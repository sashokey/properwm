import AppKit
import SwiftUI

/// 窗口根视图。和权限引导同一个结构：滚动条平时不出现，窗口高度由内容自然高度决定，
/// 只有被屏幕高度截断时才真的需要滚。
struct WelcomeGuideWindowContent: View {
    let onApply: (WelcomeGuideSelection) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            WelcomeGuideView(onApply: onApply, onDismiss: onDismiss)
        }
        .frame(width: WelcomeGuideView.contentWidth)
    }
}

/// 首次运行的一次性引导：把系统 Dock 让给钨极的三条推荐设置。
///
/// 三条同属「系统 Dock 该怎么配合钨极」这**一件**事，所以放同一屏（owner 2026-08-28 定，
/// 扩展了 2026-08-20「一屏只讲一件事」——那条挡的是把 Dock 和抽屉两个不相干主题塞一起）。
/// 抽屉空状态的可发现性仍然是另一件事，有它自己的待办卡，不塞进来。
///
/// 三条各自可勾：这是在写别人的系统偏好，用户该能只要 Dock 隐藏、不改最小化动画。
///
/// ⚠️ **这一屏的「素」是 owner 2026-08-28 看过实机后一步步定的，不是没做完**：说明性文字
/// （副标题、开头总述、每条勾选下面的灰色注解）一条不留，标题左边的图标去掉，⌥⌘D 那段的
/// 灰底方块也去掉。分区只靠间距和一条分隔线。看到光秃秃的开关别「好心」把图标、色块或注解
/// 补回来。唯一留下的说明是按钮行左侧那句闪屏预告。
struct WelcomeGuideView: View {
    let onApply: (WelcomeGuideSelection) -> Void
    let onDismiss: () -> Void

    @State private var selection = WelcomeGuideSelection.recommended

    /// 宽度固定：窗口高度由 `fittingSize` 决定，宽度不能跟着文案长短抖。
    /// 取值和权限引导一致，两扇引导窗口该长得像一家人。
    static let contentWidth: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // 图标撤走之后，标题得自己撑住这一屏的重心，所以比原来大一号。
            Text("Recommended Dock Settings")
                .font(.title2.weight(.semibold))

            options

            comeBackNote

            // 去掉色块之后，这条线是「建议区 / 行动区」唯一的分界。
            Divider()

            HStack(spacing: 8) {
                // 唯一的闪屏预告。放在手指要点的地方，而不是段落里；**无条件显示**——
                // 随勾选出现/消失会让窗口高度对不上内容（高度只在建窗时量一次）。
                // The note yields, the buttons never do: without `fixedSize()` the HStack
                // squeezes the primary button to "Apply Recommended Set…" even in English
                // (measured 173pt of the 207pt it needs) while the note keeps free space.
                Text("The screen will flash once when you apply this.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Not Now") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                Button("Apply Recommended Settings") { onApply(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty)
                    .fixedSize()
            }
        }
        .padding(28)
        .frame(width: Self.contentWidth, alignment: .leading)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Hide the Dock (auto-hide, and don’t wake it at the bottom edge)", isOn: $selection.hidesDock)
            Toggle("Use the scale effect when minimizing", isOn: $selection.usesScaleMinimizeEffect)
            Toggle("Minimize windows into their app icon", isOn: $selection.minimizesIntoAppIcon)
        }
    }

    /// 后路必须写出来（owner 2026-08-20 明确要求）：这一步会让系统 Dock 彻底不出现，
    /// 不告诉用户怎么唤回来，等于让他觉得自己把 Dock 弄丢了。
    ///
    /// ⚠️ 取消勾选「隐藏系统 Dock」时**只变淡，不隐藏**：窗口高度是建窗时用一次性探针量死的
    /// （`AppDelegate.showWelcomeWindow`），之后永不重量，任何随勾选增删的视图都会让高度对不上。
    ///
    /// ⚠️ `⌥⌘D` 归 macOS 所有，这里**只能当纯文字写**。钨极全局热键用的是 ⌥⇧⌘D；
    /// 把 ⌥⌘D 注册成 `keyEquivalent` 会把系统的快捷键抢过来（见 AGENTS.md 的热键规则）。
    private var comeBackNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Want the Dock back?")
                .font(.callout.weight(.semibold))
            Text("Press ⌥⌘D at any time — that’s macOS’s own shortcut for showing and hiding the Dock. You can also change this later from the Tungsten Edge menu bar item.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
        }
        .opacity(selection.hidesDock ? 1 : 0.4)
    }
}
