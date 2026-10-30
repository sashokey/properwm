import Foundation

/// 消息区那枚图标代表哪扇窗——**纯决策**（2026-08-23）。三条从强到弱：
///
/// 1. 窗口标题 == 应用名 → 主窗口。飞书 / QQ / 别名后的微信走这条，现状原样。**多扇都叫应用名时**
///    先挑没最小化的、再挑面积最大的（2026-08-23 实测：微信冷启动先弹一扇 700×640 的登录窗，
///    标题也是「微信」，登录后被 order-out 但 CG 里还在、座位因此保留；按创建序取第一扇就会把
///    图标绑到这扇看不见的窗上——owner 报「图标只能叫不能收」）。
/// 2. 剔掉排除表里「明确不是主窗口」的之后**只剩一扇** → 那就是主窗口。Telegram、手动固定的
///    Slack 这类单窗口应用走这条——海外消息应用几乎全是单窗口，它们的标题写的是会话名 /
///    未读数 / 系统编号，第 1 条永远过不了。
/// 3. 都不成立 → `nil`。调用方退化成**整个 app 的开关**（`DockStripView` 的 `.messagingApp`
///    无主窗分支），图标永远有反应，只是独立聊天窗一起收。
///
/// 第 2 条解除了 2026-07-21 的禁令（当时微信关掉主窗口只剩「笔记」，被吸成主窗口后主窗口
/// 再也叫不回来）。**解除的前提是排除表**：笔记排除后微信回到「没有主窗口」，点图标仍是叫回
/// 主窗口。排除表的纪律：
/// - **只写排除，不写指定**（「X 不是主窗口」而不是「主窗口叫 X」）：指定错了把图标绑到错的
///   窗口上，用户完全无法理解；排除错了最坏退回通用规则。
/// - **只有本机实测绑错才加一条**，不给没装过的 app 猜。
/// - 表里的中文是窗口标题数据，不是文案，不本地化（见 `AGENTS.md` 铁律）。
enum MessagingMainWindowDecision {
    struct WindowFact: Equatable {
        let id: String
        let title: String
        /// 已最小化的窗不优先当主窗口（只在多扇同名时起作用）。
        let isMinimized: Bool
        /// 窗口面积（pt²），多扇同名时越大越像主窗口。未知写 0。
        let area: CGFloat

        init(id: String, title: String, isMinimized: Bool = false, area: CGFloat = 0) {
            self.id = id
            self.title = title
            self.isMinimized = isMinimized
            self.area = area
        }
    }

    /// 明确不是主窗口的标题（归一化后比较）。微信「笔记」= 2026-07-21 那次实测绑错的窗口。
    static let excludedTitlesByBundleID: [String: Set<String>] = [
        "com.tencent.xinWeChat": ["笔记"],
    ]

    /// - Parameters:
    ///   - windows: 该 app 的**真实**窗口（不含 app 级兜底项），任意顺序。
    ///   - titleMatchesAppName: 第 1 条的判据，闭包注入，把 `AppNameRegistry` 留在调用侧。
    /// - Returns: 主窗口的 id；`nil` = 认不出，调用方走 app 级开关。
    static func mainWindowID(
        bundleID: String,
        windows: [WindowFact],
        titleMatchesAppName: (String) -> Bool
    ) -> String? {
        let titled = windows.filter { titleMatchesAppName($0.title) }
        if let best = titled.max(by: { lhs, rhs in
            // max(by:) 的 "lhs < rhs"：先比「没最小化」，再比面积；全相同时保留先出现的（稳定）。
            if lhs.isMinimized != rhs.isMinimized { return lhs.isMinimized }
            return lhs.area < rhs.area
        }) {
            return best.id
        }
        let excluded = excludedTitlesByBundleID[bundleID] ?? []
        let candidates = windows.filter { !excluded.contains(normalize($0.title)) }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
