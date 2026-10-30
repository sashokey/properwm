import CoreGraphics
import XCTest

final class FullscreenIntentDecisionTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testGreenButtonAcceptsExactHitAndIgnoresNonModifierFlags() {
        let snapshot = makeSnapshot()
        let request = FullscreenIntentDecision.greenButtonRequest(
            location: CGPoint(x: 120, y: 110),
            flags: [.maskAlphaShift, .maskNonCoalesced],
            snapshot: snapshot
        )
        XCTAssertEqual(request?.source, .greenButton)
        XCTAssertEqual(request?.focusedWindowID, snapshot.focusedWindowID)
    }

    func testGreenButtonRejectsModifiersCapabilityAndContextMismatches() {
        let point = CGPoint(x: 120, y: 110)
        for modifier: CGEventFlags in [
            .maskControl, .maskCommand, .maskAlternate, .maskShift,
            .maskSecondaryFn, .maskHelp, .maskNumericPad
        ] {
            XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
                location: point, flags: modifier, snapshot: makeSnapshot()
            ))
        }
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: CGPoint(x: 200, y: 200), flags: [], snapshot: makeSnapshot()
        ))
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: point, flags: [], snapshot: makeSnapshot(buttonEnabled: false)
        ))
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: point, flags: [], snapshot: makeSnapshot(isFullscreen: true)
        ))
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: point, flags: [], snapshot: makeSnapshot(panelScreens: [])
        ))
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: point,
            flags: [],
            snapshot: makeSnapshot(panelScreens: [CGRect(x: 1512, y: 0, width: 1920, height: 1080)])
        ))
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: point, flags: [], snapshot: nil
        ))
    }

    func testShortcutAcceptsExactControlCommandAndCapsLock() {
        let request = FullscreenIntentDecision.shortcutRequest(
            keyCode: FullscreenIntentDecision.ansiFKeyCode,
            flags: [.maskControl, .maskCommand, .maskAlphaShift, .maskNonCoalesced],
            isRepeat: false,
            snapshot: makeSnapshot()
        )
        XCTAssertEqual(request?.source, .keyboardShortcut)
    }

    func testShortcutRejectsExtraModifiersRepeatWrongKeyAndMissingCapability() {
        for flags: CGEventFlags in [
            [.maskControl, .maskCommand, .maskAlternate],
            [.maskControl, .maskCommand, .maskShift],
            [.maskControl, .maskCommand, .maskSecondaryFn],
            [.maskControl, .maskCommand, .maskHelp],
            [.maskControl, .maskCommand, .maskNumericPad],
            [.maskCommand]
        ] {
            XCTAssertNil(FullscreenIntentDecision.shortcutRequest(
                keyCode: FullscreenIntentDecision.ansiFKeyCode,
                flags: flags,
                isRepeat: false,
                snapshot: makeSnapshot()
            ))
        }
        XCTAssertNil(FullscreenIntentDecision.shortcutRequest(
            keyCode: FullscreenIntentDecision.ansiFKeyCode,
            flags: [.maskControl, .maskCommand],
            isRepeat: true,
            snapshot: makeSnapshot()
        ))
        XCTAssertNil(FullscreenIntentDecision.shortcutRequest(
            keyCode: 4,
            flags: [.maskControl, .maskCommand],
            isRepeat: false,
            snapshot: makeSnapshot()
        ))
        XCTAssertNil(FullscreenIntentDecision.shortcutRequest(
            keyCode: FullscreenIntentDecision.ansiFKeyCode,
            flags: [.maskControl, .maskCommand],
            isRepeat: false,
            snapshot: makeSnapshot(buttonEnabled: false)
        ))
    }

    func testSettingAndEnvironmentMustBothEnableMonitor() {
        XCTAssertTrue(FullscreenIntentDecision.isEnabled(settingEnabled: true, environment: [:]))
        XCTAssertFalse(FullscreenIntentDecision.isEnabled(
            settingEnabled: true,
            environment: ["DOCK_FULLSCREEN_INTENT": "0"]
        ))
        XCTAssertFalse(FullscreenIntentDecision.isEnabled(settingEnabled: false, environment: [:]))
    }

    func testStaleAXRefreshAndForegroundPIDSwitchCannotReplaceCache() {
        XCTAssertTrue(FullscreenIntentCacheDecision.shouldApplyRefresh(
            started: true,
            expectedObservation: 4,
            currentObservation: 4,
            expectedCache: 7,
            currentCache: 7,
            requestedPID: 123,
            activePID: 123
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.shouldApplyRefresh(
            started: true,
            expectedObservation: 4,
            currentObservation: 5,
            expectedCache: 7,
            currentCache: 7,
            requestedPID: 123,
            activePID: 123
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.shouldApplyRefresh(
            started: true,
            expectedObservation: 4,
            currentObservation: 4,
            expectedCache: 7,
            currentCache: 8,
            requestedPID: 123,
            activePID: 123
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.shouldApplyRefresh(
            started: true,
            expectedObservation: 4,
            currentObservation: 4,
            expectedCache: 7,
            currentCache: 7,
            requestedPID: 123,
            activePID: 124
        ))
    }

    func testRequestMustMatchCurrentPIDWindowScreenAndCacheGeneration() {
        let snapshot = makeSnapshot()
        let request = FullscreenIntentDecision.shortcutRequest(
            keyCode: FullscreenIntentDecision.ansiFKeyCode,
            flags: [.maskControl, .maskCommand],
            isRepeat: false,
            snapshot: snapshot
        )!
        XCTAssertTrue(FullscreenIntentCacheDecision.isCurrentRequest(
            request,
            snapshot: snapshot,
            activePID: snapshot.pid,
            started: true
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.isCurrentRequest(
            request,
            snapshot: makeSnapshot(generation: 10),
            activePID: snapshot.pid,
            started: true
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.isCurrentRequest(
            request,
            snapshot: makeSnapshot(focusedWindowID: 999),
            activePID: snapshot.pid,
            started: true
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.isCurrentRequest(
            request,
            snapshot: snapshot,
            activePID: 124,
            started: true
        ))
    }

    func testRefreshCoalescerCollapsesBurstIntoOneTrailingRefresh() {
        var coalescer = FullscreenIntentRefreshCoalescer()
        let first = coalescer.request()!
        XCTAssertNil(coalescer.request())
        XCTAssertNil(coalescer.request())
        XCTAssertTrue(coalescer.needsTrailingRefresh)

        guard case let .start(second) = coalescer.complete(token: first) else {
            return XCTFail("burst must schedule exactly one trailing refresh")
        }
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(coalescer.needsTrailingRefresh)
        XCTAssertEqual(coalescer.complete(token: first), .ignored)
        XCTAssertEqual(coalescer.complete(token: second), .idle)
        XCTAssertNil(coalescer.activeToken)
    }

    func testRefreshCoalescerResetInvalidatesOldCompletion() {
        var coalescer = FullscreenIntentRefreshCoalescer()
        let old = coalescer.request()!
        coalescer.reset()
        let current = coalescer.request()!

        XCTAssertEqual(coalescer.complete(token: old), .ignored)
        XCTAssertEqual(coalescer.activeToken, current)
        XCTAssertEqual(coalescer.complete(token: current), .idle)
    }

    func testTapRecoveryFusesOnFourthDisableWithinWindow() {
        var policy = FullscreenEventTapRecoveryPolicy()
        XCTAssertTrue(policy.recordDisable(at: 0))
        XCTAssertTrue(policy.recordDisable(at: 1))
        XCTAssertTrue(policy.recordDisable(at: 2))
        XCTAssertFalse(policy.recordDisable(at: 3))
        XCTAssertTrue(policy.isFused)
        XCTAssertFalse(policy.recordDisable(at: 64))
    }

    func testTapRecoveryDropsOldEpisodesOutsideWindow() {
        var policy = FullscreenEventTapRecoveryPolicy()
        XCTAssertTrue(policy.recordDisable(at: 0))
        XCTAssertTrue(policy.recordDisable(at: 1))
        XCTAssertTrue(policy.recordDisable(at: 61))
        XCTAssertTrue(policy.recordDisable(at: 62))
        XCTAssertFalse(policy.isFused)
    }

    func testLateHandoffCannotBeginAfterCancellation() {
        let gate = FullscreenIntentHandoffGate()
        XCTAssertTrue(gate.cancelIfPending())
        XCTAssertFalse(gate.beginExecution())
        XCTAssertEqual(gate.currentState, .cancelled)
    }

    func testExecutingHandoffCompletesAndCannotBeCancelled() {
        let gate = FullscreenIntentHandoffGate()
        XCTAssertTrue(gate.beginExecution())
        XCTAssertFalse(gate.cancelIfPending())
        gate.complete()
        XCTAssertEqual(gate.currentState, .completed)
    }

    // MARK: - Control+←/→ 空间切换实验

    /// 这一条是整个实验最容易翻车的地方：**物理方向键天生带 Fn + 小键盘 + nonCoalesced**，
    /// 用户一个附加键都没按也是如此。照 `FullscreenIntentDecision.normalizedModifiers`
    /// 那套比对会永远匹配不上，得到一个「什么都不触发」的假阴性，而它极容易被读成
    /// 「548ms 提前量不够，这条路走不通」。
    func testPhysicalArrowIntrinsicFlagsDoNotBlockTheMatch() {
        let physicalControlLeft: CGEventFlags = [
            .maskControl, .maskSecondaryFn, .maskNumericPad, .maskNonCoalesced
        ]
        XCTAssertTrue(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
            keyCode: FullscreenSpaceSwitchDecision.leftArrowKeyCode,
            flags: physicalControlLeft,
            isRepeat: false
        ))
        XCTAssertTrue(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
            keyCode: FullscreenSpaceSwitchDecision.rightArrowKeyCode,
            flags: physicalControlLeft,
            isRepeat: false
        ))
    }

    func testSpaceSwitchArrowRejectsEveryOtherShape() {
        let intrinsic: CGEventFlags = [.maskSecondaryFn, .maskNumericPad, .maskNonCoalesced]
        // 没按 Control
        XCTAssertFalse(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
            keyCode: FullscreenSpaceSwitchDecision.leftArrowKeyCode,
            flags: intrinsic,
            isRepeat: false
        ))
        // 多带了别的修饰键
        for extra: CGEventFlags in [.maskCommand, .maskAlternate, .maskShift, .maskHelp] {
            XCTAssertFalse(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
                keyCode: FullscreenSpaceSwitchDecision.leftArrowKeyCode,
                flags: intrinsic.union([.maskControl]).union(extra),
                isRepeat: false
            ), "\(extra) 不该放行")
        }
        // 上下方向键不是切空间
        for keyCode in [CGKeyCode(125), CGKeyCode(126)] {
            XCTAssertFalse(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
                keyCode: keyCode,
                flags: intrinsic.union([.maskControl]),
                isRepeat: false
            ))
        }
        // 长按重复不再触发
        XCTAssertFalse(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
            keyCode: FullscreenSpaceSwitchDecision.rightArrowKeyCode,
            flags: intrinsic.union([.maskControl]),
            isRepeat: true
        ))
    }

    func testArrowDirectionMapsKeyCodes() {
        let physical: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad, .maskNonCoalesced]
        XCTAssertEqual(
            FullscreenSpaceSwitchDecision.arrowDirection(
                keyCode: FullscreenSpaceSwitchDecision.leftArrowKeyCode,
                flags: physical, isRepeat: false
            ),
            .left
        )
        XCTAssertEqual(
            FullscreenSpaceSwitchDecision.arrowDirection(
                keyCode: FullscreenSpaceSwitchDecision.rightArrowKeyCode,
                flags: physical, isRepeat: false
            ),
            .right
        )
    }

    // MARK: - 相邻空间闸

    private func layout(current: Int, fullscreen: Set<Int> = [3]) -> SpaceLayoutSnapshot {
        SpaceLayoutSnapshot(
            orderedSpaceIDs: [1, 2, 3, 4],
            fullscreenSpaceIDs: fullscreen,
            currentSpaceID: current
        )
    }

    func testNeighborGateOnlyOpensTowardAFullscreenSpace() {
        // 空间 3 是全屏；站在 2 往右、站在 4 往左才该开
        XCTAssertTrue(layout(current: 2).neighborIsFullscreen(.right))
        XCTAssertFalse(layout(current: 2).neighborIsFullscreen(.left))
        XCTAssertTrue(layout(current: 4).neighborIsFullscreen(.left))
        XCTAssertFalse(layout(current: 4).neighborIsFullscreen(.right))
        // 两个普通桌面之间：两侧都不开——否则那里本来没问题的地方会被藏一下
        XCTAssertFalse(layout(current: 1, fullscreen: []).hasAnyFullscreenNeighbor)
    }

    func testNeighborGateHandlesEdgesAndUnknownCurrentSpace() {
        XCTAssertFalse(layout(current: 1).neighborIsFullscreen(.left))   // 最左边没有左邻
        XCTAssertFalse(layout(current: 4).neighborIsFullscreen(.right))  // 最右边没有右邻
        XCTAssertFalse(layout(current: 99).hasAnyFullscreenNeighbor)     // 当前空间不在列表里
    }

    // 2026-08-31 补：闸只属于「站在桌面上的人」。当前已在全屏空间时不预测——
    // 条本来就藏着，没有可藏的东西；全屏→全屏交给既有的保持机制。
    // （反向预测「全屏→桌面提前放条」做过并撤销，理由见 SpaceLayoutSnapshot 注释——
    // 稳定优先，owner 拍板；别只删这条测试就把它加回来。）
    func testGateNeverOpensWhileStandingInAFullscreenSpace() {
        // 站在全屏空间 3：两侧都是桌面，闸也不开
        XCTAssertFalse(layout(current: 3).neighborIsFullscreen(.left))
        XCTAssertFalse(layout(current: 3).neighborIsFullscreen(.right))
        XCTAssertFalse(layout(current: 3).hasAnyFullscreenNeighbor)
        // 全屏挨着全屏（3、4 都是全屏）：从 3 往右同样不开
        XCTAssertFalse(layout(current: 3, fullscreen: [3, 4]).neighborIsFullscreen(.right))
        // 站在桌面 2 往右照常开（原有行为不受影响）
        XCTAssertTrue(layout(current: 2).neighborIsFullscreen(.right))
    }

    // MARK: - 三指水平滑动

    /// 实测映射（14/14 一致）：自然滚动下**手指向左滑去右边的空间**。
    func testSwipeDirectionFollowsNaturalScrollingSetting() {
        var tracker = SpaceSwipeTracker()
        XCTAssertNil(tracker.consume(touches: 3, x: 0.5, y: 0.5, at: 0, naturalScrolling: true))
        XCTAssertEqual(
            tracker.consume(touches: 3, x: 0.3, y: 0.5, at: 0, naturalScrolling: true), .right
        )
        tracker.reset()
        XCTAssertNil(tracker.consume(touches: 3, x: 0.5, y: 0.5, at: 0, naturalScrolling: false))
        XCTAssertEqual(
            tracker.consume(touches: 3, x: 0.3, y: 0.5, at: 0, naturalScrolling: false), .left
        )
    }

    /// 三指**上下**滑动（Mission Control）实测 10 次里有 1 次水平漂移越过阈值；
    /// 「水平位移必须压过垂直位移」这一条把 10/10 全部排除。删掉它就会误藏任务条。
    func testVerticalThreeFingerSwipeNeverFires() {
        var tracker = SpaceSwipeTracker()
        _ = tracker.consume(touches: 3, x: 0.50, y: 0.50, at: 0, naturalScrolling: true)
        // 实测最坏样本：水平 0.055、垂直 0.267
        XCTAssertNil(tracker.consume(touches: 3, x: 0.555, y: 0.767, at: 0, naturalScrolling: true))
    }

    func testSwipeNeedsThreeFingersAndResetsWhenFingersLift() {
        var tracker = SpaceSwipeTracker()
        // 两指滚动：再大的水平位移也不触发
        _ = tracker.consume(touches: 2, x: 0.5, y: 0.5, at: 0, naturalScrolling: true)
        XCTAssertNil(tracker.consume(touches: 2, x: 0.1, y: 0.5, at: 0, naturalScrolling: true))
        // 手指抬起（触点不足三根）会重新起锚，跨串的位移不累计
        _ = tracker.consume(touches: 3, x: 0.5, y: 0.5, at: 0, naturalScrolling: true)
        _ = tracker.consume(touches: 0, x: 0.0, y: 0.0, at: 0, naturalScrolling: true)
        XCTAssertNil(tracker.consume(touches: 3, x: 0.1, y: 0.5, at: 0, naturalScrolling: true))
    }

    func testSwipeFiresOnlyOncePerBurst() {
        var tracker = SpaceSwipeTracker()
        _ = tracker.consume(touches: 3, x: 0.6, y: 0.5, at: 0, naturalScrolling: true)
        XCTAssertEqual(tracker.consume(touches: 3, x: 0.4, y: 0.5, at: 0, naturalScrolling: true), .right)
        XCTAssertNil(tracker.consume(touches: 3, x: 0.2, y: 0.5, at: 0, naturalScrolling: true))
        XCTAssertNil(tracker.consume(touches: 3, x: 0.9, y: 0.5, at: 0, naturalScrolling: true))
    }

    private func makeSnapshot(
        generation: UInt64 = 9,
        focusedWindowID: CGWindowID = 456,
        buttonEnabled: Bool = true,
        isFullscreen: Bool = false,
        panelScreens: [CGRect] = [CGRect(x: 0, y: 0, width: 1512, height: 982)]
    ) -> FullscreenIntentSnapshot {
        FullscreenIntentSnapshot(
            generation: generation,
            pid: 123,
            focusedWindowID: focusedWindowID,
            buttonFrame: CGRect(x: 100, y: 100, width: 40, height: 20),
            windowFrame: CGRect(x: 80, y: 80, width: 900, height: 700),
            screenCGFrame: screen,
            panelScreenCGFrames: panelScreens,
            isFullscreen: isFullscreen,
            buttonEnabled: buttonEnabled
        )
    }


    // MARK: - 多屏（2026-09-02）

    /// ③ 下多块屏都有条：焦点窗口所在屏只要在集合里就发请求。
    func testGreenButtonRequestFiresWhenScreenIsAnyPanelScreen() {
        let other = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let request = FullscreenIntentDecision.greenButtonRequest(
            location: CGPoint(x: 110, y: 110),
            flags: [],
            snapshot: makeSnapshot(panelScreens: [other, screen])
        )
        XCTAssertNotNil(request)
    }

    private func layout(current: Int, ordered: [Int], fullscreen: Set<Int>) -> SpaceLayoutSnapshot {
        SpaceLayoutSnapshot(orderedSpaceIDs: ordered, fullscreenSpaceIDs: fullscreen, currentSpaceID: current)
    }

    func testSpaceLayoutDirectoryLocatesDisplayUnderPointAndArrowTarget() {
        let a = SpaceLayoutDirectory.Entry(
            displayUUID: "A",
            appKitFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            layout: layout(current: 1, ordered: [1, 2], fullscreen: [])
        )
        let b = SpaceLayoutDirectory.Entry(
            displayUUID: "B",
            appKitFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            layout: layout(current: 3, ordered: [3, 4], fullscreen: [4])
        )
        let directory = SpaceLayoutDirectory(entries: [a, b])
        XCTAssertTrue(directory.hasAnyFullscreenNeighbor)
        XCTAssertEqual(directory.entry(containing: CGPoint(x: 100, y: 100))?.displayUUID, "A")
        XCTAssertEqual(directory.entry(containing: CGPoint(x: 2000, y: 100))?.displayUUID, "B")
        XCTAssertNil(directory.entry(containing: CGPoint(x: -5, y: 5)))
        XCTAssertEqual(directory.displays(withFullscreenNeighbor: .right).map(\.displayUUID), ["B"])
        // 唯一候选：鼠标在 A 上也落 B。
        XCTAssertEqual(directory.arrowTarget(.right, mouseLocation: CGPoint(x: 100, y: 100))?.displayUUID, "B")
        XCTAssertNil(directory.arrowTarget(.left, mouseLocation: CGPoint(x: 100, y: 100)))
    }

    func testSpaceLayoutDirectoryArrowTargetPrefersMouseDisplayAmongCandidates() {
        let a = SpaceLayoutDirectory.Entry(
            displayUUID: "A",
            appKitFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            layout: layout(current: 1, ordered: [1, 2], fullscreen: [2])
        )
        let b = SpaceLayoutDirectory.Entry(
            displayUUID: "B",
            appKitFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            layout: layout(current: 3, ordered: [3, 4], fullscreen: [4])
        )
        let directory = SpaceLayoutDirectory(entries: [a, b])
        XCTAssertEqual(directory.arrowTarget(.right, mouseLocation: CGPoint(x: 2000, y: 50))?.displayUUID, "B")
        XCTAssertEqual(directory.arrowTarget(.right, mouseLocation: CGPoint(x: 10, y: 50))?.displayUUID, "A")
        // 鼠标不在任何候选上 → 第一块。
        XCTAssertEqual(directory.arrowTarget(.right, mouseLocation: CGPoint(x: -100, y: -100))?.displayUUID, "A")
    }
}
