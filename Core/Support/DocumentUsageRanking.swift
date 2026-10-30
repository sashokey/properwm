import Foundation

/// 一个文件的使用计数。`count` 只从功能上线后开始累积（macOS 不记录历史打开次数）。
struct DocumentUsageRecord: Equatable, Codable {
    var count: Int
    var lastOpened: Date
}

/// 一个应用的计数账本。`lastTop` = 上次采样时系统最近列表的榜首（判「有没有新打开」用），
/// `touchedAt` = 本账本最后一次变动（bundle 级淘汰用）。
struct BundleDocumentUsage: Equatable, Codable {
    var files: [String: DocumentUsageRecord] = [:]
    var lastTop: String?
    var touchedAt: Date = .distantPast
}

/// 「最常用的文件」的纯逻辑：排序、计数、淘汰。副作用（盘、订阅、菜单）在 `DocumentUsageStore`。
enum DocumentUsageRanking {
    static let fileCap = 200
    static let bundleCap = 40

    /// 榜单：计数降序 → lastOpened 降序 → 系统最近序。只出现在最近列表、没计过数的按
    /// 0 次排在所有计过数的后面——于是刚升级那几天菜单和原来的「最近」一致，越用越准。
    /// 候选 = 系统最近列表 ∪ 已计数文件（按路径去重）。
    static func ranked(
        counts: [String: DocumentUsageRecord],
        recentPaths: [String],
        limit: Int = 10
    ) -> [String] {
        var recentOrder: [String: Int] = [:]
        for (index, path) in recentPaths.enumerated() where recentOrder[path] == nil {
            recentOrder[path] = index
        }
        var candidates = Set(recentPaths)
        candidates.formUnion(counts.keys)
        let sorted = candidates.sorted { a, b in
            let na = counts[a]?.count ?? 0
            let nb = counts[b]?.count ?? 0
            if na != nb { return na > nb }
            let da = counts[a]?.lastOpened ?? .distantPast
            let db = counts[b]?.lastOpened ?? .distantPast
            if da != db { return da > db }
            let oa = recentOrder[a] ?? Int.max
            let ob = recentOrder[b] ?? Int.max
            if oa != ob { return oa < ob }
            return a < b
        }
        return Array(sorted.prefix(limit))
    }

    /// 某文件 +1。超过 `cap` 时淘汰「计数最低、其中最久未开」的一个（永不淘汰刚 +1 的这个）。
    static func bumped(
        _ files: [String: DocumentUsageRecord],
        path: String,
        at date: Date,
        cap: Int = fileCap
    ) -> [String: DocumentUsageRecord] {
        var files = files
        var record = files[path] ?? DocumentUsageRecord(count: 0, lastOpened: date)
        record.count += 1
        record.lastOpened = date
        files[path] = record
        while files.count > cap {
            let victim = files.min { a, b in
                if a.value.count != b.value.count { return a.value.count < b.value.count }
                if a.value.lastOpened != b.value.lastOpened { return a.value.lastOpened < b.value.lastOpened }
                return a.key < b.key
            }?.key
            guard let victim, victim != path else { break }
            files.removeValue(forKey: victim)
        }
        return files
    }

    /// 榜首变化才算一次打开。首次采样（previous == nil）只立基线不计数——那可能是
    /// 陈年榜首，不是刚发生的打开；榜单清空（new == nil）也不计。
    static func shouldCountTopChange(previousTop: String?, newTop: String?) -> Bool {
        guard let previousTop, let newTop else { return false }
        return previousTop != newTop
    }

    /// bundle 级淘汰：只留最近动过的 `maxBundles` 份账本。
    static func prunedBundles(
        _ store: [String: BundleDocumentUsage],
        maxBundles: Int = bundleCap
    ) -> [String: BundleDocumentUsage] {
        guard store.count > maxBundles else { return store }
        let kept = store.sorted { $0.value.touchedAt > $1.value.touchedAt }.prefix(maxBundles)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
