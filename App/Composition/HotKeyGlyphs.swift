import Carbon.HIToolbox
import Foundation

/// 组合键 → 展示字形（如 "⌃⌘K"）。纯函数，App 与测试两个 target 都编译。
///
/// 主键的字形**在录制时就定格存进 `StoredHotKeyShortcut.glyphs`**，展示端只读存好的
/// 字符串——keyCode 反查字符要经 UCKeyTranslate + 当前键盘布局，展示时现算既重又会
/// 随布局漂移；录制那一刻 NSEvent 手里就有 `charactersIgnoringModifiers`，白拿。
enum HotKeyGlyphs {
    /// 修饰键固定序 ⌃⌥⇧⌘（macOS 菜单栏的标准展示序）。
    static func modifierString(carbonModifiers: UInt32) -> String {
        var out = ""
        if carbonModifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out
    }

    /// 主键字形。表里没有、事件字符又不可打印时返回 nil（调用方按「这个键不能用」处理）。
    static func keyString(keyCode: UInt32, charactersIgnoringModifiers: String?) -> String? {
        if let known = specialKeyNames[keyCode] { return known }
        guard let raw = charactersIgnoringModifiers, let scalar = raw.unicodeScalars.first else {
            return nil
        }
        // F 键等功能键的字符落在 Unicode 私有区（U+F700 起），没进表就不认；
        // 控制字符（回车、Tab 已进表）一律不认。
        guard scalar.value < 0xF700, !CharacterSet.controlCharacters.contains(scalar) else {
            return nil
        }
        let key = raw.uppercased()
        return key.isEmpty ? nil : key
    }

    /// 完整展示串；主键不可展示时返回 nil。
    static func display(keyCode: UInt32, carbonModifiers: UInt32, charactersIgnoringModifiers: String?) -> String? {
        guard let key = keyString(keyCode: keyCode, charactersIgnoringModifiers: charactersIgnoringModifiers) else {
            return nil
        }
        return modifierString(carbonModifiers: carbonModifiers) + key
    }

    private static let specialKeyNames: [UInt32: String] = [
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "↩",
        UInt32(kVK_ANSI_KeypadEnter): "⌤",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]
}
