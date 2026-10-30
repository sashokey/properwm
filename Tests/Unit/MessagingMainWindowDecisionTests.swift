import XCTest
@testable import macos_dock_cc_v2

/// 消息区认主窗口的三条规则（2026-08-23）。每条都对应一个真实 app 的形态，别删。
final class MessagingMainWindowDecisionTests: XCTestCase {
    private typealias W = MessagingMainWindowDecision.WindowFact
    private let wechat = "com.tencent.xinWeChat"
    private let telegram = "ru.keepcoder.Telegram"

    /// 第 1 条：标题匹配优先，哪怕有别的窗口（飞书主窗 + 独立聊天窗）。
    func testTitleMatchWinsOverEverything() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: "com.electron.lark",
            windows: [W(id: "chat", title: "张三"), W(id: "main", title: "飞书")],
            titleMatchesAppName: { $0 == "飞书" }
        )
        XCTAssertEqual(id, "main")
    }

    /// 微信冷启动的形态（2026-08-23 实测）：登录窗（700×640，order-out 后座位仍在）和主窗口都叫「微信」，
    /// 登录窗先创建。必须挑主窗口，不能按创建序取第一扇。
    func testAmongSeveralTitleMatchesTheLargestVisibleWins() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: wechat,
            windows: [W(id: "login", title: "微信", area: 700 * 640),
                      W(id: "main", title: "微信", area: 1220 * 870)],
            titleMatchesAppName: { $0 == "微信" }
        )
        XCTAssertEqual(id, "main")
    }

    /// 主窗口被最小化、登录窗没有：仍然不能把图标绑到登录窗上？——不，最小化的主窗口让位给没最小化的：
    /// 多扇同名时「没最小化」优先于「面积」，否则点图标「还原」的是一扇永远看不见的窗。
    func testNonMinimizedTitleMatchBeatsLargerMinimizedOne() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: wechat,
            windows: [W(id: "big-minimized", title: "微信", isMinimized: true, area: 1220 * 870),
                      W(id: "small-visible", title: "微信", area: 700 * 640)],
            titleMatchesAppName: { $0 == "微信" }
        )
        XCTAssertEqual(id, "small-visible")
    }

    /// 全相同时保留先出现的（稳定，不在两扇之间抖）。
    func testEqualTitleMatchesKeepFirst() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: wechat,
            windows: [W(id: "a", title: "微信"), W(id: "b", title: "微信")],
            titleMatchesAppName: { $0 == "微信" }
        )
        XCTAssertEqual(id, "a")
    }

    /// 第 2 条：单窗口应用，标题写的不是应用名（Telegram / 信息 / Slack 的形态）。
    func testSingleWindowIsMainEvenWithoutTitleMatch() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: telegram,
            windows: [W(id: "only", title: "Saved Messages")],
            titleMatchesAppName: { _ in false }
        )
        XCTAssertEqual(id, "only")
    }

    /// 2026-07-21 的起因：微信主窗关了只剩「笔记」→ 必须是「没有主窗口」，点图标才会叫回主窗口。
    func testWeChatNotesAloneIsNotMain() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: wechat,
            windows: [W(id: "notes", title: "笔记")],
            titleMatchesAppName: { _ in false }
        )
        XCTAssertNil(id)
    }

    /// 排除表只是剔除：笔记 + 一扇认不出名字的窗 → 剩下那扇是主窗口（别名失效时的微信）。
    func testExclusionLeavesTheOtherWindowAsMain() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: wechat,
            windows: [W(id: "notes", title: " 笔记 "), W(id: "main", title: "Weixin")],
            titleMatchesAppName: { _ in false }
        )
        XCTAssertEqual(id, "main", "排除表按归一化标题比较")
    }

    /// 第 3 条：两扇以上都认不出 → nil，调用方走 app 级开关，不猜。
    func testAmbiguousWindowsYieldNil() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: "com.example.chat",
            windows: [W(id: "a", title: "Alice"), W(id: "b", title: "Bob")],
            titleMatchesAppName: { _ in false }
        )
        XCTAssertNil(id)
    }

    func testNoWindowsYieldNil() {
        XCTAssertNil(MessagingMainWindowDecision.mainWindowID(
            bundleID: telegram, windows: [], titleMatchesAppName: { _ in true }))
    }

    /// 排除表只对自己的 bundle 生效：别的 app 叫「笔记」的唯一窗口照样是主窗口。
    func testExclusionIsScopedToItsBundle() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: "com.example.notesapp",
            windows: [W(id: "n", title: "笔记")],
            titleMatchesAppName: { _ in false }
        )
        XCTAssertEqual(id, "n")
    }
}
