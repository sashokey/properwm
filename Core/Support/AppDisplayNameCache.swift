import Foundation

final class AppDisplayNameCache {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for bundleID: String, loader: () -> String?) -> String {
        lock.lock()
        let cached = values[bundleID]
        lock.unlock()
        if let cached { return cached }

        guard let resolved = loader(), !resolved.isEmpty, resolved != bundleID else {
            return bundleID
        }
        lock.lock()
        values[bundleID] = resolved
        lock.unlock()
        return resolved
    }

    func invalidate(bundleID: String) {
        lock.lock()
        values.removeValue(forKey: bundleID)
        lock.unlock()
    }
}

/// 一个 app「叫什么」的全部已知写法，归一化（trim + lowercase）后存成集合。
///
/// **为什么需要它**：消息区吸收判据是「窗口标题 == 应用名」，而应用名过去每帧现查
/// `NSRunningApplication.runningApplications(withBundleIdentifier:).first?.localizedName`。
/// 那是 LaunchServices 调用，对活着的进程会**瞬时返回空**（同 `ProcessLiveness` 那条硬约束的成因）。
/// 一次抽风 → 主窗口当帧不被吸收 → 该 app 在消息区和实时区各渲染一张卡 → 整行变宽把右边推走，
/// 而且失配态会一直粘到下一次无关重排（实测粘住 2 秒 ~ 79 分钟）。
///
/// 实测 2026-08-11：本机 `Bundle.localizedInfoDictionary` 对飞书/微信解析成英文
/// （`{feishu, lark}` / `{wechat}`），中文标题「飞书」「微信」根本不在包内派生名里，
/// 所以这两个 app **只能**靠那次实时查询——它俩才会成对失配，而 QQ（包内就有 `qq`）从不失配。
///
/// **修法**：名字集合单调只增——包内派生名 ∪ 曾经成功观测到的每一个 `localizedName`。
/// 观测成功过一次，后续任何抽风都不再影响判定；观测成功前每次都重试，
/// 所以「冷启动第一帧恰好抽风」不会把残缺集合当成完整缓存永久钉死（那会比现状更糟）。
///
/// 副作用是省 I/O：观测成功后每帧零 LaunchServices 调用（原先是每帧 × 每个消息应用一次，
/// 且就发生在 `DockStripView.body` 求值里）。
final class AppNameRegistry {
    /// 包内派生名（读 Info.plist，一次性）。返回已归一化的集合。
    private let bundleNamesLoader: (String) -> Set<String>
    /// 当前运行实例的 `localizedName`；进程没跑或 LaunchServices 抽风都返回 nil。
    private let runningNameLoader: (String) -> String?

    private struct Entry {
        var names: Set<String>
        /// 是否已经成功观测到过运行名。false 时每次查询都重试。
        var sawRunningName: Bool
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// 产品别名——**实测过才写，只加不猜**（2026-08-23）：同一个 app 在某种界面语言下给主窗口
    /// 用的另一个品牌名，Info.plist 里查不到、运行名也不是它。微信英文界面（大陆账号）主窗口叫
    /// `Weixin`，而英文系统里这个 app 叫 `WeChat`，两个都不等于「微信」——英文系统 + 大陆账号的
    /// 用户（海外华人）因此进不了消息区、进了也认不出主窗口。已归一化（小写）。
    static let productAliases: [String: Set<String>] = [
        "com.tencent.xinWeChat": ["weixin"],
    ]

    init(bundleNamesLoader: @escaping (String) -> Set<String>,
         runningNameLoader: @escaping (String) -> String?) {
        self.bundleNamesLoader = bundleNamesLoader
        self.runningNameLoader = runningNameLoader
    }

    /// 归一化：去首尾空白 + 小写。空串代表「不是一个名字」，调用方据此直接判不匹配。
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 已知名字全集。未观测到运行名之前会重试 `runningNameLoader`。
    func knownNames(for bundleID: String) -> Set<String> {
        lock.lock()
        let cached = entries[bundleID]
        lock.unlock()

        // 读盘在锁外做。条目缺失才读，读到就一直缓存着。
        var entry = cached ?? Entry(names: baseNames(for: bundleID), sawRunningName: false)

        // 还没见过运行名 → 再试一次。见过就再也不查，抽风也影响不到已记住的名字。
        if !entry.sawRunningName {
            let normalized = runningNameLoader(bundleID).map(Self.normalize)
            if let normalized, !normalized.isEmpty {
                entry.names.insert(normalized)
                entry.sawRunningName = true
            }
        }

        return commit(entry, for: bundleID)
    }

    /// 并发下两个线程可能各自算出一份 entry；**合并而不是覆盖**，免得后写的那份把先写的
    /// 观测结果抹掉（集合单调只增，合并总是安全的）。返回合并后的名字集合。
    @discardableResult
    private func commit(_ entry: Entry, for bundleID: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var merged = entry
        if let existing = entries[bundleID] {
            merged.names.formUnion(existing.names)
            merged.sawRunningName = merged.sawRunningName || existing.sawRunningName
        }
        entries[bundleID] = merged
        return merged.names
    }

    /// 外部直接送来的名字（如 `NSWorkspace` 启动通知里现成的 `NSRunningApplication`），
    /// 免掉一次查询。同样单调只增。
    func observe(name raw: String, for bundleID: String) {
        let normalized = Self.normalize(raw)
        guard !normalized.isEmpty else { return }

        lock.lock()
        let existing = entries[bundleID]
        lock.unlock()

        // 首次见到这个 bundle 时得把包内名一起带上——`knownNames` 只在条目缺失时读盘，
        // 若这里只塞运行名，包内名就永远补不上了。读盘在锁外做。
        var names = existing?.names ?? baseNames(for: bundleID)
        names.insert(normalized)
        commit(Entry(names: names, sawRunningName: true), for: bundleID)
    }

    /// 包内派生名 ∪ 产品别名：条目首次建立时的起点，两条建条目的路径都必须走这里。
    private func baseNames(for bundleID: String) -> Set<String> {
        bundleNamesLoader(bundleID).union(Self.productAliases[bundleID] ?? [])
    }

    func matches(title: String, bundleID: String) -> Bool {
        let normalized = Self.normalize(title)
        guard !normalized.isEmpty else { return false }
        return knownNames(for: bundleID).contains(normalized)
    }

    func invalidate(bundleID: String) {
        lock.lock()
        entries.removeValue(forKey: bundleID)
        lock.unlock()
    }
}
