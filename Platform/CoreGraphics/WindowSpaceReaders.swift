import CoreGraphics
import Foundation
#if DEBUG
import os
#endif

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
    enum Mode: String {
        case standard
        case verify
        case batch

        static var live: Self {
            #if DEBUG
            DebugSwitch.spaceBatchMode.value().flatMap(Self.init(rawValue:)) ?? .standard
            #else
            .standard
            #endif
        }
    }

    #if DEBUG
    private static let logger = Logger(subsystem: "io.github.sashokey.properwm", category: "space-membership")
    #endif

    static func capture(_ requests: [WindowSpaceRequest]) -> WindowSpaceSnapshot? {
        capture(requests, cancellation: OperationCancellation())
    }

    static func capture(_ requests: [WindowSpaceRequest], cancellation: OperationCancellation,
                        maximumDuration: TimeInterval = 1,
                        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        layouts: () -> [String: SpaceLayoutSnapshot]? = ManagedSpaceLayoutReader.layouts,
                        membership: (Int) -> [Int]? = WindowSpaceMembershipReader.spaceIDs,
                        mode: Mode = .standard,
                        windowsInSpace: (Int) -> Set<Int>? = WindowSpaceMembershipReader.windowNumbers) -> WindowSpaceSnapshot? {
        let budget = OperationReadBudget(maximumDuration: maximumDuration, cancellation: cancellation, uptime: uptime)
        guard budget.canContinue, let initial = layouts() else { return nil }

        var seenNumbers: Set<Int> = []
        let numbers = requests.map { Int($0.identity.windowID) }.filter { seenNumbers.insert($0).inserted }
        let parked = Set(requests.filter(\.isParked).map { Int($0.identity.windowID) })
        let spaces = Set(initial.values.flatMap(\.orderedSpaceIDs)).sorted()

        func readByWindow(_ cached: [Int: Set<Int>]) -> [Int: Set<Int>]? {
            var result = cached
            for number in numbers where result[number] == nil {
                guard budget.canContinue else { return nil }
                if let ids = membership(number) { result[number] = Set(ids) }
            }
            return result
        }

        func readBySpace() -> [Int: Set<Int>]? {
            let eligible = seenNumbers.subtracting(parked)
            guard !spaces.isEmpty, spaces.count < eligible.count else { return nil }
            var result: [Int: Set<Int>] = [:]
            for space in spaces {
                guard budget.canContinue, let windows = windowsInSpace(space) else { return nil }
                for number in windows where eligible.contains(number) {
                    result[number, default: []].insert(space)
                }
            }
            return result
        }

        if mode == .batch, let cached = readBySpace() {
            return snapshot(using: readByWindow(cached))
        }
        let original = snapshot(using: readByWindow([:]))
        if mode == .verify, let original, !spaces.isEmpty, spaces.count < numbers.count - parked.count {
            let batched = readBySpace()
            let candidate = batched.flatMap(readByWindow)
            guard budget.canContinue, initial == layouts(), budget.canContinue else { return nil }
            #if DEBUG
            if let candidate, let batched {
                let matches = original == makeSnapshot(using: candidate)
                logger.notice("space batch parity matches=\(matches, privacy: .public) windows=\(numbers.count, privacy: .public) spaces=\(spaces.count, privacy: .public) batchedWindows=\(batched.count, privacy: .public)")
            }
            #endif
        }
        return original

        func snapshot(using byWindow: [Int: Set<Int>]?) -> WindowSpaceSnapshot? {
            guard let byWindow, budget.canContinue, initial == layouts(), budget.canContinue else { return nil }
            return makeSnapshot(using: byWindow)
        }

        func makeSnapshot(using byWindow: [Int: Set<Int>]) -> WindowSpaceSnapshot {
            var memberships: [WindowSpaceIdentity: Set<Int>] = [:]
            for request in requests {
                memberships[request.identity] = byWindow[Int(request.identity.windowID)]
            }
            return WindowSpaceSnapshot(layouts: initial, memberships: memberships)
        }
    }
}

enum WindowSpaceMembershipReader {
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyWindowsForSpaceFn = @convention(c) (
        Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
    ) -> Unmanaged<CFArray>?

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

    private static let windowsForSpace: (cid: Int32, copy: CopyWindowsForSpaceFn)? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
        ) else { return nil }
        guard let cidSym = dlsym(handle, "SLSMainConnectionID"),
              let copySym = dlsym(handle, "SLSCopyWindowsWithOptionsAndTags")
        else { dlclose(handle); return nil }
        let cid = unsafeBitCast(cidSym, to: MainConnectionIDFn.self)()
        return (cid, unsafeBitCast(copySym, to: CopyWindowsForSpaceFn.self))
    }()

    static func windowNumbers(forSpaceID spaceID: Int) -> Set<Int>? {
        guard spaceID > 0, let windowsForSpace else { return nil }
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let raw = windowsForSpace.copy(
            windowsForSpace.cid, 0, [NSNumber(value: spaceID)] as CFArray, 0x7, &setTags, &clearTags
        )?.takeRetainedValue() as? [NSNumber] else { return nil }
        return Set(raw.map(\.intValue))
    }

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

