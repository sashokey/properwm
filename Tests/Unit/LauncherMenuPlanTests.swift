import XCTest
@testable import macos_dock_cc_v2

final class LauncherMenuPlanTests: XCTestCase {

    func testRunningNotHiddenShowsHideAndQuit() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: true, isHidden: false, hasWindows: false, hasMembership: false)
        XCTAssertEqual(kinds, [.recentDocuments, .hide, .quit])
    }

    func testRunningHiddenShowsShowAndQuit() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: true, isHidden: true, hasWindows: false, hasMembership: false)
        XCTAssertEqual(kinds, [.recentDocuments, .show, .quit])
    }

    func testNotRunningNoMembershipShowsOpenOnly() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: false, isHidden: false, hasWindows: false, hasMembership: false)
        XCTAssertEqual(kinds, [.open])
    }

    func testNotRunningWithMembershipShowsOpenRecentAndMembership() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: false, isHidden: false, hasWindows: false, hasMembership: true)
        XCTAssertEqual(kinds, [.open, .recentDocuments, .membership])
    }

    func testRunningWithMembershipShowsAll() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: true, isHidden: false, hasWindows: false, hasMembership: true)
        XCTAssertEqual(kinds, [.recentDocuments, .hide, .membership, .quit])
    }

    /// 窗口列表（2026-08-24）：运行中且有真窗口时排最前，未运行时即使误报有窗也不出现。
    func testRunningWithWindowsStartsWithWindowList() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: true, isHidden: false, hasWindows: true, hasMembership: true)
        XCTAssertEqual(kinds, [.windowList, .recentDocuments, .hide, .membership, .quit])

        let notRunning = LauncherMenuPlan.itemKinds(isRunning: false, isHidden: false, hasWindows: true, hasMembership: false)
        XCTAssertFalse(notRunning.contains(.windowList), "未运行的显示态不该列窗口（显示区判据优先）")
    }

    /// 退出恒为末项：成员项曾被排在退出之后，导致 kept 图标菜单里「退出」落到倒数第三。
    func testQuitIsAlwaysLastWhenPresent() {
        for isRunning in [true, false] {
            for isHidden in [true, false] {
                for hasWindows in [true, false] {
                    for hasMembership in [true, false] {
                        let kinds = LauncherMenuPlan.itemKinds(isRunning: isRunning,
                                                               isHidden: isHidden,
                                                               hasWindows: hasWindows,
                                                               hasMembership: hasMembership)
                        guard kinds.contains(.quit) else { continue }
                        XCTAssertEqual(kinds.last, .quit,
                                       "running=\(isRunning) hidden=\(isHidden) windows=\(hasWindows) membership=\(hasMembership) → \(kinds)")
                    }
                }
            }
        }
    }

}
