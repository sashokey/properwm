import XCTest
import Synchronization

private func identity(_ itemID: String, pid: Int32, windowID: UInt32, targetID: UUID? = nil) -> WindowSpaceIdentity {
    WindowSpaceIdentity(.init(windowID: WindowID(rawValue: itemID), pid: pid, processGeneration: nil,
        cgWindowID: windowID, groupID: itemID, targetID: targetID))!
}

final class WindowSpaceVisibilityTests: XCTestCase {
    private let window = identity("browser", pid: 42, windowID: 100)
    private let other = identity("editor", pid: 43, windowID: 101)

    private func layout(_ current: Int, spaces: [Int] = [1, 2, 3], fullscreen: Set<Int> = [3]) -> SpaceLayoutSnapshot {
        SpaceLayoutSnapshot(orderedSpaceIDs: spaces, fullscreenSpaceIDs: fullscreen, currentSpaceID: current)
    }

    func testCaptureStopsBetweenMembershipRequestsOnCancellationOrDeadline() {
        let requests = [window, other].map { WindowSpaceRequest(identity: $0, isParked: false, isOnDesktop: true) }
        let expectedLayout = ["left": layout(1)]
        for expires in [false, true] {
            let cancellation = OperationCancellation()
            let now = Mutex<TimeInterval>(100)
            var reads = 0
            let result = WindowSpaceObservation.capture(requests, cancellation: cancellation, maximumDuration: 1,
                uptime: { now.withLock { $0 } }, layouts: { expectedLayout }, membership: { _ in
                    reads += 1
                    if expires { now.withLock { $0 = 102 } } else { cancellation.cancel() }
                    return [1]
                })
            XCTAssertNil(result)
            XCTAssertEqual(reads, 1)
        }
    }

    func testCaptureSharesMembershipForRequestsWithTheSameWindowNumber() {
        let alternate = identity("alternate", pid: window.actionIdentity.pid, windowID: window.windowID)
        let requests = [window, alternate].map {
            WindowSpaceRequest(identity: $0, isParked: false, isOnDesktop: true)
        }
        var calls: [Int] = []
        let snapshot = WindowSpaceObservation.capture(
            requests, cancellation: OperationCancellation(), layouts: { ["left": layout(1)] }, membership: { number in
                calls.append(number)
                return [1, 2]
            }
        )
        XCTAssertEqual(calls, [Int(window.windowID)])
        XCTAssertEqual(snapshot?.memberships, [window: [1, 2], alternate: [1, 2]])
    }

    func testBatchMapsStickyWindowsAndFallsBackForParkedAndMissingWindows() {
        let sticky = window
        let regular = other
        let missing = identity("missing", pid: 43, windowID: 102)
        let parked = identity("parked", pid: 43, windowID: 103)
        let requests = [sticky, regular, missing, parked].map {
            WindowSpaceRequest(identity: $0, isParked: $0 == parked, isOnDesktop: $0 != parked)
        }
        var scalarReads: [Int] = []
        var spaceReads: [Int] = []
        let snapshot = WindowSpaceObservation.capture(
            requests, cancellation: OperationCancellation(),
            layouts: { ["left": layout(1, spaces: [1, 2], fullscreen: [])] },
            membership: { number in
                scalarReads.append(number)
                return number == 103 ? [2] : nil
            },
            mode: .batch, windowsInSpace: { space in
                spaceReads.append(space)
                return space == 1 ? [100, 101, 103] : [100]
            }
        )
        XCTAssertEqual(spaceReads, [1, 2])
        XCTAssertEqual(scalarReads, [102, 103])
        XCTAssertEqual(snapshot?.memberships, [sticky: [1, 2], regular: [1], parked: [2]])
    }

