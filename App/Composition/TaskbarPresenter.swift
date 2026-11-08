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
        view.taskbarContent.actions = TaskbarViewActions(
            toggle: { [weak runtime] in runtime?.toggle(windowID: $0) },
            activate: { [weak runtime] in runtime?.activate(windowID: $0) },
            close: { [weak runtime] in runtime?.close(windowID: $0) },
            quit: { group in
                var attempted = Set<pid_t>()
                for window in group.windows {
                    let item = window.item
                    guard let app = system.app(item.pid), !app.isTerminated,
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
        icons.changes.sink { [weak self] in self?.scheduleRefresh(refreshIcons: true) }.store(in: &subscriptions)
        refresh()
    }

    private var refreshScheduled = false
    private var iconsDirty = false

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
        let filter = StripDisplayFilter(scope: displayUUID, connectedUUIDs: topology.table.connectedUUIDs,
                                        primaryUUID: topology.table.primaryUUID)
        let groups = TaskbarPresentation.groups(items: items, order: order, filter: filter,
                                                optimisticStates: runtime.optimisticStatesByWindowID,
                                                spaces: spaces.snapshot) { item in
            if let bundleID = item.bundleIdentifier { return AppDisplayNameResolver.displayName(for: bundleID, origin: item.resourceOrigin) }
            return NSRunningApplication(processIdentifier: item.resourcePID)?.localizedName ?? item.appID
        }
        view.taskbarContent.update(groups: groups, refreshIcons: refreshIcons)
    }
}
