struct DockSnapshot: Equatable, Sendable {
    var windows: [WindowID: WindowRecord]
    var orderedWindowIDs: [WindowID]

    static let empty = DockSnapshot(windows: [:], orderedWindowIDs: [])

    mutating func apply(_ update: StateUpdate) {
        let windowID = update.windowRecord?.id ?? update.windowID
        windows[windowID] = update.windowRecord
        orderedWindowIDs = update.orderedWindowIDs
    }
}

struct StateUpdate: Hashable, Sendable {
    let windowID: WindowID
    let windowRecord: WindowRecord?
    let orderedWindowIDs: [WindowID]
}