    func testBatchVerificationAndMissingSpaceResultKeepAuthoritativeValues() {
        let third = identity("third", pid: 43, windowID: 102)
        let requests = [window, other, third].map {
            WindowSpaceRequest(identity: $0, isParked: false, isOnDesktop: true)
        }
        for mode in [WindowSpaceObservation.Mode.verify, .batch] {
            var scalarReads: [Int] = []
            let result = WindowSpaceObservation.capture(
                requests, cancellation: OperationCancellation(),
                layouts: { ["left": layout(1, spaces: [1, 2], fullscreen: [])] },
                membership: { number in
                    scalarReads.append(number)
                    return [2]
                },
                mode: mode,
                windowsInSpace: { space in
                    mode == .batch && space == 2 ? nil : (space == 1 ? [100, 101, 102] : [])
                }
            )
            XCTAssertEqual(scalarReads, [100, 101, 102])
            XCTAssertEqual(result?.memberships, [window: [2], other: [2], third: [2]])
        }
    }

    func testVerificationDiscardsTheSnapshotIfSpacesChangeDuringComparison() {
        let third = identity("third", pid: 43, windowID: 102)
        let requests = [window, other, third].map {
            WindowSpaceRequest(identity: $0, isParked: false, isOnDesktop: true)
        }
        var current = 1
        let result = WindowSpaceObservation.capture(
            requests, cancellation: OperationCancellation(),
            layouts: { ["left": layout(current, spaces: [1, 2], fullscreen: [])] },
            membership: { _ in [1] }, mode: .verify, windowsInSpace: { _ in
                current = 2
                return [100, 101, 102]
            }
        )
        XCTAssertNil(result)
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

    func testChangedDisplayLayoutMakesOnlyItsOmittedMembershipUnconfirmed() {
        let right = layout(10, spaces: [10, 11], fullscreen: [])
        let original = WindowSpaceSnapshot(layouts: ["left": layout(1), "right": right],
            memberships: [window: [2], other: [10]])
        let leftRequest = WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: true, displayUUID: "left")
        let rightRequest = WindowSpaceRequest(identity: other, isParked: false, isOnDesktop: true, displayUUID: "right")
        let layouts = ["left": layout(2), "right": right]
        let partial = original.updating(with: WindowSpaceSnapshot(layouts: layouts), requests: [leftRequest, rightRequest])
        XCTAssertFalse(partial.shows(window, on: "left"))
        XCTAssertTrue(partial.shows(other, on: "right"))

        let parked = WindowSpaceRequest(identity: window, isParked: true, isOnDesktop: false, displayUUID: "left")
        let missing = partial.updating(with: WindowSpaceSnapshot(layouts: layouts, memberships: [window: []]),
                                      requests: [parked, rightRequest])
        XCTAssertFalse(missing.shows(window, on: "left"))
        let recovered = missing.updating(with: WindowSpaceSnapshot(layouts: layouts, memberships: [window: [2]]),
                                         requests: [parked, rightRequest])
        XCTAssertTrue(recovered.shows(window, on: "left"))
    }

    func testChangedWindowIdentityDoesNotInheritRetiredMembership() {
        let replacement = identity(window.itemID, pid: window.actionIdentity.pid, windowID: 200)
        let snapshot = WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: [2]])
        let updated = snapshot.updating(with: nil, requests: [WindowSpaceRequest(identity: replacement, isParked: false, isOnDesktop: true)])
        XCTAssertNil(updated.memberships[window])
        XCTAssertTrue(updated.shows(replacement, on: "left"))
    }

    func testReusedWindowNumberKeepsFallbackWhenThereWasNoSpaceEvidence() {
        let prior = WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: true)
        let replacement = identity(window.itemID, pid: window.actionIdentity.pid, windowID: window.windowID,
                                   targetID: UUID())
        let next = WindowSpaceRequest(identity: replacement, isParked: false, isOnDesktop: true)
        let snapshot = WindowSpaceSnapshot().updating(with: nil, requests: [prior])
        XCTAssertTrue(snapshot.shows(replacement, on: "left"))
        XCTAssertTrue(snapshot.updating(with: nil, requests: [next]).shows(replacement, on: "left"))
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
