import Combine
import Foundation
import Synchronization
import XCTest

@MainActor
private final class TokenInventory: WindowInventoryTracking {
    let values: CurrentValueSubject<DockSnapshot, Never>
    var snapshots: AnyPublisher<DockSnapshot, Never> { values.eraseToAnyPublisher() }
    init(_ snapshot: DockSnapshot) { values = CurrentValueSubject(snapshot) }
    func start() {}
    func stop() {}
}

private final class TokenExecutor: WindowActionExecuting {
    let started = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    func execute(_ request: PlatformActionRequest, snapshot: DockSnapshot,
                 forcedMinimizedPrior: Bool, cancellation: OperationCancellation,
                 onHandoffActivePrediction: (@Sendable (WindowID) -> Void)?) -> Bool {
        started.withLock { $0 = true }
        _ = release.wait(timeout: .now() + 3)
        return true
    }
}

@MainActor
final class RuntimeTokenRegressionTests: XCTestCase {
    func testRetiredPendingWindowActionsDoNotRetainTokens() async {
        let records = (0...40).map { index in
            WindowRecord(id: WindowID(rawValue: "token-window-\(index)"), appID: AppID(rawValue: "fixture"),
                         pid: -42420, bundleIdentifier: "review.token.fixture", title: "Fixture \(index)",
                         bounds: nil, status: .inactive, cgWindowID: UInt32(index + 1))
        }
        let inventory = TokenInventory(snapshot(records))
        let executor = TokenExecutor()
        let log = WindowInventoryAnomalyLog(configuration: .init(enabled: false,
            directoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            maxFileSize: 1_048_576, archiveCount: 0))
        let runtime = AppRuntime(inventoryLog: log, tracker: inventory, actionExecutor: executor, isAppFrontmost: { _ in false })
        defer { executor.release.signal(); runtime.stop() }
        runtime.start()
        await waitUntil { runtime.snapshot.windows.count == 41 }
        runtime.activate(windowID: records[0].id.rawValue)
        await waitUntil { executor.started.withLock { $0 } }
        for record in records.dropFirst() { runtime.close(windowID: record.id.rawValue) }
        let tasks = runtime.pendingActionsForTesting
        inventory.values.send(snapshot([records[0]]))
        await waitUntil { runtime.snapshot.windows.count == 1 }
        executor.release.signal()
        for task in tasks { await task.value }
        let tokens = Mirror(reflecting: runtime).children.first { $0.label == "actionTokens" }?.value as? [String: UUID]
        let retained = tokens?.keys.filter { $0 != records[0].id.rawValue }.count
        print("Runtime token repro: retired queued windows=40, retained tokens=\(retained ?? -1)")
        XCTAssertEqual(retained, 0, "Retired jobs never execute the callback that deletes their action token")
    }

    private func snapshot(_ records: [WindowRecord]) -> DockSnapshot {
        DockSnapshot(windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                     orderedWindowIDs: records.map(\.id))
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate())
    }
}
