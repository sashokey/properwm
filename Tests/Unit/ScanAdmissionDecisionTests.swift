import XCTest

/// 补扫准入纯决策层（ScanAdmissionDecision）。
///
/// 核心负例是第一条：原始 AX 列表非空、但过滤后一个合格窗口都没有时必须拒收。旧实现用
/// `!snaps.isEmpty` 判定，把只有假窗口的 App 也收编了——而活着但零座位的 AppEntry 永不删除，
/// 任务栏上会留下一张擦不掉的 app-* 卡。过滤动作必须发生在 `prepare` 内部（而不是由调用方传
/// 一个数字进来），否则"生产代码误传 snaps.count"这一失败模式测不出来。
final class ScanAdmissionDecisionTests: XCTestCase {

    /// 假窗口：真 AXWindowSnapshot 含非可选 AXUIElement，单测无法凭空构造，所以纯决策层走泛型。
    private struct FakeWindow: Equatable {
        let name: String
        let eligible: Bool
    }

    private func isEligible(_ w: FakeWindow) -> Bool { w.eligible }

    private let identityA = ScanAdmissionDecision.ProcessIdentity(
        pid: 4242, startTimeSec: 1_700_000_000, startTimeUsec: 123_456, bundleID: "com.example.app"
    )

    private func verdict(
        _ prepared: ScanAdmissionDecision.Prepared<FakeWindow>,
        probed: ScanAdmissionDecision.ProcessIdentity? = nil,
        current: ScanAdmissionDecision.ProcessIdentity? = nil,
        isRegularNonSelf: Bool = true,
        isTerminated: Bool = false,
        alreadyTracked: Bool = false
    ) -> ScanAdmissionDecision.Verdict {
        ScanAdmissionDecision.verdict(
            prepared,
            probedIdentity: probed ?? identityA,
            currentIdentity: current ?? identityA,
            isRegularNonSelf: isRegularNonSelf,
            isTerminated: isTerminated,
            alreadyTracked: alreadyTracked
        )
    }

    // MARK: - 过滤接线（核心）

    /// 原始 3 个窗口、全不合格 → eligible 为空 → 拒收。锁的就是本次修复的那条接线。
    func testRawWindowsPresentButNoneEligibleIsRejected() {
        let raw = [
            FakeWindow(name: "透明面板", eligible: false),
            FakeWindow(name: "扩展窗口", eligible: false),
            FakeWindow(name: "系统内部", eligible: false)
        ]
        let prepared = ScanAdmissionDecision.prepare(rawWindows: raw, isEligible: isEligible)

        XCTAssertEqual(prepared.rawCount, 3)
        XCTAssertTrue(prepared.eligible.isEmpty)
        XCTAssertFalse(prepared.readFailed)
        XCTAssertEqual(verdict(prepared), .skipNoEligible)
    }

    /// 混合集合：带出去的必须是过滤后的那一个窗口本身，不是原始数组。
    func testMixedWindowsCarryOnlyEligibleOnes() {
        let keeper = FakeWindow(name: "真窗口", eligible: true)
        let raw = [FakeWindow(name: "假窗口", eligible: false), keeper, FakeWindow(name: "假窗口2", eligible: false)]
        let prepared = ScanAdmissionDecision.prepare(rawWindows: raw, isEligible: isEligible)

        XCTAssertEqual(prepared.rawCount, 3)
        XCTAssertEqual(prepared.eligible, [keeper])
        XCTAssertEqual(verdict(prepared), .admit)
    }

    /// AX 读失败（.unread）与"读到 0 个窗口"是两回事，各自有独立结论。
    func testUnreadIsDistinctFromEmpty() {
        let unread = ScanAdmissionDecision.prepare(rawWindows: nil, isEligible: isEligible)
        XCTAssertTrue(unread.readFailed)
        XCTAssertEqual(unread.rawCount, 0)
        XCTAssertEqual(verdict(unread), .skipUnread)

        let empty = ScanAdmissionDecision.prepare(rawWindows: [FakeWindow](), isEligible: isEligible)
        XCTAssertFalse(empty.readFailed)
        XCTAssertEqual(verdict(empty), .skipNoEligible)
    }

    // MARK: - 进程代际（pid 复用）

    private func eligiblePrepared() -> ScanAdmissionDecision.Prepared<FakeWindow> {
        ScanAdmissionDecision.prepare(
            rawWindows: [FakeWindow(name: "真窗口", eligible: true)],
            isEligible: isEligible
        )
    }

    func testSameIdentityAdmits() {
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: identityA), .admit)
    }

    func testDifferentPIDIsIdentityMismatch() {
        let other = ScanAdmissionDecision.ProcessIdentity(
            pid: 9999, startTimeSec: identityA.startTimeSec, startTimeUsec: identityA.startTimeUsec,
            bundleID: identityA.bundleID
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: other), .skipIdentityMismatch)
    }

    func testDifferentBundleIDIsIdentityMismatch() {
        let other = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: identityA.startTimeSec, startTimeUsec: identityA.startTimeUsec,
            bundleID: "com.example.other"
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: other), .skipIdentityMismatch)
    }

    /// pid 被复用的真实签名：同 pid 同 bundleID，但启动时刻变了（秒/微秒任一不同都算）。
    func testDifferentStartTimeIsIdentityMismatch() {
        let laterSec = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: 1_700_000_099, startTimeUsec: identityA.startTimeUsec,
            bundleID: identityA.bundleID
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: laterSec), .skipIdentityMismatch)

        let laterUsec = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: identityA.startTimeSec, startTimeUsec: 999_999,
            bundleID: identityA.bundleID
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: laterUsec), .skipIdentityMismatch)
    }

    /// 启动时刻单方缺失 = 进程已经没了，保守拒收，等下一轮补扫。
    func testMissingStartTimeOnOneSideIsIdentityMismatch() {
        let missing = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: nil, startTimeUsec: nil, bundleID: identityA.bundleID
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: missing), .skipIdentityMismatch)
        XCTAssertEqual(verdict(eligiblePrepared(), probed: missing, current: identityA), .skipIdentityMismatch)
    }

    /// 双方都缺失也不放行——不能用"两边都不知道"当作同一个进程的证据。
    func testMissingStartTimeOnBothSidesIsIdentityMismatch() {
        let missing = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: nil, startTimeUsec: nil, bundleID: identityA.bundleID
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: missing, current: missing), .skipIdentityMismatch)
    }

    // MARK: - 进程态（回调时重查）

    func testAlreadyTrackedIsRejectedEvenWithEligibleWindows() {
        XCTAssertEqual(verdict(eligiblePrepared(), alreadyTracked: true), .skipAlreadyTracked)
    }

    func testTerminatedIsRejectedEvenWithEligibleWindows() {
        XCTAssertEqual(verdict(eligiblePrepared(), isTerminated: true), .skipTerminated)
    }

    func testNonRegularIsRejectedEvenWithEligibleWindows() {
        XCTAssertEqual(verdict(eligiblePrepared(), isRegularNonSelf: false), .skipNotRegular)
    }
}
