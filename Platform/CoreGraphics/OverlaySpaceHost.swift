import AppKit
import Foundation

@MainActor
final class OverlaySpaceHost {
    static let isEnabled = DebugSwitch.overlaySpace.isEnabled(in: ProcessInfo.processInfo.environment)

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceDestroyFn = @convention(c) (Int32, UInt64) -> Int32
    private typealias SpaceSetAbsoluteLevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SpaceListFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindowsFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private struct Symbols {
        let cid: Int32
        let create: SpaceCreateFn
        let destroy: SpaceDestroyFn
        let setAbsoluteLevel: SpaceSetAbsoluteLevelFn
        let show: SpaceListFn
        let hide: SpaceListFn
        let addWindows: SpaceAddWindowsFn
        let copySpaces: CopySpacesForWindowsFn
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) else { return nil }
        func load<T>(_ name: String, as: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let cidFn = load("SLSMainConnectionID", as: MainConnectionIDFn.self),
              let create = load("SLSSpaceCreate", as: SpaceCreateFn.self),
              let destroy = load("SLSSpaceDestroy", as: SpaceDestroyFn.self),
              let setLevel = load("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevelFn.self),
              let show = load("SLSShowSpaces", as: SpaceListFn.self),
              let hide = load("SLSHideSpaces", as: SpaceListFn.self),
              let addWindows = load("SLSSpaceAddWindowsAndRemoveFromSpaces", as: SpaceAddWindowsFn.self),
              let copySpaces = load("SLSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
        else { dlclose(handle); return nil }
        return Symbols(cid: cidFn(), create: create, destroy: destroy, setAbsoluteLevel: setLevel,
                       show: show, hide: hide, addWindows: addWindows, copySpaces: copySpaces)
    }()

    struct Operations {
        let create: () -> UInt64
        let prepare: (UInt64) -> Void
        let addWindows: (UInt64, [Int]) -> Void
        let spaces: (Int) -> [UInt64]?
        let release: (UInt64) -> Void
    }

    static func make() -> OverlaySpaceHost? {
        guard isEnabled, let symbols else { return nil }
        return OverlaySpaceHost(operations: Operations(
            create: { symbols.create(symbols.cid, 1, nil) },
            prepare: { sid in
                _ = symbols.setAbsoluteLevel(symbols.cid, sid, 0)
                _ = symbols.show(symbols.cid, [NSNumber(value: sid)] as CFArray)
            },
            addWindows: { sid, windows in
                _ = symbols.addWindows(symbols.cid, sid, windows.map { NSNumber(value: $0) } as CFArray, 0x7)
            },
            spaces: { window in
                (symbols.copySpaces(symbols.cid, 0xF, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber])?
                    .map(\.uint64Value)
            },
            release: { sid in
                _ = symbols.hide(symbols.cid, [NSNumber(value: sid)] as CFArray)
                _ = symbols.destroy(symbols.cid, sid)
            }
        ))
    }

    private let operations: Operations
    private var spaceID: UInt64?

    init(operations: Operations) { self.operations = operations }

    isolated deinit { tearDown() }

    @discardableResult
    func pin(windowNumbers: [Int]) -> Bool {
        let targets = windowNumbers.filter { $0 > 0 }
        guard !targets.isEmpty, let sid = ensureSpace() else { return false }
        let missing = targets.filter { !isPinned(windowNumber: $0) }
        guard !missing.isEmpty else { return true }
        operations.addWindows(sid, missing)
        return missing.allSatisfy { isPinned(windowNumber: $0) }
    }

    func isPinned(windowNumber: Int) -> Bool {
        guard let sid = spaceID, windowNumber > 0 else { return false }
        return operations.spaces(windowNumber)?.contains(sid) == true
    }

    func tearDown() {
        guard let sid = spaceID else { return }
        spaceID = nil
        operations.release(sid)
    }

    private func ensureSpace() -> UInt64? {
        if let spaceID { return spaceID }
        let sid = operations.create()
        guard sid != 0 else { return nil }
        spaceID = sid
        operations.prepare(sid)
        return sid
    }
}
