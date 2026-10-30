import Foundation
import XCTest
@testable import macos_dock_cc_v2

/// 本机授权凭据的存取。
///
/// 关键性质只有两条：**验过才落盘**，以及**每次启动重新验签名**——存的是凭据，
/// 不是"已激活"这个布尔值，所以手改 plist 塞不出一个已激活状态。
@MainActor
final class LicenseStoreTests: XCTestCase {

    /// 与 `LicenseVerifierTests` 同源，逐字节抄自 `Docs/31-licensing.md`。TEST ONLY。
    private static let testPublicKeyBase64 = "UniWyTOOsQme4j2oj6+11U1JI/xaVfQxtt3KtuTtzeg="
    private static let sampleLicense = "eyJ2IjoxLCJpZCI6IjZGM0IxQzJBLThENDUtNEU5QS1CMEM3LTE1RTJEM0E0N0Y4MCIsImVtYWlsIjoiZm91bmRlckBleGFtcGxlLmNvbSIsImtpbmQiOiJmb3VuZGluZyIsInBsYW4iOiJsaWZldGltZSIsImlzc3VlZF9hdCI6MTc1NjAwMDAwMH0.d3Ltz9GRO04VDKqg7bMOdLCYo1rT8ieeXSEyRFqXIpGujI0KGpTF8wRCHLxAqwMyM61poQoBBAXqCKK79eq_DQ"

    private var testPublicKey: Data { Data(base64Encoded: Self.testPublicKeyBase64)! }

    func testStartsUnactivated() {
        let store = makeStore(defaults: makeDefaults())
        XCTAssertEqual(store.state, .unactivated)
    }

    func testActivatingAValidCodePersistsItAndSurvivesRelaunch() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        guard case .success = store.activate(code: Self.sampleLicense) else {
            return XCTFail("样例授权码必须能激活")
        }
        XCTAssertEqual(store.state.payload?.email, "founder@example.com")
        XCTAssertEqual(store.state.payload?.kind, .founding)

        // 重开 app
        let relaunched = makeStore(defaults: defaults)
        XCTAssertEqual(relaunched.state.payload?.email, "founder@example.com")
    }

    func testInvalidCodeIsNotPersisted() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        guard case .failure = store.activate(code: "definitely-not-a-license") else {
            return XCTFail("非法授权码不该被接受")
        }
        XCTAssertEqual(store.state, .unactivated)
        XCTAssertNil(defaults.string(forKey: LicenseStore.licenseKeyDefaultsKey))
        XCTAssertEqual(makeStore(defaults: defaults).state, .unactivated)
    }

    /// 手改 plist 塞一条码进去也没用——启动时照样验签名。
    func testStoredCodeThatDoesNotVerifyFallsBackToUnactivated() {
        let defaults = makeDefaults()
        defaults.set(Self.sampleLicense, forKey: LicenseStore.licenseKeyDefaultsKey)

        // 换一把公钥（正式那把）去读同一条码：验不过。
        let store = LicenseStore(defaults: defaults, publicKey: LicenseVerifier.productionPublicKey)
        XCTAssertEqual(store.state, .unactivated)
        // 原文留着不动：换回对的公钥还能自愈。
        XCTAssertNotNil(defaults.string(forKey: LicenseStore.licenseKeyDefaultsKey))
    }

    /// 键名进了用户磁盘，改名 = 所有已激活用户回到未激活。
    func testKeyNameIsFrozen() {
        XCTAssertEqual(LicenseStore.licenseKeyDefaultsKey, "com.tungsten.edge.licenseKey")
    }

    private func makeStore(defaults: UserDefaults) -> LicenseStore {
        LicenseStore(defaults: defaults, publicKey: testPublicKey)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.tungsten.edge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
