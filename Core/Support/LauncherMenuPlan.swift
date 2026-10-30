import Foundation

/// 启动图标（LauncherChip）右键菜单的**纯决策层**：给定「显示区运行态 + 是否有成员项」，
/// 产出应出现的菜单项种类（顺序即渲染顺序）。抽成纯逻辑是为了可单测，构建 NSMenu 的副作用留在 LauncherChip。
///
/// 关键：`isRunning` 传的是**图标所在区的显示态**（`LauncherChip.isRunning`，按区赋值），
/// **不是** `NSWorkspace` 的进程存活态。未运行区里进程可能仍活（关窗不退 / 常驻），
/// 但它按「未运行」显示，菜单也必须按未运行处理——否则会冒出与外观矛盾的「隐藏 / 退出」。

enum LauncherMenuItemKind: Equatable {
    /// 「打开」——仅未运行时出现，严格排在最近文件与成员项之前。运行态用 显示/隐藏/退出 代替。
    case open
    /// Dock 式窗口列表（✓ 前台 / ◇ 最小化）——运行中且确有真窗口时排在最前（2026-08-24）。
    /// 只属于应用级图标；具体窗口卡不经过本计划。
    case windowList
    case recentDocuments
    case show
    case hide
    /// 退出（含 Option 替身 强制退出）——**恒定末项**，成员项一律排在它之前。
    case quit
    /// 成员 / 管理项区（可勾选的在程序坞中保留 / 固定在 Dock 栏左侧；1 或多项由调用方决定）。
    case membership
}

enum LauncherMenuPlan {
    /// - Parameters:
    ///   - isRunning: 图标所在区的**显示态**（非进程存活态）。
    ///   - isHidden: 显示态下 app 是否隐藏（决定「显示」还是「隐藏」）。
    ///   - hasWindows: 快照里该应用有没有真窗口（决定要不要窗口列表）。
    ///   - hasMembership: 是否有成员/管理项。
    static func itemKinds(isRunning: Bool,
                          isHidden: Bool,
                          hasWindows: Bool,
                          hasMembership: Bool) -> [LauncherMenuItemKind] {
        // 次序（Docs/27 2026-08-24）：窗口列表 → 最近文件 → 动作项 → 成员项 → 退出。
        // 退出必须恒为末项——成员项夹在退出之后会让「退出」落到倒数第三，与用户预期相悖。
        var kinds: [LauncherMenuItemKind] = []
        if !isRunning { kinds.append(.open) }
        if isRunning && hasWindows { kinds.append(.windowList) }
        if isRunning || hasMembership { kinds.append(.recentDocuments) }
        if isRunning { kinds.append(isHidden ? .show : .hide) }
        if hasMembership { kinds.append(.membership) }
        if isRunning { kinds.append(.quit) }
        return kinds
    }
}
