import AppKit
import Combine
import SwiftUI

/// Shared by the two hosting roots of one taskbar; a resize must not inherit chip animations.
@MainActor
final class PanelHeightResizePresentation: ObservableObject {
    @Published var isActive = false

    func nonInteractiveHeightChanges(
        from heights: Published<DockPanelHeight>.Publisher
    ) -> AnyPublisher<DockPanelHeight, Never> {
        heights
            .removeDuplicates()
            .dropFirst()
            // Reject at publication, before a queued delivery can outlive the drag.
            .filter { [weak self] _ in self?.isActive == false }
            .receive(on: DispatchQueue.main)
            // A new drag may have started while an ordinary change was queued.
            .filter { [weak self] _ in self?.isActive == false }
            .eraseToAnyPublisher()
    }
}

private struct PanelHeightResizingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isPanelHeightResizing: Bool {
        get { self[PanelHeightResizingKey.self] }
        set { self[PanelHeightResizingKey.self] = newValue }
    }
}

struct PanelHeightResizeModifier: ViewModifier {
    @ObservedObject var presentation: PanelHeightResizePresentation

    func body(content: Content) -> some View {
        content
            .environment(\.isPanelHeightResizing, presentation.isActive)
            .transaction { transaction in
                if presentation.isActive {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}

/// Hosts manually sized panel content without letting the hosted view become the
/// window's content view and participate in automatic window sizing.
@MainActor
final class ManualPanelHost {
    let contentView: NSView

    init(contentView: NSView, in panel: NSPanel) {
        self.contentView = contentView

        let initialSize = panel.contentView?.bounds.size
            ?? panel.contentRect(forFrameRect: panel.frame).size
        let container = NSView(frame: NSRect(origin: .zero, size: initialSize))
        panel.contentView = container

        contentView.frame = container.bounds
        contentView.autoresizingMask = [.width, .height]
        container.addSubview(contentView)
    }

    var fittingSize: NSSize { contentView.fittingSize }

    /// ObservedObject invalidation alone does not refresh NSHostingView's fitting size in the
    /// publishing call stack. Lay out explicitly before measuring and after resizing its panel.
    func layoutContent() {
        contentView.needsLayout = true
        contentView.layoutSubtreeIfNeeded()
    }
}

/// Window levels above `.floating`, the level every panel is created at.
enum PanelLevel {
    /// The drawer while a drag from outside has it open. The system Apps panel (Spotlight's app
    /// list, a window of `Siri`) sits at 23 on macOS 27; at `.floating` the drawer opened under it.
    static let raisedDrawer = NSWindow.Level.statusBar
    /// The drag carrier: above every panel of ours, the raised drawer included — an app dropped
    /// from outside lands on the carrier, into that drawer.
    static let carrier = NSWindow.Level(rawValue: raisedDrawer.rawValue + 1)
}

/// 七扇悬浮面板共用的窗口行为集合。**必须只有这一处字面量**：
/// issue #19 的修复要把这套值原样重新赋一遍来补回「常驻所有桌面」的成员资格，
/// 复原的值和创建时的值一旦分叉，修复就会静默地把面板改成另一种行为。
enum PanelCollectionBehavior {
    static let standard: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
}

/// 关闭 AppKit 的窗口自动约束。系统默认会把靠近/跨越屏幕边缘的窗口挪回"当前屏"可用区内（避开菜单栏）。
/// 多屏**共享边**场景下这会致命：把任务条放到上方屏底部时，窗口原点 y 落在下方屏那一侧，系统就拿下方屏
/// 来约束，把整窗按到下方屏菜单栏正下方 → 任务条/胶囊跑到错误的屏（2026-06-23 三屏 bug 根因；实测 y=970
/// 被按成 y=857 = 下方屏可用区顶 949 − 窗口高 92）。我们的面板永远手动精确定位、永不盖菜单栏，故直接
/// 返回原 frame、不让系统二次约束。
class NonConstrainingPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // `isMovable = false` only stops mouse drags: any process with Accessibility access can still
    // relocate the window through `kAXPositionAttribute`, and `PanelCoordinator` never puts it
    // back (`setFrames` compares targets, not live frames). A window manager reacting to the
    // per-tick frame changes of a grip drag is exactly such a process. NSWindow serves AX
    // position / size writes through the legacy attribute API below; disallowing
    // `setAccessibilityFrame(_:)` via `isAccessibilitySelectorAllowed` does not block them.
    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        if attribute == .position || attribute == .size { return false }
        return super.accessibilityIsAttributeSettable(attribute)
    }

    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        if attribute == .position || attribute == .size { return }
        super.accessibilitySetValue(value, forAttribute: attribute)
    }
}

/// Liquid Glass is hosted in a non-key floating panel. These private AppKit appearance hooks are
/// the same narrow override used by native-looking third-party docks to keep the material active.
final class DockLiquidGlassPanel: NonConstrainingPanel {
    @objc(_hasActiveAppearance)
    func bestDockHasActiveAppearance() -> Bool { true }

    @objc(_hasActiveAppearanceIgnoringKeyFocus)
    func bestDockHasActiveAppearanceIgnoringKeyFocus() -> Bool { true }

    @objc(_hasKeyAppearance)
    func bestDockHasKeyAppearance() -> Bool { true }

    @objc(_hasMainAppearance)
    func bestDockHasMainAppearance() -> Bool { true }

    @objc(_hasActiveControls)
    func bestDockHasActiveControls() -> Bool { true }
}
