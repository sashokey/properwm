import AppKit
import XCTest

@MainActor
final class OverlaySpaceHostTests: XCTestCase {
    @MainActor
    private final class Backend {
        var created = 0
        var prepared: [UInt64] = []
        var released: [UInt64] = []
        var members: Set<Int> = []
        var windowMoves: [[Int]] = []
        var failCreation = false
        var isVisible: Bool? = true
        var failPin = false

        func makeHost() -> OverlaySpaceHost {
            OverlaySpaceHost(operations: .init(create: {
                self.created += 1
                return self.failCreation ? 0 : UInt64(self.created)
            }, prepare: {
                self.prepared.append($0)
            }, isVisible: { _ in self.isVisible }, addWindows: { _, windows in
                self.windowMoves.append(windows)
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

    func testUnconfirmedSpaceIsReleasedBeforeAnyWindowIsMoved() {
        let backend = Backend()
        backend.isVisible = false
        let host = backend.makeHost()

        XCTAssertFalse(host.pin(windowNumbers: [10]))
        XCTAssertEqual(backend.released, [1])
        XCTAssertTrue(backend.windowMoves.isEmpty)
        XCTAssertFalse(host.isPinned(windowNumber: 10))

        backend.isVisible = true
        XCTAssertTrue(host.pin(windowNumbers: [10]))
        XCTAssertEqual(backend.prepared, [1, 2])
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

    func testCachedWindowPinDoesNotSurviveLossOfOverlayVisibility() {
        let backend = Backend()
        let host = backend.makeHost()
        XCTAssertTrue(host.pin(windowNumbers: [10]))

        backend.isVisible = false
        XCTAssertFalse(host.pin(windowNumbers: [10]))
        XCTAssertEqual(backend.released, [1])
        XCTAssertFalse(host.isPinned(windowNumber: 10))
        XCTAssertEqual(backend.windowMoves, [[10]])
    }

    func testNewWindowsAreNotMovedIntoAnInvisibleExistingSpace() {
        let backend = Backend()
        let host = backend.makeHost()
        XCTAssertTrue(host.pin(windowNumbers: [10]))

        backend.isVisible = false
        XCTAssertFalse(host.pin(windowNumbers: [20]))
        XCTAssertEqual(backend.released, [1])
        XCTAssertEqual(backend.windowMoves, [[10]])
    }

    func testUnknownOverlayVisibilityDoesNotReleaseItOrMoveNewWindows() {
        let backend = Backend()
        let host = backend.makeHost()
        XCTAssertTrue(host.pin(windowNumbers: [10]))

        backend.isVisible = nil
        XCTAssertFalse(host.pin(windowNumbers: [20]))
        XCTAssertTrue(backend.released.isEmpty)
        XCTAssertEqual(backend.windowMoves, [[10]])

        backend.isVisible = true
        XCTAssertTrue(host.pin(windowNumbers: [10, 20]))
        XCTAssertEqual(backend.windowMoves, [[10], [20]])
    }

    func testConfirmedVisibilityLossRestoresPreviouslyPinnedPanels() async {
        let backend = Backend()
        let host = backend.makeHost()
        let panels = (0..<2).map { _ in
            let panel = NSPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = PanelCollectionBehavior.standard
            return panel
        }
        XCTAssertTrue(host.pin(panels: [panels[0]]))
        XCTAssertTrue(host.pin(panels: [panels[1]]))

        backend.isVisible = false
        host.reconcileVisibility()
        XCTAssertEqual(backend.released, [1])
        XCTAssertEqual(panels.map(\.collectionBehavior), [[], []])
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let standard: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        XCTAssertEqual(panels.map(\.collectionBehavior), [standard, standard])
        XCTAssertTrue(panels.allSatisfy { !host.isPinned(windowNumber: $0.windowNumber) && !$0.isVisible })
    }
}
