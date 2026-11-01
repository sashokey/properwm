import XCTest

final class WindowSpaceVisibilityTests: XCTestCase {
    private let window = WindowSpaceIdentity(itemID: "browser", pid: 42, windowID: 100)
    private let other = WindowSpaceIdentity(itemID: "editor", pid: 43, windowID: 101)

    private func layout(_ current: Int, spaces: [Int] = [1, 2, 3], fullscreen: Set<Int> = [3]) -> SpaceLayoutSnapshot {
        SpaceLayoutSnapshot(orderedSpaceIDs: spaces, fullscreenSpaceIDs: fullscreen, currentSpaceID: current)
    }

    func testFullscreenWindowIsExcludedFromOriginalDesktopAndReturnsAfterLeavingFullscreen() {
        var snapshot = WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: [1]])
        XCTAssertTrue(snapshot.shows(window, on: "left"))
        snapshot.memberships[window] = [3]
        XCTAssertFalse(snapshot.shows(window, on: "left"))
        snapshot.memberships[window] = [1]
        XCTAssertTrue(snapshot.shows(window, on: "left"))
    }

    func testEachMonitorUsesItsOwnCurrentSpaceAndAllSpaceWindowsRemainVisible() {
        let snapshot = WindowSpaceSnapshot(layouts: ["left": layout(1), "right": layout(10, spaces: [10, 11])],
            memberships: [window: [2], other: [10]])
        XCTAssertFalse(snapshot.shows(window, on: "left"))
        XCTAssertFalse(snapshot.shows(other, on: "left"))
        XCTAssertTrue(snapshot.shows(other, on: "right"))
        var sticky = snapshot
        sticky.memberships[window] = [1, 2]
        XCTAssertTrue(sticky.shows(window, on: "left"))
    }

    func testMinimizingPreservesLastSpaceButDoesNotFollowUserToAnotherSpace() {
        let original = WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: [1]])
        let parked = WindowSpaceRequest(identity: window, isParked: true, isOnDesktop: false)
        let moved = original.updating(with: WindowSpaceSnapshot(layouts: ["left": layout(2)], memberships: [window: []]), requests: [parked])
        XCTAssertEqual(moved.memberships[window], [1])
        XCTAssertFalse(moved.shows(window, on: "left"))
        let returned = moved.updating(with: WindowSpaceSnapshot(layouts: ["left": layout(1)]), requests: [parked])
        XCTAssertTrue(returned.shows(window, on: "left"))
    }

    func testFailedReadsKeepKnownMembershipAndRetiredWindowsArePruned() {
        let original = WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: [2], other: [1]])
        let request = WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: false)
        let failed = original.updating(with: nil, requests: [request])
        XCTAssertFalse(failed.shows(window, on: "left"))
        XCTAssertNil(failed.memberships[other])
        let partial = failed.updating(with: WindowSpaceSnapshot(layouts: ["left": layout(1)]), requests: [request])
        XCTAssertFalse(partial.shows(window, on: "left"))
    }

    func testChangedWindowIdentityDoesNotInheritRetiredMembership() {
        let replacement = WindowSpaceIdentity(itemID: window.itemID, pid: window.pid, windowID: 200)
        let snapshot = WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: [2]])
        let updated = snapshot.updating(with: nil, requests: [WindowSpaceRequest(identity: replacement, isParked: false, isOnDesktop: true)])
        XCTAssertNil(updated.memberships[window])
        XCTAssertTrue(updated.shows(replacement, on: "left"))
    }

    func testSharedSpacesUseTheMainLayoutForBothDisplays() {
        let snapshot = WindowSpaceSnapshot(layouts: ["Main": layout(2)], memberships: [window: [1], other: [2]])
        for display in ["left", "right"] {
            XCTAssertFalse(snapshot.shows(window, on: display))
            XCTAssertTrue(snapshot.shows(other, on: display))
        }
    }

    func testEmptyMembershipForAnOrdinaryWindowIsNotTheCurrentSpace() {
        let request = WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: false)
        let updated = WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: [1]])
            .updating(with: WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: []]), requests: [request])
        XCTAssertFalse(updated.shows(window, on: "left"))
    }

    func testLayoutParsingPreservesDisplayIdentityAndFullscreenType() throws {
        let layouts = try XCTUnwrap(ManagedSpaceLayoutReader.parse([
            ["Display Identifier": "left", "Current Space": ["ManagedSpaceID": 3],
             "Spaces": [["ManagedSpaceID": 1, "type": 0], ["ManagedSpaceID": 3, "type": 4]]],
            ["Display Identifier": "right", "Current Space": ["id64": 10],
             "Spaces": [["id64": 10, "type": 0], ["id64": 11, "type": 0]]]
        ]))
        XCTAssertEqual(layouts["left"]?.currentSpaceID, 3)
        XCTAssertEqual(layouts["left"]?.fullscreenSpaceIDs, [3])
        XCTAssertEqual(layouts["right"]?.currentSpaceID, 10)
        XCTAssertEqual(layouts["right"]?.fullscreenSpaceIDs, [])
    }

    func testInconsistentLayoutIsUnknownRatherThanAWindowedDesktop() {
        XCTAssertNil(ManagedSpaceLayoutReader.parse([]))
        XCTAssertNil(ManagedSpaceLayoutReader.parse([["Display Identifier": "left",
            "Current Space": ["ManagedSpaceID": 3], "Spaces": [["ManagedSpaceID": 1, "type": 0]]]]))
        XCTAssertNil(ManagedSpaceLayoutReader.parse([["Display Identifier": "left", "Spaces": []]]))
    }
}
