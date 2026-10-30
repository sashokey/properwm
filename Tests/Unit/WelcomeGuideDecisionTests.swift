import XCTest
@testable import macos_dock_cc_v2

/// 首次运行欢迎引导的弹出判据。
///
/// 这里真正要锁住的是**「读不到」和「读到了 false」必须分开处理**这一条：
/// 前者是瞬时故障、下次再问，后者才是"该弹"。两者混淆的方向不同、代价也不同——
/// 混成「弹」会在读不到时骚扰用户，混成「标记已看过」会因为一次 CFPreferences 抖动
/// 永久吞掉引导，而后者用户完全无从察觉。
final class WelcomeGuideDecisionTests: XCTestCase {
    func testPresentsWhenDockIsVisibleAndNothingHasBeenSeen() {
        XCTAssertEqual(
            WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: true,
                dockAutohideEnabled: false
            ),
            .present
        )
    }

    func testAlreadySeenNeverPresentsAgain() {
        // 看过就是看过，后面几个条件都不该推翻它——包括用户看完之后又把 Dock 改回常驻。
        for dockAutohide in [true, false, nil] as [Bool?] {
            XCTAssertEqual(
                WelcomeGuideDecision.evaluate(
                    hasSeenWelcome: true,
                    canWriteDockPreferences: true,
                    dockAutohideEnabled: dockAutohide
                ),
                .skipAndMarkSeen,
                "dockAutohideEnabled = \(String(describing: dockAutohide))"
            )
        }
    }

    func testDockAlreadyHiddenSkipsAndMarksSeen() {
        // 引导没有意义了。标记掉，免得用户哪天故意把 Dock 调回常驻时，
        // 被一个「首次运行引导」突然拦住。
        XCTAssertEqual(
            WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: true,
                dockAutohideEnabled: true
            ),
            .skipAndMarkSeen
        )
    }

    func testSandboxedSkipsAndMarksSeen() {
        // 沙箱里写不了 Dock 偏好，给一个必然失败的按钮不如不给。
        // 沙箱是永久属性，所以直接销掉这台机器上的引导。
        XCTAssertEqual(
            WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: false,
                dockAutohideEnabled: false
            ),
            .skipAndMarkSeen
        )
    }

    /// **这条是整个类型存在的理由。**
    ///
    /// `currentAutohideState()` 返回 nil 表示"这次没读到"，不表示"Dock 没自动隐藏"。
    /// 此时既不能弹（无凭据），更不能标记已看过——那会让一次瞬时读取失败永久吞掉引导。
    func testUnreadableDockStateSkipsWithoutMarking() {
        XCTAssertEqual(
            WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: true,
                dockAutohideEnabled: nil
            ),
            .skipWithoutMarking
        )
    }

    /// 读不到 + 沙箱：沙箱那条优先，因为它是永久的，不该每次启动都白读一次。
    func testSandboxWinsOverUnreadableState() {
        XCTAssertEqual(
            WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: false,
                dockAutohideEnabled: nil
            ),
            .skipAndMarkSeen
        )
    }

    // MARK: - 勾选 → 要写哪几个键

    /// 这一步最容易把两个最小化选项接反，而只构造 `NativeDockRecommendations` 的测试抓不到，
    /// 所以四种组合逐字段断言。
    func testFullSelectionMapsToAllThreeWrites() {
        let recommendations = WelcomeGuideSelection.recommended.recommendations(hideDelay: 999)
        XCTAssertEqual(recommendations.autoHideDelay, 999)
        XCTAssertTrue(recommendations.minimizeEffectScale)
        XCTAssertTrue(recommendations.minimizeIntoAppIcon)
        XCTAssertFalse(recommendations.isEmpty)
    }

    func testHideOnlySelectionLeavesMinimizeKeysUntouched() {
        let recommendations = WelcomeGuideSelection(
            hidesDock: true,
            usesScaleMinimizeEffect: false,
            minimizesIntoAppIcon: false
        ).recommendations(hideDelay: 999)
        XCTAssertEqual(recommendations.autoHideDelay, 999)
        XCTAssertFalse(recommendations.minimizeEffectScale)
        XCTAssertFalse(recommendations.minimizeIntoAppIcon)
    }

    /// 不勾隐藏 = **完全不碰** autohide（nil），不是「写个默认值」。
    func testMinimizeOnlySelectionCarriesNoAutoHideDelay() {
        let recommendations = WelcomeGuideSelection(
            hidesDock: false,
            usesScaleMinimizeEffect: true,
            minimizesIntoAppIcon: true
        ).recommendations(hideDelay: 999)
        XCTAssertNil(recommendations.autoHideDelay)
        XCTAssertTrue(recommendations.minimizeEffectScale)
        XCTAssertTrue(recommendations.minimizeIntoAppIcon)
    }

    /// 两个最小化选项各自独立，别接反。
    func testEachMinimizeOptionMapsToItsOwnField() {
        let scaleOnly = WelcomeGuideSelection(
            hidesDock: false,
            usesScaleMinimizeEffect: true,
            minimizesIntoAppIcon: false
        ).recommendations(hideDelay: 999)
        XCTAssertTrue(scaleOnly.minimizeEffectScale)
        XCTAssertFalse(scaleOnly.minimizeIntoAppIcon)

        let iconOnly = WelcomeGuideSelection(
            hidesDock: false,
            usesScaleMinimizeEffect: false,
            minimizesIntoAppIcon: true
        ).recommendations(hideDelay: 999)
        XCTAssertFalse(iconOnly.minimizeEffectScale)
        XCTAssertTrue(iconOnly.minimizeIntoAppIcon)
    }

    func testEmptySelectionMapsToEmptyRecommendations() {
        let selection = WelcomeGuideSelection(
            hidesDock: false,
            usesScaleMinimizeEffect: false,
            minimizesIntoAppIcon: false
        )
        XCTAssertTrue(selection.isEmpty)
        XCTAssertTrue(selection.recommendations(hideDelay: 999).isEmpty)
    }
}
