import Foundation

struct SpaceLayoutSnapshot: Equatable, Sendable {
    let orderedSpaceIDs: [Int]
    let fullscreenSpaceIDs: Set<Int>
    let currentSpaceID: Int
    static let fullscreenSpaceType = 4
}

struct WindowSpaceIdentity: Hashable, Sendable {
    let itemID: String
    let pid: Int32
    let windowID: UInt32
}

struct WindowSpaceRequest: Equatable, Sendable {
    let identity: WindowSpaceIdentity
    let isParked: Bool
    let isOnDesktop: Bool
}

struct WindowSpaceSnapshot: Equatable, Sendable {
    var layouts: [String: SpaceLayoutSnapshot] = [:]
    var memberships: [WindowSpaceIdentity: Set<Int>] = [:]

    func shows(_ identity: WindowSpaceIdentity?, on displayUUID: String?) -> Bool {
        guard let identity, let spaces = memberships[identity] else { return true }
        if let displayUUID, let layout = layouts[displayUUID] ?? layouts["Main"] {
            return spaces.contains(layout.currentSpaceID)
        }
        guard displayUUID == nil, !layouts.isEmpty else { return true }
        return !spaces.isDisjoint(with: layouts.values.map(\.currentSpaceID))
    }

    func updating(with observation: WindowSpaceSnapshot?, requests: [WindowSpaceRequest]) -> Self {
        let identities = Set(requests.map(\.identity))
        var next = self
        next.memberships = memberships.filter { identities.contains($0.key) }
        guard let observation else { return next }
        next.layouts = observation.layouts
        for request in requests {
            guard let spaces = observation.memberships[request.identity] else { continue }
            if spaces.isEmpty, request.isParked { continue }
            next.memberships[request.identity] = spaces
        }
        return next
    }
}
