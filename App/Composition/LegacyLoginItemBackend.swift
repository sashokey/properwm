import AppKit
import CoreServices

/// macOS 12 的「登录时启动」：`SMAppService` 要 13+，12 上走老的登录项列表
/// （`LSSharedFileList*`，和「系统偏好设置 → 用户与群组 → 登录项」是同一张表，用户看得见、能自己删）。
///
/// **这里的过时警告是预期的，不要为了消警告去改。** Apple 在 10.11 就把这组 API 标成过时，
/// 但 macOS 12 已停止更新、接口不会再变，而这条路径只在 12 上被选中（`LaunchAtLoginService.systemBackend()`）。
/// 最低部署目标升到 13 时整个文件直接删除。为什么不用 helper app 或 LaunchAgent：`Docs/27`。
///
/// 后端与真正碰 CoreServices 的 `SharedFileListLoginItems` 之间隔着 `LoginItemListing`，
/// 单测用内存列表替掉它（`LaunchAtLoginServiceTests`）。
protocol LoginItemListing: Sendable {
    /// 列表打不开时返回 nil，和「列表是空的」区分开。
    func itemURLs() -> [URL]?
    func insert(_ url: URL) throws
    /// 删除列表里**所有**解析到这个 URL 的条目。
    func remove(_ url: URL) throws
}

struct LegacyLoginItemBackend: LaunchAtLoginBackend {
    let list: any LoginItemListing
    let bundleURL: URL

    func readState() -> LaunchAtLoginState {
        guard let urls = list.itemURLs() else { return .unsupported }
        return urls.contains { LoginItemURLMatcher.matches($0, bundleURL) } ? .on : .off
    }

    func setEnabled(_ enabled: Bool) throws {
        guard let urls = list.itemURLs() else { throw LaunchAtLoginError.unsupported }
        let matches = urls.filter { LoginItemURLMatcher.matches($0, bundleURL) }
        if enabled {
            // 已经在列表里就不再插一条：老接口不去重，重复条目会在系统偏好设置里显示成两行。
            guard matches.isEmpty else { return }
            try list.insert(bundleURL)
        } else {
            for url in matches {
                try list.remove(url)
            }
        }
    }

    /// 老列表没有「待批准」这一步，菜单里的「打开登录项设置…」在 12 上不会出现；
    /// 留着是为了协议完整——12 的登录项住在「用户与群组」。
    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preferences.users") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 列表里存的 URL 带不带结尾斜杠、有没有经过 `/private` 符号链接都不稳定，比较前先归一。
enum LoginItemURLMatcher {
    static func matches(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedPath(lhs) == normalizedPath(rhs)
    }

    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

/// 唯一碰 `LSSharedFileList*` 的地方。
struct SharedFileListLoginItems: LoginItemListing {
    func itemURLs() -> [URL]? {
        guard let list = openList() else { return nil }
        return entries(in: list).map(\.url)
    }

    func insert(_ url: URL) throws {
        guard let list = openList() else { throw LaunchAtLoginError.unsupported }
        // 返回值带 CF_RETURNS_RETAINED，Swift 里直接拿到对象，不要再 takeRetainedValue()。
        let inserted = LSSharedFileListInsertItemURL(
            list,
            kLSSharedFileListItemLast.takeUnretainedValue(),
            nil,
            nil,
            url as CFURL,
            nil,
            nil
        )
        guard inserted != nil else { throw LaunchAtLoginError.writeFailed }
    }

    func remove(_ url: URL) throws {
        guard let list = openList() else { throw LaunchAtLoginError.unsupported }
        for entry in entries(in: list) where LoginItemURLMatcher.matches(entry.url, url) {
            guard LSSharedFileListItemRemove(list, entry.item) == noErr else {
                throw LaunchAtLoginError.writeFailed
            }
        }
    }

    private func openList() -> LSSharedFileList? {
        LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeUnretainedValue(), nil)?
            .takeRetainedValue()
    }

    private func entries(in list: LSSharedFileList) -> [(item: LSSharedFileListItem, url: URL)] {
        var seed: UInt32 = 0
        let items = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] ?? []
        // 解析条目时不要弹交互、不要挂载卷：这一步跑在后台队列上，列表里可能有指向外接盘的别的登录项。
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        return items.compactMap { item in
            guard let url = LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue() as URL? else {
                return nil
            }
            return (item, url)
        }
    }
}
