import AppKit
import Foundation

@MainActor
final class OverlaySpaceHost {
    static let isEnabled = DebugSwitch.overlaySpace.isEnabled(in: ProcessInfo.processInfo.environment)
    private static let currentSpacesMask: Int32 = 0x5

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceDestroyFn = @convention(c) (Int32, UInt64) -> Void
    private typealias SpaceSetAbsoluteLevelFn = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias SpaceListFn = @convention(c) (Int32, CFArray) -> Void
    private typealias SpaceAddWindowsFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
    private typealias CopySpacesFn = @convention(c) (Int32, Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private struct Symbols {
        let cid: Int32
        let create: SpaceCreateFn
        let destroy: SpaceDestroyFn
        let setAbsoluteLevel: SpaceSetAbsoluteLevelFn
        let show: SpaceListFn
        let hide: SpaceListFn
        let addWindows: SpaceAddWindowsFn
        let copySpaces: CopySpacesFn
        let copySpacesForWindows: CopySpacesForWindowsFn
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
              let copySpaces = load("SLSCopySpaces", as: CopySpacesFn.self),
              let copySpacesForWindows = load("SLSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
        else { dlclose(handle); return nil }
        return Symbols(cid: cidFn(), create: create, destroy: destroy, setAbsoluteLevel: setLevel,
                       show: show, hide: hide, addWindows: addWindows, copySpaces: copySpaces,
                       copySpacesForWindows: copySpacesForWindows)
    }()

    struct Operations {
        let create: () -> UInt64
        let prepare: (UInt64) -> Void
        let isVisible: (UInt64) -> Bool?
        let addWindows: (UInt64, [Int]) -> Void
        let spaces: (Int) -> [UInt64]?
        let release: (UInt64) -> Void
    }

    static func make() -> OverlaySpaceHost? {
        guard isEnabled, let symbols else { return nil }
        return OverlaySpaceHost(operations: Operations(
            create: { symbols.create(symbols.cid, 1, nil) },
            prepare: { sid in
                symbols.setAbsoluteLevel(symbols.cid, sid, 0)
                symbols.show(symbols.cid, [NSNumber(value: sid)] as CFArray)
            },
            isVisible: { sid in
                let shown = symbols.copySpaces(symbols.cid, currentSpacesMask)?.takeRetainedValue() as? [NSNumber]
                return shown?.contains(NSNumber(value: sid))
            },
            addWindows: { sid, windows in
                symbols.addWindows(symbols.cid, sid, windows.map { NSNumber(value: $0) } as CFArray, 0x7)
            },
            spaces: { window in
                (symbols.copySpacesForWindows(symbols.cid, 0xF, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber])?
                    .map(\.uint64Value)
            },
            release: { sid in
                symbols.hide(symbols.cid, [NSNumber(value: sid)] as CFArray)
                symbols.destroy(symbols.cid, sid)
            }
        ))
    }

    private let operations: Operations
    private var spaceID: UInt64?
    private let pinnedPanels = NSHashTable<NSPanel>.weakObjects()
    private var restoringMembership = false

    init(operations: Operations) { self.operations = operations }

    isolated deinit { tearDown() }

    @discardableResult
    func pin(panels: [NSPanel]) -> Bool {
        pin(windowNumbers: panels.map(\.windowNumber)) {
            for panel in panels where panel.windowNumber > 0 { pinnedPanels.add(panel) }
        }
    }

    @discardableResult
    func pin(windowNumbers: [Int], trackPanels: () -> Void = {}) -> Bool {
        let targets = windowNumbers.filter { $0 > 0 }
        guard !targets.isEmpty, let sid = ensureSpace() else { return false }
        trackPanels()
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
        pinnedPanels.removeAllObjects()
        operations.release(sid)
    }

    func reconcileVisibility() {
        if let spaceID { _ = isUsable(spaceID) }
    }

    private func isUsable(_ sid: UInt64) -> Bool {
        guard let visible = operations.isVisible(sid) else { return false }
        if !visible {
            let panels = pinnedPanels.allObjects
            tearDown()
            if !panels.isEmpty {
                restoringMembership = true
                PanelCollectionBehavior.restoreMembership(of: panels) { [weak self] in
                    self?.restoringMembership = false
                }
            }
        }
        return visible
    }

    private func ensureSpace() -> UInt64? {
        guard !restoringMembership else { return nil }
        if let spaceID { return isUsable(spaceID) ? spaceID : nil }
        let sid = operations.create()
        guard sid != 0 else { return nil }
        operations.prepare(sid)
        guard operations.isVisible(sid) == true else {
            operations.release(sid)
            return nil
        }
        spaceID = sid
        return sid
    }
}
