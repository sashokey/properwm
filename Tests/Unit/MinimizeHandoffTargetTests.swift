import XCTest
@testable import macos_dock_cc_v2

final class MinimizeHandoffTargetTests: XCTestCase {
    private func record(_ id: String, pid: Int32, wid: CGWindowID?, status: WindowStatus = .inactive) -> WindowRecord {
        var r = WindowRecord(
            id: WindowID(rawValue: id), appID: AppID(rawValue: "app-\(pid)"), pid: pid,
            bundleIdentifier: nil, title: "T", bounds: nil, status: status
        )
        r.cgWindowID = wid
        return r
    }

    private func snapshot(_ records: [WindowRecord]) -> DockSnapshot {
        DockSnapshot(
            windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
            orderedWindowIDs: records.map(\.id)
        )
    }

    private func z(_ pairs: [(Int32, CGWindowID)]) -> [MinimizeHandoffTarget.ZOrderedWindow] {
        pairs.map { .init(pid: $0.0, cgWindowID: $0.1) }
    }

    /// B1 > A > B2：压在下面的是别的 App → 交给 A（pid + 它那扇窗口）。
    func testOtherAppDirectlyBeneathIsSwitchedTo() {
        let b1 = record("b1", pid: 2, wid: 21, status: .active)
        let a = record("a", pid: 1, wid: 11)
        let b2 = record("b2", pid: 2, wid: 22)
        let verdict = MinimizeHandoffTarget.select(
            zOrder: z([(2, 21), (1, 11), (2, 22)]), target: b1, snapshot: snapshot([b1, a, b2]))
        XCTAssertEqual(verdict, .switchTo(pid: 1, cgWindowID: 11, windowID: WindowID(rawValue: "a")))
    }

    /// B1 > B2 > A：紧贴在下的是兄弟 → 不交接，让 AppKit 原生提拔 B2。
    func testSiblingDirectlyBeneathTakesOver() {
        let b1 = record("b1", pid: 2, wid: 21, status: .active)
        let b2 = record("b2", pid: 2, wid: 22)
        let a = record("a", pid: 1, wid: 11)
        let verdict = MinimizeHandoffTarget.select(
            zOrder: z([(2, 21), (2, 22), (1, 11)]), target: b1, snapshot: snapshot([b1, b2, a]))
        XCTAssertEqual(verdict, .siblingTakesOver(windowID: WindowID(rawValue: "b2")))
    }

    /// 中间夹着没被任务条收编的窗口（不在快照里）→ 跳过，取下一个。
    func testUnadmittedWindowsAreSkipped() {
        let b1 = record("b1", pid: 2, wid: 21, status: .active)
        let a = record("a", pid: 1, wid: 11)
        let verdict = MinimizeHandoffTarget.select(
            zOrder: z([(2, 21), (9, 99), (1, 11)]), target: b1, snapshot: snapshot([b1, a]))
        XCTAssertEqual(verdict, .switchTo(pid: 1, cgWindowID: 11, windowID: WindowID(rawValue: "a")))
    }

    /// 目标之上的条目（浮在上面的别的窗口）不算候选。
    func testEntriesAboveTargetAreIgnored() {
        let b1 = record("b1", pid: 2, wid: 21, status: .active)
        let c = record("c", pid: 3, wid: 31)
        let a = record("a", pid: 1, wid: 11)
        let verdict = MinimizeHandoffTarget.select(
            zOrder: z([(3, 31), (2, 21), (1, 11)]), target: b1, snapshot: snapshot([b1, c, a]))
        XCTAssertEqual(verdict, .switchTo(pid: 1, cgWindowID: 11, windowID: WindowID(rawValue: "a")))
    }

    /// 目标不在 CG 列表里（cgWindowID 未知）→ 从头扫。
    func testTargetMissingFromZOrderScansFromTop() {
        let b1 = record("b1", pid: 2, wid: nil, status: .active)
        let a = record("a", pid: 1, wid: 11)
        let verdict = MinimizeHandoffTarget.select(
            zOrder: z([(1, 11)]), target: b1, snapshot: snapshot([b1, a]))
        XCTAssertEqual(verdict, .switchTo(pid: 1, cgWindowID: 11, windowID: WindowID(rawValue: "a")))
    }

    /// 没有可交接的在屏窗口 → none（兜底路径由调用方决定）。
    func testNoCandidateYieldsNone() {
        let b1 = record("b1", pid: 2, wid: 21, status: .active)
        let hidden = record("h", pid: 1, wid: 11, status: .hidden)
        let verdict = MinimizeHandoffTarget.select(
            zOrder: z([(2, 21), (1, 11)]), target: b1, snapshot: snapshot([b1, hidden]))
        XCTAssertEqual(verdict, .none)
        XCTAssertEqual(MinimizeHandoffTarget.select(zOrder: [], target: b1, snapshot: snapshot([b1])), .none)
    }
}
