import Carbon.HIToolbox
import Foundation

/// 录制到的组合键被拒绝的理由。给设置窗口挑一句人话用，纯值便于单测。
enum HotKeyShortcutRejection: Equatable {
    /// 一个 ⌘ / ⌃ / ⌥ 都没有（含只按了 ⇧ 或什么修饰键都没按）。
    case missingPrimaryModifier
    /// 仅 ⌥ 或 ⌥⇧：macOS 15 上已知不可靠（FB15168205），默认快捷键当年就是为躲它挑的。
    case unreliableModifiers
    /// 系统已占用：⌃⌥（VoiceOver 的修饰键组合，不带 ⌘ 时拒绝）、恰好 ⌥⌘D（macOS
    /// 自己的系统 Dock 显隐键——它归系统持有，注册就是抢，规则同 `GlobalHotKeyShortcut`）。
    case reservedBySystem
    /// Esc / Delete / 前向 Delete 不能当主键：它们在录制框里另有语义（取消），
    /// 真拿来当全局键也只会和无数应用内语义打架。
    case forbiddenKey
}

/// 「这个组合能不能注册成钨极的全局快捷键」的纯判定。
/// App 与测试两个 target 都编译；注册的副作用在 `GlobalHotKeyMonitor`。
enum HotKeyShortcutValidation {
    static func validate(keyCode: UInt32, carbonModifiers: UInt32) -> HotKeyShortcutRejection? {
        let cmd = UInt32(cmdKey)
        let opt = UInt32(optionKey)
        let ctl = UInt32(controlKey)
        let shf = UInt32(shiftKey)

        let forbiddenKeys: Set<UInt32> = [
            UInt32(kVK_Escape),
            UInt32(kVK_Delete),
            UInt32(kVK_ForwardDelete),
        ]
        if forbiddenKeys.contains(keyCode) { return .forbiddenKey }

        if carbonModifiers & (cmd | ctl | opt) == 0 { return .missingPrimaryModifier }
        if carbonModifiers == opt || carbonModifiers == (opt | shf) { return .unreliableModifiers }
        // ⌃⌥ 不带 ⌘ = VoiceOver 修饰键域；带上 ⌘ 的 ⌃⌥⌘X 是常见安全组合，放行。
        if carbonModifiers & ctl != 0, carbonModifiers & opt != 0, carbonModifiers & cmd == 0 {
            return .reservedBySystem
        }
        if carbonModifiers == (opt | cmd), keyCode == UInt32(kVK_ANSI_D) { return .reservedBySystem }
        return nil
    }
}
