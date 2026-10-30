import Foundation

/// 记录这台机器**第一次运行钨极**的时间。写一次，之后永不覆盖。
///
/// ## 为什么需要它
///
/// 钨极将来会从免费转成买断收费，届时承诺「公告日之前就在用的人永久免费」。
/// 兑现这个承诺需要一个能**自动**判定老用户的凭据。
///
/// 只靠邮箱名单不够：真实老用户里愿意留邮箱的是少数，剩下多数人会发现自己被排除在外——
/// 而那正是这条承诺本来要避免的怨气。所以主凭据是这个本地时间戳（自动、用户无感），
/// 邮箱名单只作换机 / 重装后的补发通道。
///
/// ## 两个已知且接受的边界
///
/// - **已经在用的老用户**升级到带这个键的版本时，写入的是「升级日」而不是真实首装日。
///   可以接受：它仍然早于将来的收费公告日，判定结果不受影响。
/// - **能被伪造**：改 plist 就能改。**不要为此加服务端验证**——会改 plist 的人本来就不是
///   目标客群，而且被伪造走的也只是本来就免费的那部分用户，不划算。
///
/// 删除 app 不会清掉 UserDefaults，所以重装能保留；换机器才会丢，那由邮箱名单兜底。
enum InstallationRecord {
    /// ⚠️ 这个键名进了用户磁盘。**改名 = 把所有老用户的首装记录清零**，
    /// 他们会在转收费时被误判成新用户。要改必须写迁移。
    static let firstLaunchDateKey = "com.tungsten.edge.firstLaunchDate"

    static func firstLaunchDate(defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: firstLaunchDateKey) as? Date
    }

    /// 首次调用写入 `now` 并返回它；此后每次调用都原样返回最早那个值。
    ///
    /// **「已存在就绝不覆盖」是这个类型的全部意义**——一旦某次启动把它刷成今天，
    /// 这台机器的老用户身份就永久丢失且无法恢复。
    @discardableResult
    static func recordFirstLaunchIfNeeded(
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Date {
        if let existing = firstLaunchDate(defaults: defaults) {
            return existing
        }
        defaults.set(now, forKey: firstLaunchDateKey)
        return now
    }
}
