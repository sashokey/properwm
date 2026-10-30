import CoreGraphics
import XCTest

/// 补扫探测门控判定矩阵：三个强制探测兜底、两个跳过判据、记忆失效的每条路径。
final class ScanProbeGateDecisionTests: XCTestCase {
    private let identity = ScanAdmissionDecision.ProcessIdentity(
        pid: 4242, startTimeSec: 1, startTimeUsec: 2, bundleID: "com.example.fixture"
    )

    private func conclusiveMemo(cgIDs: Set<CGWindowID> = [77]) -> ScanProbeGateDecision.Memo {
        ScanProbeGateDecision.Memo(identity: identity, lastCGIDs: cgIDs, verdictWasNoEligible: true)
    }

    private func input(
        captureFailed: Bool = false,
        cgWindowIDs: Set<CGWindowID> = [77],
        memo: ScanProbeGateDecision.Memo?,
        workspaceDirty: Bool = false,
        slowFullScanDue: Bool = false
    ) -> ScanProbeGateDecision.Input {
        ScanProbeGateDecision.Input(
            captureFailed: captureFailed,
            cgWindowIDs: cgWindowIDs,
            memo: memo,
            currentIdentity: identity,
            workspaceDirty: workspaceDirty,
            slowFullScanDue: slowFullScanDue
        )
    }

    func testCaptureFailureAlwaysProbes() {
        // CG 失败与空集不可区分（Docs/26 硬约束）：即便记忆完好也必须探测。
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(captureFailed: true, cgWindowIDs: [], memo: conclusiveMemo())),
            .probe(.captureFailed)
        )
    }

    func testSlowFullScanBypassesEverySkip() {
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(cgWindowIDs: [], memo: conclusiveMemo(), slowFullScanDue: true)),
            .probe(.fullScanDue)
        )
    }

    func testWorkspaceDirtyBypassesEverySkip() {
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(cgWindowIDs: [], memo: conclusiveMemo(), workspaceDirty: true)),
            .probe(.workspaceDirty)
        )
    }

    func testNoCGWindowsSkipsWithoutMemo() {
        // CG 全表（含最小化/隐藏/其它 Space）里一个窗口都没有 → 没有可准入之物。
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(cgWindowIDs: [], memo: nil)),
            .skipNoCGWindows
        )
    }

    func testNoMemoProbes() {
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(memo: nil)),
            .probe(.noMemo)
        )
    }

    func testIdentityChangeInvalidatesMemo() {
        // pid 复用：代际不匹配的记忆必须作废。
        var stale = conclusiveMemo()
        stale.identity = ScanAdmissionDecision.ProcessIdentity(
            pid: 4242, startTimeSec: 9, startTimeUsec: 9, bundleID: "com.example.fixture"
        )
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(memo: stale)),
            .probe(.identityChanged)
        )
    }

    func testCGSetChangeInvalidatesMemo() {
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(cgWindowIDs: [77, 78], memo: conclusiveMemo(cgIDs: [77]))),
            .probe(.cgSetChanged)
        )
    }

    func testInconclusiveMemoProbes() {
        // 防御分支：记忆只该收 noEligible 结论，混进其它结论时宁可重探。
        var memo = conclusiveMemo()
        memo.verdictWasNoEligible = false
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(memo: memo)),
            .probe(.memoNotConclusive)
        )
    }

    func testIntactConclusiveMemoSkips() {
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(memo: conclusiveMemo())),
            .skipMemoized
        )
    }
}
