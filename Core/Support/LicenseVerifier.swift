import CryptoKit
import Foundation

/// 授权码的种类。发放端只允许发这两种。
///
/// **陌生取值一律拒绝**（`LicenseVerificationError.unsupportedKind`），不做"当成付费用户"的宽容处理：
/// 将来真要发第三种，得先发一个认识它的应用版本，否则老版本会把它当成有效授权放行。
enum LicenseKind: String, Equatable {
    /// 原始用户（收费公告之前就在用的人，免费发放）。
    case founding
    /// 已付款买断。
    case paid
}

/// 一条授权码里携带的全部内容。格式契约在 `Docs/31-licensing.md`，改字段要连那份文档一起改。
struct LicensePayload: Equatable {
    /// 格式版本，恒 1。
    let version: Int
    /// 这条授权码的编号（发放端做作废/重发的账目用）。**应用端不校验、不上报。**
    let id: String
    /// 购买或确认时的邮箱，只用来显示给用户看「这台机器激活的是谁的授权」。
    let email: String
    let kind: LicenseKind
    /// 恒 `lifetime`（买断终身）。
    let plan: String
    /// 签发时刻。**不是有效期**——离线授权没有过期这回事，见 `Docs/27`。
    let issuedAt: Date

    static let supportedVersion = 1
    static let supportedPlan = "lifetime"
}

enum LicenseVerificationError: Error, Equatable {
    /// 不是 `payload.signature` 两段。
    case malformedFormat
    /// 某一段不是合法 base64url，或签名长度不是 64 字节。
    case malformedEncoding
    /// payload 不是合法 JSON，或缺字段 / 字段类型不对。
    case malformedPayload
    case unsupportedVersion(Int)
    case unsupportedKind(String)
    case unsupportedPlan(String)
    /// 签名对不上公钥——被改过，或者根本不是我们签的。
    case badSignature
    /// 内嵌公钥本身有问题（只可能是代码里那个常量被改坏了）。
    case invalidPublicKey
}

/// 离线授权码的验证。**纯函数**：进去一个字符串加一把公钥，出来解析结果或错误，不碰磁盘、不联网。
///
/// 格式与测试向量在 `Docs/31-licensing.md`；那份文档是应用端与发放端之间的唯一契约，
/// 单测 `LicenseVerifierTests` 用的就是文档里那对固定测试密钥，两边靠它交叉验证。
///
/// **这里刻意没有的东西**（产品决策，`Docs/27`《收费模式：买断制》）：联网激活、设备绑定、
/// 有效期、激活次数、吊销列表。源码是公开的，硬 DRM 一定绕得过，收的是体面人的钱。不要加。
enum LicenseVerifier {

    /// 正式签名公钥（Ed25519，32 字节 raw）。
    ///
    /// ⚠️ 指纹 `056f214892905a3a`（SHA-256 前 8 字节），登记在 `Docs/31-licensing.md`。
    /// 换掉这个常量 = 已经发出去的每一条授权码当场失效，所有付费用户都要重发。
    /// 配对的私钥不可再生，性质等同 Sparkle 那把 EdDSA 私钥；两者**不是同一把**，不要合并。
    static let productionPublicKeyBase64 = "Fn8rCKO1xyQ3Tn/ea77j1iY1DbJGG5TczIPmXBwdSwM="

    static var productionPublicKey: Data {
        Data(base64Encoded: productionPublicKeyBase64) ?? Data()
    }

    /// 验证一条授权码。
    ///
    /// **签名先于解析**：先证明这串字节是我们签的，再去信任里面写的邮箱和种类。
    static func verify(
        code: String,
        publicKey: Data = productionPublicKey
    ) -> Result<LicensePayload, LicenseVerificationError> {
        // 用户从邮件里复制常常带上换行和尾随空格。除去空白之外不做任何清洗——
        // base64url 区分大小写，任何"顺手规范化"都会把合法授权码弄坏。
        let cleaned = code.filter { !$0.isWhitespace }
        let segments = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 2, !segments[0].isEmpty, !segments[1].isEmpty else {
            return .failure(.malformedFormat)
        }

        guard let payloadBytes = decodeBase64URL(String(segments[0])),
              let signature = decodeBase64URL(String(segments[1])),
              signature.count == 64
        else {
            return .failure(.malformedEncoding)
        }

        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return .failure(.invalidPublicKey)
        }
        guard key.isValidSignature(signature, for: payloadBytes) else {
            return .failure(.badSignature)
        }

        return decodePayload(payloadBytes)
    }

    // MARK: 内部

    /// payload 的线上表示。未知字段被忽略（前向兼容），已知字段一个都不能少。
    private struct WirePayload: Decodable {
        let v: Int
        let id: String
        let email: String
        let kind: String
        let plan: String
        let issued_at: Int
    }

    private static func decodePayload(
        _ bytes: Data
    ) -> Result<LicensePayload, LicenseVerificationError> {
        guard let wire = try? JSONDecoder().decode(WirePayload.self, from: bytes) else {
            return .failure(.malformedPayload)
        }
        guard wire.v == LicensePayload.supportedVersion else {
            return .failure(.unsupportedVersion(wire.v))
        }
        guard let kind = LicenseKind(rawValue: wire.kind) else {
            return .failure(.unsupportedKind(wire.kind))
        }
        guard wire.plan == LicensePayload.supportedPlan else {
            return .failure(.unsupportedPlan(wire.plan))
        }
        return .success(
            LicensePayload(
                version: wire.v,
                id: wire.id,
                email: wire.email,
                kind: kind,
                plan: wire.plan,
                issuedAt: Date(timeIntervalSince1970: TimeInterval(wire.issued_at))
            )
        )
    }

    /// base64url（`-` `_`，不带补位）→ 字节。补位是可选的：发放端不带，手工粘贴的可能带。
    private static func decodeBase64URL(_ text: String) -> Data? {
        var normalized = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }
}
