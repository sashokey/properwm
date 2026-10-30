import XCTest
@testable import macos_dock_cc_v2

/// 首次启动时间戳。
///
/// 这个类型只有一条真正重要的性质：**写一次之后永不覆盖**。它是将来转收费时
/// 「公告日之前就在用的人永久免费」唯一能自动判定的凭据——一旦某次启动把它刷成今天，
/// 这台机器的老用户身份就永久丢失，而且无法从任何地方恢复。
/// 所以下面的覆盖测试不是走过场，它锁的是一个不可逆的用户承诺。
final class InstallationRecordTests: XCTestCase {

    func testFirstCallRecordsNowAndReturnsIt() {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertNil(InstallationRecord.firstLaunchDate(defaults: defaults))

        let recorded = InstallationRecord.recordFirstLaunchIfNeeded(defaults: defaults, now: now)

        XCTAssertEqual(recorded, now)
        XCTAssertEqual(InstallationRecord.firstLaunchDate(defaults: defaults), now)
    }

    /// 回归锁：后续启动**绝不能**覆盖最早那个值。
    func testLaterLaunchesNeverOverwriteTheOriginalDate() {
        let defaults = makeDefaults()
        let firstLaunch = Date(timeIntervalSince1970: 1_000_000)
        let muchLater = Date(timeIntervalSince1970: 9_000_000)

        InstallationRecord.recordFirstLaunchIfNeeded(defaults: defaults, now: firstLaunch)

        // 模拟之后的每一次启动
        let secondLaunch = InstallationRecord.recordFirstLaunchIfNeeded(defaults: defaults, now: muchLater)
        let thirdLaunch = InstallationRecord.recordFirstLaunchIfNeeded(defaults: defaults, now: Date())

        XCTAssertEqual(secondLaunch, firstLaunch)
        XCTAssertEqual(thirdLaunch, firstLaunch)
        XCTAssertEqual(InstallationRecord.firstLaunchDate(defaults: defaults), firstLaunch)
    }

    /// 老用户升级到本版时写入的是「升级日」而不是真实首装日——这是已知且接受的边界，
    /// 因为它仍然早于将来的收费公告日。这条测试把这个语义写死，免得有人当 bug 去「修」。
    func testExistingUserUpgradingRecordsUpgradeDayAndThenFreezes() {
        let defaults = makeDefaults()
        let upgradeDay = Date(timeIntervalSince1970: 5_000_000)

        let recorded = InstallationRecord.recordFirstLaunchIfNeeded(defaults: defaults, now: upgradeDay)
        XCTAssertEqual(recorded, upgradeDay)

        InstallationRecord.recordFirstLaunchIfNeeded(defaults: defaults, now: Date(timeIntervalSince1970: 6_000_000))
        XCTAssertEqual(InstallationRecord.firstLaunchDate(defaults: defaults), upgradeDay)
    }

    /// 键名进了用户磁盘，改名等于把所有人的首装记录清零、转收费时全被误判成新用户。
    func testKeyNameIsFrozen() {
        XCTAssertEqual(InstallationRecord.firstLaunchDateKey, "com.tungsten.edge.firstLaunchDate")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.tungsten.edge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
