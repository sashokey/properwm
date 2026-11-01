import Foundation

struct StripDisplayFilter: Equatable {
    enum Subject: Equatable {
        case launcher
        case runningWithoutWindow(displayUUID: String?)
        case window(displayUUID: String?)
    }

    let scope: String?
    let connectedUUIDs: Set<String>
    let primaryUUID: String?

    static let unfiltered = StripDisplayFilter(scope: nil, connectedUUIDs: [], primaryUUID: nil)

    func shows(_ subject: Subject) -> Bool {
        guard let scope else { return true }
        switch subject {
        case .launcher:
            return true
        case .runningWithoutWindow(let key), .window(let key):
            return resolvedWindowDisplayUUID(key) == scope
        }
    }

    func resolvedWindowDisplayUUID(_ key: String?) -> String? {
        guard let key, connectedUUIDs.contains(key) else { return primaryUUID }
        return key
    }
}
