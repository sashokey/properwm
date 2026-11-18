import AppKit
import Combine

@MainActor
final class TaskbarPresenter {
    private let runtime: AppRuntime
    private let ordering: StripOrderStore
    private let topology: DisplayTopologyStore
    private let spaces: TaskbarSpaceStore
    private let displayUUID: String?
    private weak var view: TaskbarView?
    private var subscriptions = Set<AnyCancellable>()
    private var refreshing = false
    private var liveIDs: [String] = []
    private var renderedSpaceRevision: UInt64 = 0

    init(view: TaskbarView, runtime: AppRuntime, ordering: StripOrderStore,
         topology: DisplayTopologyStore, spaces: TaskbarSpaceStore, displayUUID: String?,
         backgroundMenu: @escaping (NSEvent, NSView) -> Void,
         popupPresented: @escaping (NSPanel) -> Void,
         contextMenuVisibilityChanged: @escaping (Bool) -> Void,
         icons: AppIconResolver = .shared, system: any WindowSystemAccess = NativeWindowSystem()) {
        self.view = view
        self.runtime = runtime
        self.ordering = ordering
        self.topology = topology
        self.spaces = spaces
        self.displayUUID = displayUUID
        view.taskbarContent.canUseWindowActions = { [weak self] in
            guard let self else { return false }
            return self.spaces.canUseProjection(on: self.displayUUID, renderedSpaceRevision: self.renderedSpaceRevision)
        }
        view.taskbarContent.actions = TaskbarViewActions(
            toggle: { [weak self] in self?.trigger(.toggle($0.windowID), expected: $0) },
            activate: { [weak self] in self?.trigger(.activate($0.windowID), expected: $0) },
            close: { [weak self] in self?.trigger(.close($0.windowID), expected: $0) },
            quit: { [weak self] group in
                guard let self else { return }
                let visible = self.visibleItems()
                var attempted = Set<pid_t>()
                for window in group.windows {
                    let item = window.item
                    guard visible[item.id]?.actionIdentity == item.actionIdentity,
                          let app = system.app(item.pid), !app.isTerminated,
                          let expected = item.processGeneration,
                          system.generation(item.pid) == expected,
                          let origin = item.applicationOrigin, app.origin == origin else { continue }
                    let pid = item.owningApplication?.pid ?? item.pid
                    if let owner = item.owningApplication {
                        guard let parent = system.app(pid), !parent.isTerminated,
                              system.generation(pid) == owner.generation,
                              parent.origin == owner.origin else { continue }
                    }
                    guard attempted.insert(pid).inserted else { continue }
                    _ = system.terminate(pid)
                }
            },
            reorder: { [weak self] app, target, after in
                guard let self else { return }
                self.ordering.reorderGroup(app, relativeTo: target, after: after, current: self.liveIDs)
            },
            backgroundMenu: backgroundMenu,
            popupPresented: popupPresented,
            contextMenuVisibilityChanged: contextMenuVisibilityChanged
        )
        view.taskbarContent.iconProvider = { item in
            if let bundleID = item.item.bundleIdentifier { return icons.icon(for: bundleID, origin: item.item.resourceOrigin) }
            return NSRunningApplication(processIdentifier: item.item.resourcePID)?.icon
        }
        runtime.$snapshot.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        runtime.$optimisticStatesByWindowID.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        ordering.$liveOrder.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        topology.$table.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        spaces.$snapshot.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        spaces.$confirmedSpaceRevision.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        icons.changes.sink { [weak self] in self?.scheduleRefresh(refreshIcons: true) }.store(in: &subscriptions)
        refresh()
    }

    private var refreshScheduled = false
    private var iconsDirty = false

    private var displayFilter: StripDisplayFilter {
        StripDisplayFilter(scope: displayUUID, connectedUUIDs: topology.table.connectedUUIDs,
                           primaryUUID: topology.table.primaryUUID)
    }

    private func visibleItems() -> [String: StripItem] {
        TaskbarPresentation.visibleItems(StripItem.openWindows(from: runtime.snapshot),
                                       filter: displayFilter, spaces: spaces.snapshot)
    }

    private func trigger(_ intent: UserIntent, expected: WindowActionIdentity) {
        let revision = renderedSpaceRevision
        runtime.trigger(intent, expected: expected, projectionInvalidations: spaces.activeSpaceChanges) { [weak self] in
            guard let self, self.view != nil,
                  self.spaces.canUseProjection(on: self.displayUUID, renderedSpaceRevision: revision) else { return false }
            return self.visibleItems()[expected.groupID]?.actionIdentity == expected
        }
    }

    private func scheduleRefresh(refreshIcons: Bool = false) {
        iconsDirty = iconsDirty || refreshIcons
        guard !refreshing, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func refresh() {
        guard !refreshing, let view else { return }
        refreshing = true
        let refreshIcons = iconsDirty
        iconsDirty = false
        defer {
            refreshing = false
            if iconsDirty { scheduleRefresh() }
        }
        let items = StripItem.openWindows(from: runtime.snapshot)
        liveIDs = items.map(\.id)
        let keys = Dictionary(items.map { ($0.id, $0.applicationKey) }, uniquingKeysWith: { first, _ in first })
        ordering.sync(current: liveIDs, appKeyOf: keys)
        let order = TaskbarGroupOrdering.contiguous(ordering.reconciled(current: liveIDs, appKeyOf: keys), appKeys: keys)
        let confirmedSpaceRevision = spaces.confirmedSpaceRevision
        let groups = TaskbarPresentation.groups(items: items, order: order, filter: displayFilter,
                                                optimisticStates: runtime.optimisticStatesByWindowID,
                                                spaces: spaces.snapshot) { item in
            if let bundleID = item.bundleIdentifier { return AppDisplayNameResolver.displayName(for: bundleID, origin: item.resourceOrigin) }
            return NSRunningApplication(processIdentifier: item.resourcePID)?.localizedName ?? item.appID
        }
        view.taskbarContent.update(groups: groups, refreshIcons: refreshIcons)
        renderedSpaceRevision = confirmedSpaceRevision
    }
}
