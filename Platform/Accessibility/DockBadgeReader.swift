import AppKit
import ApplicationServices

/// Reads per-app badge strings from the system Dock's accessibility tree.
///
/// Apps publish unread counts by setting their Dock tile badge; there is no public
/// API to read another app's badge directly, but the Dock process exposes each icon
/// as an AX element whose `AXStatusLabel` attribute carries the badge text ("3",
/// "99+", "•"). Mapping element → app uses the Dock item's `AXURL` (the .app bundle
/// URL), which is exact — no name matching.
///
/// Requires Accessibility permission, which this app already needs. Apps only get a
/// Dock icon while running (or pinned), and messaging chips only render while the
/// app runs, so coverage is aligned by construction.
/// 一次全量走树的产物：Dock 进程 pid + bundleID → AXDockItem 元素引用。元素引用跨 tick 复用
///（定点读每 0.5s 只碰这几个引用，不再走整棵树）；Dock 重启、读错、身份重验失败、消息名单
/// 变化时整体作废重建。AXUIElement 是线程安全的 CFType，跨线程携带与 AXWindowSnapshot.element
/// 同一先例。
struct DockItemCache: @unchecked Sendable {
    let dockPID: pid_t
    let elementsByBundleID: [String: AXUIElement]
}

struct DockBadgeWalkOutcome {
    let badges: [String: String]
    /// Dock 进程没找到时为 nil（下一 tick 会再走一次全量）。
    let cache: DockItemCache?
    /// app 路径 → bundleID 的持久缓存（跨走树复用，省掉每 tick 的 Bundle(url:) 磁盘读）。
    let pathToBundleID: [String: String]
}

enum DockBadgeTargetedOutcome: Equatable {
    case ok([String: String])
    /// Dock 换代 / 元素读错 / 身份重验失败：本轮结果不可信。调用方必须沿用上次发布值
    ///（瞬态错误不能把角标闪没）并安排重走全树。
    case cacheInvalid
}

protocol DockBadgeReading: Sendable {
    func readBadges() -> [String: String]
    func fullWalk(previousPathMap: [String: String]) -> DockBadgeWalkOutcome
    func targetedRead(
        cache: DockItemCache,
        bundleIDs: [String],
        previousBadges: [String: String]
    ) -> DockBadgeTargetedOutcome
}

struct DockBadgeReader: DockBadgeReading, Sendable {
    /// Returns [bundleID: badge text] for every Dock item that currently shows a badge.
    /// Call off the main thread; AX messaging to the Dock can block briefly.
    func readBadges() -> [String: String] {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(dockElement, 0.25)

        var bundleIDByPath: [String: String] = [:]
        var result: [String: String] = [:]
        // Dock AX hierarchy: application element → AXList children → AXDockItem children.
        for list in children(of: dockElement) {
            for item in children(of: list) {
                guard let badge = stringAttribute("AXStatusLabel", of: item),
                      !badge.isEmpty,
                      let url = urlAttribute(kAXURLAttribute as String, of: item),
                      let bundleID = bundleID(forAppURL: url, cache: &bundleIDByPath) else { continue }
                result[bundleID] = badge
            }
        }
        return result
    }

    /// 全量走树：与 `readBadges()` 同一棵树，但顺带缓存**每个** app 磁贴的元素引用（多读一次
    /// AXURL/项），换来此后每 tick 只读消息应用那一两个元素。走树是低频动作（10s 自愈 + 名单
    /// 变化 + 读错恢复），不在 0.5s 热路径上。
    func fullWalk(previousPathMap: [String: String]) -> DockBadgeWalkOutcome {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return DockBadgeWalkOutcome(badges: [:], cache: nil, pathToBundleID: previousPathMap)
        }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(dockElement, 0.25)

        var pathMap = previousPathMap
        var badges: [String: String] = [:]
        var elements: [String: AXUIElement] = [:]
        for list in children(of: dockElement) {
            for item in children(of: list) {
                guard let url = urlAttribute(kAXURLAttribute as String, of: item),
                      let bid = bundleID(forAppURL: url, cache: &pathMap) else { continue }
                _ = AXUIElementSetMessagingTimeout(item, 0.25)
                elements[bid] = item
                if let badge = stringAttribute("AXStatusLabel", of: item) {
                    badges[bid] = badge
                }
            }
        }
        return DockBadgeWalkOutcome(
            badges: badges,
            cache: DockItemCache(dockPID: dock.processIdentifier, elementsByBundleID: elements),
            pathToBundleID: pathMap
        )
    }

    /// 定点读：只读 `bundleIDs` 里有缓存元素的项的 AXStatusLabel（1~3 次 AX 往返/tick）。
    /// 三道保守失效：① Dock pid 换代；② 任何非「无角标」的读错误；③ **值发生变化的项**在
    /// 发布前重验元素 AXURL 仍指向同一 bundleID（封死「回收元素替别的 app 报数」的静默错误，
    /// 稳态零成本——值不变不重验）。
    func targetedRead(
        cache: DockItemCache,
        bundleIDs: [String],
        previousBadges: [String: String]
    ) -> DockBadgeTargetedOutcome {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first,
              dock.processIdentifier == cache.dockPID else { return .cacheInvalid }

        var badges: [String: String] = [:]
        for bid in bundleIDs {
            guard let item = cache.elementsByBundleID[bid] else { continue }
            switch statusLabelRead(of: item) {
            case .value(let badge): badges[bid] = badge
            case .absent: break
            case .readError: return .cacheInvalid
            }
        }
        for bid in bundleIDs where badges[bid] != previousBadges[bid] {
            guard let item = cache.elementsByBundleID[bid],
                  let url = urlAttribute(kAXURLAttribute as String, of: item),
                  Bundle(url: url)?.bundleIdentifier == bid else { return .cacheInvalid }
        }
        return .ok(badges)
    }

    // MARK: - AX helpers

    private enum AttributeRead {
        case value(String)
        /// 正常的「无角标」：读成功但空 / 无值 / 属性不支持。
        case absent
        /// 其它错误（元素失效、超时等）——与「无角标」必须区分，否则瞬态错误会把角标闪没。
        case readError
    }

    private func statusLabelRead(of element: AXUIElement) -> AttributeRead {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, "AXStatusLabel" as CFString, &value)
        switch err {
        case .success:
            guard let text = value as? String else { return .absent }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .absent : .value(trimmed)
        case .noValue, .attributeUnsupported:
            return .absent
        default:
            return .readError
        }
    }


    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func urlAttribute(_ attribute: String, of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let url = value as? NSURL else { return nil }
        return url as URL
    }

    private func bundleID(forAppURL url: URL, cache: inout [String: String]) -> String? {
        let path = url.path
        if let cached = cache[path] { return cached }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        cache[path] = bundleID
        return bundleID
    }
}
