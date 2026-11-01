import XCTest

final class StripDisplayFilterTests: XCTestCase {
    private let onA = StripDisplayFilter(scope: "A", connectedUUIDs: ["A", "B"], primaryUUID: "A")
    private let onB = StripDisplayFilter(scope: "B", connectedUUIDs: ["A", "B"], primaryUUID: "A")

    func testNilScopeShowsEverything() {
        let filter = StripDisplayFilter(scope: nil, connectedUUIDs: ["A", "B"], primaryUUID: "A")
        XCTAssertTrue(filter.shows(displayUUID: "B"))
        XCTAssertTrue(filter.shows(displayUUID: nil))
        XCTAssertTrue(StripDisplayFilter.unfiltered.shows(displayUUID: "Z"))
    }

    func testWindowShowsOnlyOnItsOwnDisplay() {
        XCTAssertTrue(onA.shows(displayUUID: "A"))
        XCTAssertFalse(onB.shows(displayUUID: "A"))
        XCTAssertTrue(onB.shows(displayUUID: "B"))
        XCTAssertFalse(onA.shows(displayUUID: "B"))
    }

    func testUnknownDisplayFallsToPrimary() {
        XCTAssertTrue(onA.shows(displayUUID: nil))
        XCTAssertFalse(onB.shows(displayUUID: nil))
    }

    func testDisconnectedDisplayFallsToPrimary() {
        XCTAssertTrue(onA.shows(displayUUID: "GONE"))
        XCTAssertFalse(onB.shows(displayUUID: "GONE"))
    }

    func testNoPrimaryHidesUnknownEverywhere() {
        let filter = StripDisplayFilter(scope: "A", connectedUUIDs: [], primaryUUID: nil)
        XCTAssertFalse(filter.shows(displayUUID: nil))
        XCTAssertFalse(filter.shows(displayUUID: "A"))
    }
}
