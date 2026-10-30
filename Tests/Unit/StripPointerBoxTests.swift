import XCTest
@testable import macos_dock_cc_v2

/// 任务条进 / 出迟滞框（`StripPointerBox`）：两套口径各测一遍，改数值前先过这里。
final class StripPointerBoxTests: XCTestCase {
    private let strip = CGRect(x: 100, y: 0, width: 600, height: 54)
    private let reach: CGFloat = 62

    private func box(_ x: CGFloat, _ y: CGFloat, _ profile: StripPointerBox.Profile) -> StripPointerBox {
        StripPointerBox.classify(pointer: CGPoint(x: x, y: y), stripRect: strip, rightReach: reach, profile: profile)
    }

    func testInsideIsEnterAndNotOutInBothProfiles() {
        XCTAssertEqual(box(300, 20, .drawerConversion), StripPointerBox(enter: true, clearlyOut: false))
        XCTAssertEqual(box(300, 20, .stripPresence), StripPointerBox(enter: true, clearlyOut: false))
    }

    /// 抽屉转正口径：上方进 16 / 出 40，中间是迟滞带。
    func testDrawerConversionTopBand() {
        XCTAssertTrue(box(300, 54 + 15, .drawerConversion).enter)
        XCTAssertEqual(box(300, 54 + 30, .drawerConversion), StripPointerBox(enter: false, clearlyOut: false))
        XCTAssertTrue(box(300, 54 + 41, .drawerConversion).clearlyOut)
    }

    /// 拖出即合拢口径：上方进 0 / 出 6——指针一出条顶就算走了，按原生 Dock 录屏对齐（owner 2026-09-03）。
    func testStripPresenceTopBandMatchesTheNativeDock() {
        XCTAssertTrue(box(300, 54, .stripPresence).enter)
        XCTAssertEqual(box(300, 54 + 3, .stripPresence), StripPointerBox(enter: false, clearlyOut: false))
        XCTAssertTrue(box(300, 54 + 7, .stripPresence).clearlyOut)
        XCTAssertFalse(box(300, 54 + 7, .drawerConversion).clearlyOut, "抽屉那套在这个高度还没出")
    }

    /// 下方与左右两套口径相同。
    func testBottomAndSidesAreShared() {
        for profile in [StripPointerBox.Profile.drawerConversion, .stripPresence] {
            XCTAssertEqual(box(300, -16, profile), StripPointerBox(enter: false, clearlyOut: false))
            XCTAssertTrue(box(300, -25, profile).clearlyOut)
            XCTAssertEqual(box(100 - 16, 20, profile), StripPointerBox(enter: false, clearlyOut: false))
            XCTAssertTrue(box(100 - 25, 20, profile).clearlyOut)
        }
    }

    /// 右侧的胶囊算在条上：光标压在胶囊上仍是 enter，胶囊再往右 16pt 外才算出。
    func testCapsuleCountsAsOnTheStrip() {
        for profile in [StripPointerBox.Profile.drawerConversion, .stripPresence] {
            XCTAssertTrue(box(700 + reach - 1, 20, profile).enter)
            XCTAssertEqual(box(700 + reach + 10, 20, profile), StripPointerBox(enter: false, clearlyOut: false))
            XCTAssertTrue(box(700 + reach + 17, 20, profile).clearlyOut)
        }
    }

    func testEnterAndOutAreNeverBothTrue() {
        for profile in [StripPointerBox.Profile.drawerConversion, .stripPresence] {
            for x in stride(from: 0, through: 900, by: 7) {
                for y in stride(from: -60, through: 120, by: 5) {
                    let b = box(CGFloat(x), CGFloat(y), profile)
                    XCTAssertFalse(b.enter && b.clearlyOut, "(\(x), \(y)) \(profile)")
                }
            }
        }
    }
}
