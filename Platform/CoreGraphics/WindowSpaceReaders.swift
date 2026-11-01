import CoreGraphics
import Foundation

enum ManagedSpaceLayoutReader {
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let symbols: (cid: Int32, copy: CopySpacesFn)? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
        ) else { return nil }
        guard let cidSym = dlsym(handle, "SLSMainConnectionID"),
            let copySym = dlsym(handle, "SLSCopyManagedDisplaySpaces")
        else { dlclose(handle); return nil }
        let cid = unsafeBitCast(cidSym, to: MainConnectionIDFn.self)()
        return (cid, unsafeBitCast(copySym, to: CopySpacesFn.self))
    }()

    static func layout(forDisplayUUID uuid: String) -> SpaceLayoutSnapshot? {
        guard let layouts = layouts() else { return nil }
        return layouts[uuid] ?? layouts["Main"]
    }

    static func layouts() -> [String: SpaceLayoutSnapshot]? {
        guard let symbols,
              let displays = symbols.copy(symbols.cid)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return parse(displays)
    }

    static func parse(_ displays: [[String: Any]]) -> [String: SpaceLayoutSnapshot]? {
        guard !displays.isEmpty else { return nil }
        var result: [String: SpaceLayoutSnapshot] = [:]
        for display in displays {
            guard let uuid = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]],
                  let current = display["Current Space"] as? [String: Any],
                  let currentID = spaceID(current) else { return nil }
            var ordered: [Int] = []
            var fullscreen: Set<Int> = []
            for space in spaces {
                guard let id = spaceID(space) else { return nil }
                ordered.append(id)
                if space["type"] as? Int == SpaceLayoutSnapshot.fullscreenSpaceType {
                    fullscreen.insert(id)
                }
            }
            guard ordered.contains(currentID) else { return nil }
            result[uuid] = SpaceLayoutSnapshot(
                orderedSpaceIDs: ordered,
                fullscreenSpaceIDs: fullscreen,
                currentSpaceID: currentID
            )
        }
        return result
    }

    private static func spaceID(_ dict: [String: Any]) -> Int? {
        (dict["ManagedSpaceID"] as? Int) ?? (dict["id64"] as? Int)
    }
}

enum WindowSpaceObservation {
    static func capture(_ requests: [WindowSpaceRequest]) -> WindowSpaceSnapshot? {
        capture(requests, cancellation: OperationCancellation())
    }

    static func capture(_ requests: [WindowSpaceRequest], cancellation: OperationCancellation,
                        maximumDuration: TimeInterval = 1,
                        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        layouts: () -> [String: SpaceLayoutSnapshot]? = ManagedSpaceLayoutReader.layouts,
                        membership: (Int) -> [Int]? = WindowSpaceMembershipReader.spaceIDs) -> WindowSpaceSnapshot? {
        let budget = OperationReadBudget(maximumDuration: maximumDuration, cancellation: cancellation, uptime: uptime)
        guard budget.canContinue, let initial = layouts() else { return nil }
        var memberships: [WindowSpaceIdentity: Set<Int>] = [:]
        for request in requests {
            guard budget.canContinue else { return nil }
            if let spaces = membership(Int(request.identity.windowID)) {
                memberships[request.identity] = Set(spaces)
            }
        }
        guard budget.canContinue, initial == layouts(), budget.canContinue else { return nil }
        return WindowSpaceSnapshot(layouts: initial, memberships: memberships)
    }
}

enum WindowSpaceMembershipReader {
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let symbols: (cid: Int32, copy: CopySpacesForWindowsFn)? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
        ) else { return nil }
        guard let cidSym = dlsym(handle, "SLSMainConnectionID"),
            let copySym = dlsym(handle, "SLSCopySpacesForWindows")
        else { dlclose(handle); return nil }
        let cid = unsafeBitCast(cidSym, to: MainConnectionIDFn.self)()
        return (cid, unsafeBitCast(copySym, to: CopySpacesForWindowsFn.self))
    }()

    static func spaceIDs(forWindowNumber windowNumber: Int) -> [Int]? {
        guard windowNumber > 0, let symbols else { return nil }
        guard let raw = symbols.copy(
            symbols.cid,
            0x7,
            [NSNumber(value: windowNumber)] as CFArray
        )?.takeRetainedValue() as? [NSNumber] else { return nil }
        return raw.map(\.intValue)
    }
}

