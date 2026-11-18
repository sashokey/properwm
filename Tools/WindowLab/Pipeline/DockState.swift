@MainActor
final class DockState {
    private(set) var snapshot: DockSnapshot = .empty

    func commit(_ update: StateUpdate) {
        snapshot.apply(update)
    }
}
