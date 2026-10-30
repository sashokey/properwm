import XCTest
@testable import macos_dock_cc_v2

/// macOS 12 的老登录项路径。真正碰 CoreServices 的 `SharedFileListLoginItems` 在这里用内存列表替掉，
/// 测的是后端的判断：什么时候算开、重复勾选不重复插、取消要清干净、列表打不开时怎么表现。
final class LaunchAtLoginServiceTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/Applications/Tungsten Edge.app")
    private let otherApp = URL(fileURLWithPath: "/Applications/Safari.app")

    // MARK: 读状态

    func testUnavailableListReadsUnsupportedAndRefusesToWrite() {
        let list = LoginItemListStub(urls: nil)
        let backend = LegacyLoginItemBackend(list: list, bundleURL: app)

        XCTAssertEqual(backend.readState(), .unsupported)
        XCTAssertThrowsError(try backend.setEnabled(true))
        XCTAssertTrue(list.inserted.isEmpty)
    }

    func testReadsOnOnlyWhenThisBundleIsListed() {
        XCTAssertEqual(
            LegacyLoginItemBackend(list: LoginItemListStub(urls: []), bundleURL: app).readState(),
            .off
        )
        XCTAssertEqual(
            LegacyLoginItemBackend(list: LoginItemListStub(urls: [otherApp]), bundleURL: app).readState(),
            .off
        )
        XCTAssertEqual(
            LegacyLoginItemBackend(list: LoginItemListStub(urls: [otherApp, app]), bundleURL: app).readState(),
            .on
        )
    }

    func testReadTreatsTrailingSlashVariantAsTheSameBundle() {
        // 列表里存的 URL 带不带结尾斜杠不稳定，不能因此把「已勾选」读成「未勾选」。
        let listed = URL(fileURLWithPath: "/Applications/Tungsten Edge.app/")
        XCTAssertEqual(
            LegacyLoginItemBackend(list: LoginItemListStub(urls: [listed]), bundleURL: app).readState(),
            .on
        )
    }

    // MARK: 写开关

    func testEnableInsertsOnceAndIsIdempotent() throws {
        let list = LoginItemListStub(urls: [otherApp])
        let backend = LegacyLoginItemBackend(list: list, bundleURL: app)

        try backend.setEnabled(true)
        try backend.setEnabled(true)

        XCTAssertEqual(list.inserted, [app])
        XCTAssertEqual(backend.readState(), .on)
    }

    func testDisableRemovesEveryMatchingEntryAndLeavesOthersAlone() throws {
        let duplicate = URL(fileURLWithPath: "/Applications/Tungsten Edge.app/")
        let list = LoginItemListStub(urls: [app, otherApp, duplicate])
        let backend = LegacyLoginItemBackend(list: list, bundleURL: app)

        try backend.setEnabled(false)

        XCTAssertEqual(list.removed, [app, duplicate])
        XCTAssertEqual(list.urls, [otherApp])
        XCTAssertEqual(backend.readState(), .off)
    }

    func testDisableWhenNotListedIsANoOp() throws {
        let list = LoginItemListStub(urls: [otherApp])
        let backend = LegacyLoginItemBackend(list: list, bundleURL: app)

        try backend.setEnabled(false)

        XCTAssertTrue(list.removed.isEmpty)
        XCTAssertTrue(list.inserted.isEmpty)
    }

    func testListErrorsPropagateUnchanged() {
        let list = LoginItemListStub(urls: [])
        list.error = LaunchAtLoginError.writeFailed
        let backend = LegacyLoginItemBackend(list: list, bundleURL: app)

        XCTAssertThrowsError(try backend.setEnabled(true)) { error in
            guard case LaunchAtLoginError.writeFailed = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    // MARK: URL 匹配

    func testMatcherIgnoresTrailingSlashAndNormalizesPath() {
        XCTAssertTrue(LoginItemURLMatcher.matches(
            URL(fileURLWithPath: "/Applications/Tungsten Edge.app/"),
            URL(fileURLWithPath: "/Applications/Tungsten Edge.app")
        ))
        XCTAssertTrue(LoginItemURLMatcher.matches(
            URL(fileURLWithPath: "/Applications/Utilities/../Tungsten Edge.app"),
            URL(fileURLWithPath: "/Applications/Tungsten Edge.app")
        ))
    }

    func testMatcherRejectsOtherBundlesAndLookalikePrefixes() {
        XCTAssertFalse(LoginItemURLMatcher.matches(app, otherApp))
        // 前缀相同不算同一个包。
        XCTAssertFalse(LoginItemURLMatcher.matches(
            URL(fileURLWithPath: "/Applications/Tungsten Edge.app"),
            URL(fileURLWithPath: "/Applications/Tungsten Edge.app.bak")
        ))
    }

    // MARK: 服务层只是个后台队列包装

    @MainActor
    func testServiceReadsAndWritesThroughTheInjectedBackend() async throws {
        let list = LoginItemListStub(urls: [app])
        let service = LaunchAtLoginService(backend: LegacyLoginItemBackend(list: list, bundleURL: app))

        let state = await service.currentState()
        XCTAssertEqual(state, .on)

        try service.setEnabled(false)
        XCTAssertEqual(list.removed, [app])
        let after = await service.currentState()
        XCTAssertEqual(after, .off)
    }
}

private final class LoginItemListStub: LoginItemListing, @unchecked Sendable {
    var urls: [URL]?
    var inserted: [URL] = []
    var removed: [URL] = []
    var error: Error?

    init(urls: [URL]?) {
        self.urls = urls
    }

    func itemURLs() -> [URL]? { urls }

    func insert(_ url: URL) throws {
        if let error { throw error }
        inserted.append(url)
        urls?.append(url)
    }

    func remove(_ url: URL) throws {
        if let error { throw error }
        removed.append(url)
        urls?.removeAll { $0 == url }
    }
}
