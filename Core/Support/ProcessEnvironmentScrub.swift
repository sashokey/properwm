import Foundation

/// 进程入口处清掉「终端味」的环境变量（2026-08-23）。
///
/// 任务条启动别的应用时，系统把我们自己的环境原样传给它。从终端（Xcode / Claude Code / Ghostty）
/// 拉起的开发构建带着 `LANG=en_US.UTF-8`，再由它启动的微信就以英文界面打开、主窗口标题变成
/// `Weixin`，「标题 == 应用名」的主窗口识别随之失效——owner 机器上「从钨极启动的微信是英文」
/// 就是这么来的（实测：那个微信进程身上带着整套终端变量，从 Dock 启动的 Telegram 一个都没有）。
/// 一个任务条应该**像 Dock 一样**启动应用，不管自己是怎么被启动的。
///
/// 正常用户从 Launchpad / 登录项启动，这些变量本来就不存在，清了零影响。
/// 自家的 `DOCK_*` 开关不在清单里。
enum ProcessEnvironmentScrub {
    static let exactKeys: Set<String> = [
        "LANG", "COLORTERM", "SHELL", "SHLVL",
        "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
    ]
    static let prefixes: [String] = ["LC_", "CLAUDE_", "GHOSTTY_"]

    /// 纯判定：给定环境里哪些 key 该清。排序只为输出稳定。
    static func keysToUnset(in environment: [String: String]) -> [String] {
        environment.keys
            .filter { key in exactKeys.contains(key) || prefixes.contains(where: { key.hasPrefix($0) }) }
            .sorted()
    }

    /// 入口处调一次，越早越好——之后任何被我们启动的应用继承的都是此刻的环境。
    static func apply(environment: [String: String] = ProcessInfo.processInfo.environment) {
        for key in keysToUnset(in: environment) {
            unsetenv(key)
        }
    }
}
