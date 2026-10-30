import CryptoKit
import Foundation
import XCTest
@testable import macos_dock_cc_v2

/// 离线授权码的验证。
///
/// ⚠️ 这里用的密钥与授权码**逐字节抄自 `Docs/31-licensing.md`「测试向量」一节**，
/// 不是临时生成的——发放端要拿同一对密钥对同一条码做交叉验证。
/// 改动这些常量 = 改动应用端与发放端之间的契约，必须同步改那份文档。
final class LicenseVerifierTests: XCTestCase {

    /// TEST ONLY 公钥（32 字节 raw，base64）。**不是**正式公钥。
    private static let testPublicKeyBase64 = "UniWyTOOsQme4j2oj6+11U1JI/xaVfQxtt3KtuTtzeg="

    /// TEST ONLY 私钥 seed，用来在测试里现签一条码（覆盖"合法但不是文档那条"的路径）。
    private static let testSeedBase64 = "00bBTqBWpVsPxVmYBwMAgLm2H/qEtb+kOBnnBIZWfU4="

    /// 文档里那条完整样例：kind=founding、plan=lifetime、email=founder@example.com。
    private static let sampleLicense = "eyJ2IjoxLCJpZCI6IjZGM0IxQzJBLThENDUtNEU5QS1CMEM3LTE1RTJEM0E0N0Y4MCIsImVtYWlsIjoiZm91bmRlckBleGFtcGxlLmNvbSIsImtpbmQiOiJmb3VuZGluZyIsInBsYW4iOiJsaWZldGltZSIsImlzc3VlZF9hdCI6MTc1NjAwMDAwMH0.d3Ltz9GRO04VDKqg7bMOdLCYo1rT8ieeXSEyRFqXIpGujI0KGpTF8wRCHLxAqwMyM61poQoBBAXqCKK79eq_DQ"

    private var testPublicKey: Data { Data(base64Encoded: Self.testPublicKeyBase64)! }

    // MARK: 合法

