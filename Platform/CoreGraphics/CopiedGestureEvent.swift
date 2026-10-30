import AppKit

struct CopiedGestureEvent: @unchecked Sendable {
    private let value: CGEvent

    init?(copying event: CGEvent) {
        guard let copy = event.copy() else { return nil }
        value = copy
    }

    @MainActor
    func makeAppKitEvent() -> NSEvent? {
        NSEvent(cgEvent: value)
    }
}
