import Combine
import Foundation

/// 授权状态。只有两个——**没有**"试用中""已过期""待验证"。
/// 试用期是另一条独立的本地时间戳逻辑，不挂在授权码上（`Docs/27`《收费模式：买断制》）。
enum LicenseState: Equatable {
    case unactivated
    case activated(LicensePayload)

    var payload: LicensePayload? {
        if case .activated(let payload) = self { return payload }
        return nil
    }
}

/// 本机的授权凭据。**存的是授权码原文，不是"已激活"这个布尔值**——
/// 每次启动都拿公钥重新验一遍再显示，所以直接改 plist 塞一个 `true` 是没用的
///（能伪造的只有签名，而那需要私钥）。
///
/// 离线验证、不联网、不绑设备：产品决策见 `Docs/27`。格式契约见 `Docs/31-licensing.md`。
@MainActor
final class LicenseStore: ObservableObject {
    /// ⚠️ 这个键名进了用户磁盘。**改名 = 所有已激活用户回到未激活**，得重新粘一次授权码。
    /// 前缀沿用 `InstallationRecord`。
    static let licenseKeyDefaultsKey = "com.tungsten.edge.licenseKey"

    /// 授权码发放还没开始（`licenses` 表 0 条，1.0 才发）。
    ///
    /// 为 false 时「授权」页**只说明现状，不显示输入框和激活按钮**——在没有任何授权码
    /// 存在的时候摆一个「粘贴授权码」的输入框，等于告诉用户「你手上该有一串码」，
    /// 2026-08-25 因此收到反馈「邮箱并没有收到激活码」。
    ///
    /// **1.0 开始发放时翻成 true**，同时把设置页那句「将在 1.0 正式版开放」改回去——
    /// 两处是一件事，只改一处就又会出现「界面和现实对不上」。
    ///
    /// 已接受的后果：停在 0.9.x 不升级的用户，拿到授权码后得先升到 1.0 才有地方粘。
    static let isIssuingLicenses = false

    @Published private(set) var state: LicenseState

    private let defaults: UserDefaults
    private let publicKey: Data

    init(
        defaults: UserDefaults = .standard,
        publicKey: Data = LicenseVerifier.productionPublicKey
    ) {
        self.defaults = defaults
        self.publicKey = publicKey
        let stored = defaults.string(forKey: Self.licenseKeyDefaultsKey)
        // 存着一条验不过的码（换过公钥、plist 被手改）时静默回到未激活，
        // 不弹窗也不清盘：留着原文，将来换回公钥或修好发放端还能自愈。
        if let stored, case .success(let payload) = LicenseVerifier.verify(code: stored, publicKey: publicKey) {
            state = .activated(payload)
        } else {
            state = .unactivated
        }
    }

    /// 用户粘进来一条授权码。验过才落盘——不合法的东西不进 UserDefaults。
    @discardableResult
    func activate(code: String) -> Result<LicensePayload, LicenseVerificationError> {
        let result = LicenseVerifier.verify(code: code, publicKey: publicKey)
        if case .success(let payload) = result {
            // 落盘的是去掉空白之后的形态，和验证时用的是同一串字节。
            defaults.set(code.filter { !$0.isWhitespace }, forKey: Self.licenseKeyDefaultsKey)
            state = .activated(payload)
        }
        return result
    }
}