    func testDocumentedSampleVerifiesAndParses() {
        guard case .success(let payload) = LicenseVerifier.verify(
            code: Self.sampleLicense,
            publicKey: testPublicKey
        ) else {
            return XCTFail("Docs/31 的样例授权码必须验得过")
        }

        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.id, "6F3B1C2A-8D45-4E9A-B0C7-15E2D3A47F80")
        XCTAssertEqual(payload.email, "founder@example.com")
        XCTAssertEqual(payload.kind, .founding)
        XCTAssertEqual(payload.plan, "lifetime")
        XCTAssertEqual(payload.issuedAt, Date(timeIntervalSince1970: 1_756_000_000))
    }

    /// 用户从邮件里复制常常带上换行和尾随空格，这类码必须照样能用。
    func testWhitespaceAroundAndInsideTheCodeIsIgnored() {
        let messy = "  \n" + Self.sampleLicense.prefix(40) + " \n " + Self.sampleLicense.dropFirst(40) + "\n"
        guard case .success(let payload) = LicenseVerifier.verify(code: messy, publicKey: testPublicKey) else {
            return XCTFail("带空白的粘贴结果必须仍然可用")
        }
        XCTAssertEqual(payload.email, "founder@example.com")
    }

    func testFreshlySignedPaidLicenseVerifies() {
        let json = #"{"v":1,"id":"A","email":"buyer@example.com","kind":"paid","plan":"lifetime","issued_at":1756000001}"#
        guard case .success(let payload) = LicenseVerifier.verify(
            code: signedCode(payloadJSON: json),
            publicKey: testPublicKey
        ) else {
            return XCTFail("现签的 paid 授权码必须验得过")
        }
        XCTAssertEqual(payload.kind, .paid)
    }

    /// 前向兼容：多出来的字段被忽略，不影响验证。
    func testUnknownPayloadFieldsAreIgnored() {
        let json = #"{"v":1,"id":"A","email":"a@b.c","kind":"paid","plan":"lifetime","issued_at":1,"seats":5}"#
        guard case .success = LicenseVerifier.verify(code: signedCode(payloadJSON: json), publicKey: testPublicKey) else {
            return XCTFail("未知字段不该让验证失败")
        }
    }

    // MARK: 篡改

    /// 改 payload 里一个字符（把邮箱的首字母换掉）——签名立刻对不上。
    func testTamperedPayloadFailsSignature() {
        let tampered = replacingOneCharacter(in: Self.sampleLicense, segment: 0)
        assertFails(tampered, with: [.badSignature, .malformedEncoding])
    }

    /// 改签名里一个字符。
    func testTamperedSignatureFails() {
        let tampered = replacingOneCharacter(in: Self.sampleLicense, segment: 1)
        assertFails(tampered, with: [.badSignature, .malformedEncoding])
    }

    /// 用正式公钥去验一条测试私钥签的码——必须拒绝。
    /// 这条同时锁住"内嵌公钥真的参与了判定"，而不是签名被当成装饰。
    func testWrongPublicKeyRejectsAValidlySignedCode() {
        assertFails(
            Self.sampleLicense,
            publicKey: LicenseVerifier.productionPublicKey,
            with: [.badSignature]
        )
    }

    // MARK: 格式

    func testFormatErrors() {
        assertFails("", with: [.malformedFormat])
        assertFails("no-dot-at-all", with: [.malformedFormat])
        assertFails("a.b.c", with: [.malformedFormat])
        assertFails(".xyz", with: [.malformedFormat])
        assertFails("xyz.", with: [.malformedFormat])
        // 两段都是合法 base64url，但签名不是 64 字节。
        assertFails("aGVsbG8.aGVsbG8", with: [.malformedEncoding])
        // 非 base64url 字符。
        assertFails("!!!!.\(String(repeating: "A", count: 86))", with: [.malformedEncoding])
    }

    func testSignedButNonJSONPayloadIsMalformed() {
        assertFails(signedCode(payloadJSON: "not json at all"), with: [.malformedPayload])
    }

    func testMissingFieldIsMalformed() {
        assertFails(
            signedCode(payloadJSON: #"{"v":1,"id":"A","kind":"paid","plan":"lifetime","issued_at":1}"#),
            with: [.malformedPayload]
        )
    }

    func testUnsupportedVersionKindAndPlanAreRejected() {
        assertFails(
            signedCode(payloadJSON: #"{"v":2,"id":"A","email":"a@b.c","kind":"paid","plan":"lifetime","issued_at":1}"#),
            with: [.unsupportedVersion(2)]
        )
        assertFails(
            signedCode(payloadJSON: #"{"v":1,"id":"A","email":"a@b.c","kind":"team","plan":"lifetime","issued_at":1}"#),
            with: [.unsupportedKind("team")]
        )
        assertFails(
            signedCode(payloadJSON: #"{"v":1,"id":"A","email":"a@b.c","kind":"paid","plan":"annual","issued_at":1}"#),
            with: [.unsupportedPlan("annual")]
        )
    }

    /// 正式公钥常量必须是一把真能用的 Ed25519 公钥（32 字节、可构造）。
    /// 被改坏时这条会先响，而不是留给用户在设置窗口里撞上。
    func testProductionPublicKeyIsWellFormed() {
        let key = LicenseVerifier.productionPublicKey
        XCTAssertEqual(key.count, 32)
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: key))
    }

    // MARK: 工具

    private func signedCode(payloadJSON: String) -> String {
        let seed = Data(base64Encoded: Self.testSeedBase64)!
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let bytes = Data(payloadJSON.utf8)
        let signature = try! key.signature(for: bytes)
        return "\(base64URL(bytes)).\(base64URL(signature))"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 把某一段里的一个字符换成另一个合法 base64url 字符。
    private func replacingOneCharacter(in code: String, segment: Int) -> String {
        var parts = code.split(separator: ".").map(String.init)
        var chars = Array(parts[segment])
        let index = chars.count / 2
        chars[index] = chars[index] == "A" ? "B" : "A"
        parts[segment] = String(chars)
        return parts.joined(separator: ".")
    }

    private func assertFails(
        _ code: String,
        publicKey: Data? = nil,
        with expected: [LicenseVerificationError],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = LicenseVerifier.verify(code: code, publicKey: publicKey ?? testPublicKey)
        switch result {
        case .success:
            XCTFail("这条授权码不该通过验证：\(code.prefix(30))…", file: file, line: line)
        case .failure(let error):
            XCTAssertTrue(
                expected.contains(error),
                "期望 \(expected) 之一，实际 \(error)",
                file: file,
                line: line
            )
        }
    }
}
