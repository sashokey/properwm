import Foundation

struct SpaceLayoutSnapshot: Equatable, Sendable {
    let orderedSpaceIDs: [Int]
    let fullscreenSpaceIDs: Set<Int>
    let currentSpaceID: Int
    static let fullscreenSpaceType = 4
}

struct WindowSpaceIdentity: Hashable, Sendable {
    let actionIdentity: WindowActionIdentity
    let windowID: UInt32

    var itemID: String { actionIdentity.groupID }

    init?(_ actionIdentity: WindowActionIdentity) {
        guard let windowID = actionIdentity.cgWindowID else { return nil }
        self.actionIdentity = actionIdentity
        self.windowID = windowID
    }
}

struct WindowSpaceRequest: Equatable, Sendable {
    let identity: WindowSpaceIdentity
    let isParked: Bool
    let isOnDesktop: Bool
    let displayUUID: String?

    init(identity: WindowSpaceIdentity, isParked: Bool, isOnDesktop: Bool, displayUUID: String? = nil) {
        self.identity = identity
        self.isParked = isParked
        self.isOnDesktop = isOnDesktop
        self.displayUUID = displayUUID
    }
}

struct WindowSpaceSnapshot: Equatable, Sendable {
    var layouts: [String: SpaceLayoutSnapshot]
    var memberships: [WindowSpaceIdentity: Set<Int>]
    private var requestedIdentities: [String: WindowSpaceIdentity] = [:]
    private var unconfirmedMemberships: Set<WindowSpaceIdentity> = []

    init(layouts: [String: SpaceLayoutSnapshot] = [:], memberships: [WindowSpaceIdentity: Set<Int>] = [:]) {
        self.layouts = layouts
        self.memberships = memberships
    }

    func shows(_ identity: WindowSpaceIdentity?, on displayUUID: String?) -> Bool {
        guard let identity else { return true }
        guard let spaces = memberships[identity] else {
            return !unconfirmedMemberships.contains(identity) && !reusesWindowNumber(identity)
        }
        if let displayUUID, let layout = layouts[displayUUID] ?? layouts["Main"] {
            return spaces.contains(layout.currentSpaceID)
        }
        guard displayUUID == nil, !layouts.isEmpty else { return true }
        return !spaces.isDisjoint(with: layouts.values.map(\.currentSpaceID))
    }

    func updating(with observation: WindowSpaceSnapshot?, requests: [WindowSpaceRequest],
                  afterSpaceChange: Bool = false) -> Self {
        let identities = Set(requests.map(\.identity))
        var next = self
        next.memberships = memberships.filter { identities.contains($0.key) }
        next.requestedIdentities = Dictionary(requests.map { ($0.identity.itemID, $0.identity) },
                                              uniquingKeysWith: { first, _ in first })
        next.unconfirmedMemberships.formIntersection(identities)
        next.unconfirmedMemberships.formUnion(identities.filter(reusesWindowNumber))
        guard let observation, !observation.layouts.isEmpty else { return next }
        next.layouts = observation.layouts
        for request in requests {
            let identity = request.identity
            if let spaces = observation.memberships[identity], !request.isParked || !spaces.isEmpty {
                next.memberships[identity] = spaces
                next.unconfirmedMemberships.remove(identity)
            } else if !request.isParked && (afterSpaceChange || layoutChanged(on: request.displayUUID, to: observation.layouts)) {
                next.memberships.removeValue(forKey: identity)
                next.unconfirmedMemberships.insert(identity)
            }
        }
        return next
    }

    private func reusesWindowNumber(_ identity: WindowSpaceIdentity) -> Bool {
        guard let prior = requestedIdentities[identity.itemID], identity != prior,
              identity.windowID == prior.windowID else { return false }
        return memberships[prior] != nil || unconfirmedMemberships.contains(prior)
    }

    private func layoutChanged(on displayUUID: String?, to next: [String: SpaceLayoutSnapshot]) -> Bool {
        guard !layouts.isEmpty else { return false }
        guard let displayUUID else { return layouts != next }
        return (layouts[displayUUID] ?? layouts["Main"]) != (next[displayUUID] ?? next["Main"])
    }
}
