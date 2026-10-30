import Foundation

/// 消息区**准入能力**的纯决策层:哪些应用当前能被认出主窗口。
///
/// 消息区的模型是「一个图标 = 该应用的主窗口卡」,所以「能不能认出主窗口」本身就是这个区的
/// 能力测试。`MessagingAppStore.autoRegister` 用它当自动标记的门槛:看起来像消息应用还不够,
/// 还得**能在这个区里被正确表示**。
///
/// 这道门槛挡住的是「永远认不出」的应用——Apple「信息」是 Mac Catalyst 应用,窗口标题是
/// UIScene 会话编号,与应用名永不相等;Ghostty 这类终端窗口标题是命令名,却会因 App Store
/// 类别是「社交网络」而被误标。它们进了消息区只会得到一个「只能唤醒、不能收起」的启动器图标,
/// 且窗口不被吸收还会重复显示。
///
/// **调用方必须只在首次注册时取用**:本判定反映的是「此刻」能否认出,不是稳定属性。微信主窗口
/// 关闭时只剩「笔记」窗口,此刻同样认不出——若每轮复检就会把它踢出消息区、开回来又跳进去。
/// 一次通过即永久落名单,之后不再复检。
enum MessagingZoneAdmission {
    /// 快照里的一个窗口读模型(只取判定需要的三个字段,不依赖 UI 层类型)。
    struct WindowFact: Equatable {
        let bundleID: String
        let title: String
        let isAppLevelFallback: Bool

        init(bundleID: String, title: String, isAppLevelFallback: Bool) {
            self.bundleID = bundleID
            self.title = title
            self.isAppLevelFallback = isAppLevelFallback
        }
    }

    /// - Parameter titleMatchesAppName: `(title, bundleID) -> Bool`,以闭包注入,把查
    ///   `NSRunningApplication` / 读磁盘 plist / 静态缓存这些不纯的部分留在调用侧。
    /// - Returns: 当前存在「标题等于应用名」的真实窗口的那些 bundleID。
    static func mainWindowIdentifiableBundleIDs(
        windows: [WindowFact],
        titleMatchesAppName: (String, String) -> Bool
    ) -> Set<String> {
        var result: Set<String> = []
        for window in windows {
            // app-* 兜底项不是真实窗口,不能拿来证明主窗口可识别。
            guard !window.isAppLevelFallback, !window.bundleID.isEmpty else { continue }
            guard !result.contains(window.bundleID) else { continue }
            if titleMatchesAppName(window.title, window.bundleID) {
                result.insert(window.bundleID)
            }
        }
        return result
    }
}
