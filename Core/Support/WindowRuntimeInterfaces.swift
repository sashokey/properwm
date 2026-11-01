import Combine

@MainActor
protocol WindowInventoryTracking: AnyObject {
    var snapshots: AnyPublisher<DockSnapshot, Never> { get }
    func start()
    func stop()
}

protocol WindowActionExecuting: Sendable {
    func execute(_ request: PlatformActionRequest, snapshot: DockSnapshot,
                 forcedMinimizedPrior: Bool,
                 cancellation: OperationCancellation,
                 onHandoffActivePrediction: (@Sendable (WindowID) -> Void)?) -> Bool
}
