import Foundation

/// 固定文件夹「左键主行为」的可切换策略。
///
/// A/B 预留：以后要做「左键预览 vs 左键打开访达窗口」的切换，只改这里（或把 `primaryAction`
/// 接到设置里按用户选择返回），**所有左键调用点统一走 `DockStripView.folderPrimaryTap`**，
/// 不在各处写死行为，避免散落。
enum FolderPrimaryAction {
    /// 左键 = 打开该路径的访达窗口。
    case openFinderWindow
    /// 左键 = 打开内容预览弹窗。
    case preview
}

enum FolderInteraction {
    /// 当前固定文件夹左键 = 内容预览（2026-07-09：左键要「点开点收」的 toggle 手感；
    /// 打开真访达窗口退到右键「在访达中打开」）。做 A/B 时改这一处即可。
    static var primaryAction: FolderPrimaryAction { .preview }
}
