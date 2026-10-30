import AppKit

/// NSScreen → display UUID（`CGDisplayCreateUUIDFromDisplayID`，基于 EDID，
/// 拔插 / 换口 / 休眠唤醒后稳定）。任务条「固定到某屏」的持久化身份用它，
/// **绝不按 `NSScreen.screens` 数组序号记屏**。
/// 逻辑与 `FullscreenIntentMonitor.swift` 里 `ManagedSpaceLayoutReader.displayUUIDString(for:)`
/// 同源（那个文件的细节被规则冻结，刻意不共享实现）。
enum DisplayIdentity {
    @MainActor
    static func uuidString(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))
        else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String?
    }

    /// 在场屏幕表：每块能读出 UUID 的屏的 Quartz 帧 + 主屏（`NSScreen.screens.first`，菜单栏那块；
    /// **不是** `NSScreen.main`，那个跟着 key 窗口跑）。喂给 `WindowDisplayAttribution` / `StripDisplayFilter`。
    /// 屏参数变化时算一次（`DisplayTopologyStore`），别在热路径上现算。
    @MainActor
    static func attributionTable() -> WindowDisplayAttribution.Table {
        attributionTable(screens: NSScreen.screens)
    }

    /// Builds the table from screens the caller already sampled, so one topology transaction
    /// never reads `NSScreen.screens` twice.
    @MainActor
    static func attributionTable(screens: [NSScreen]) -> WindowDisplayAttribution.Table {
        let primaryHeight = screens.first?.frame.maxY ?? 0
        var primaryUUID: String?
        let displays: [WindowDisplayAttribution.Display] = screens.enumerated().compactMap { index, screen in
            guard let uuid = uuidString(for: screen) else { return nil }
            if index == 0 { primaryUUID = uuid }
            return WindowDisplayAttribution.Display(
                uuid: uuid,
                cgFrame: WindowLiftAvoidance.quartzFrame(fromAppKit: screen.frame, primaryScreenHeight: primaryHeight),
                visibleCGFrame: WindowLiftAvoidance.quartzFrame(fromAppKit: screen.visibleFrame,
                                                                primaryScreenHeight: primaryHeight)
            )
        }
        return WindowDisplayAttribution.Table(
            displays: displays,
            primaryUUID: primaryUUID
        )
    }

    /// Derives the physical display count, the ordered UUIDs and the attribution table from a
    /// single read.
    @MainActor
    static func topologySnapshot() -> ScreenTopologySnapshot {
        let screens = NSScreen.screens
        let table = attributionTable(screens: screens)
        return ScreenTopologySnapshot(
            physicalDisplayCount: screens.count,
            identifiedDisplayUUIDs: table.displays.map(\.uuid),
            attributionTable: table
        )
    }

    /// 在场的屏 →（display UUID, 去重后的展示名）。读不出 UUID 的屏不进列表（固定不了它）。
    /// **有系统 I/O（`localizedName` 会读 IODisplay），别在菜单弹出路径上现算**——
    /// 调用方应在屏幕参数变化时缓存一份（`StatusMenuController` 即如此）。
    @MainActor
    static func connectedScreenOptions() -> [(uuid: String, title: String)] {
        let identified: [(uuid: String, name: String)] = NSScreen.screens.compactMap { screen in
            guard let uuid = uuidString(for: screen) else { return nil }
            return (uuid, screen.localizedName)
        }
        let titles = TaskbarScreenResolution.displayTitles(names: identified.map(\.name))
        return zip(identified, titles).map { ($0.uuid, $1) }
    }
}
