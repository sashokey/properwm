import XCTest

@MainActor
final class OverlaySpaceHostTests: XCTestCase {
    @MainActor
    private final class Backend {
        var created = 0
        var prepared: [UInt64] = []
        var released: [UInt64] = []
        var members: Set<Int> = []
        var failCreation = false
        var failPin = false

        func makeHost() -> OverlaySpaceHost {
            OverlaySpaceHost(operations: .init(create: {
                self.created += 1
                return self.failCreation ? 0 : UInt64(self.created)
            }, prepare: { self.prepared.append($0) }, addWindows: { _, windows in
                if !self.failPin { self.members.formUnion(windows) }
            }, spaces: { self.members.contains($0) ? [UInt64(self.created)] : [] }, release: {
                self.released.append($0)
                self.members.removeAll()
            }))
        }
    }

    func testUnusedHostCreatesAndReleasesNoSpace() {
        let backend = Backend()
        var host: OverlaySpaceHost? = backend.makeHost()
        XCTAssertFalse(host!.pin(windowNumbers: [0, -1]))
        host = nil
        XCTAssertEqual(backend.created, 0)
        XCTAssertTrue(backend.released.isEmpty)
    }

    func testExplicitReleaseIsIdempotentAndHostCanBeReused() {
        let backend = Backend()
        var host: OverlaySpaceHost? = backend.makeHost()
        XCTAssertTrue(host!.pin(windowNumbers: [10]))
        XCTAssertTrue(host!.pin(windowNumbers: [10, 20]))
        XCTAssertEqual(backend.created, 1)
        host!.tearDown()
        host!.tearDown()
        XCTAssertEqual(backend.released, [1])
        XCTAssertTrue(host!.pin(windowNumbers: [30]))
        XCTAssertEqual(backend.prepared, [1, 2])
        host = nil
        XCTAssertEqual(backend.released, [1, 2])
    }

    func testFailedCreationAndFailedReadbackAreNotReportedAsSuccess() {
        let backend = Backend()
        backend.failCreation = true
        var host: OverlaySpaceHost? = backend.makeHost()
        XCTAssertFalse(host!.pin(windowNumbers: [10]))
        XCTAssertTrue(backend.prepared.isEmpty)
        backend.failCreation = false
        backend.failPin = true
        XCTAssertFalse(host!.pin(windowNumbers: [10]))
        host = nil
        XCTAssertEqual(backend.released, [2])
    }
}
