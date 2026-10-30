import XCTest

final class TaskbarDisplaySetTests: XCTestCase {
    func testDiffKeepsCurrentOrderForAddedAndKept() {
        let diff = TaskbarDisplaySet.diff(previous: ["A", "B", "C"], current: ["C", "D", "A"])
        XCTAssertEqual(diff.added, ["D"])
        XCTAssertEqual(diff.removed, ["B"])
        XCTAssertEqual(diff.kept, ["C", "A"])
    }

    func testDiffEmptyToSomething() {
        let diff = TaskbarDisplaySet.diff(previous: [], current: ["A"])
        XCTAssertEqual(diff, TaskbarDisplaySet.Diff(added: ["A"], removed: [], kept: []))
    }

    func testDesiredUnitKeysOnePerDisplayForAllScreensModes() {
        XCTAssertEqual(TaskbarDisplaySet.desiredUnitKeys(connectedKeys: ["A", "B"]), ["A", "B"])
        XCTAssertEqual(
            TaskbarDisplaySet.desiredUnitKeys(connectedKeys: ["B"]),
            ["B"]
        )
    }

    func testDesiredUnitKeysFallsBackToSingleUnitWhenNoDisplays() {
        XCTAssertEqual(TaskbarDisplaySet.desiredUnitKeys(connectedKeys: []), [nil])
    }
}
