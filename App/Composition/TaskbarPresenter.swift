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
         icons: AppIconResolver = .shared) {
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
                for pid in Set(group.windows.map(\.item.pid)) {
                    guard let app = NSRunningApplication(processIdentifier: pid),
                          let representative = group.windows.first(where: { $0.item.pid == pid }),
                          representative.item.bundleIdentifier == nil || app.bundleIdentifier == representative.item.bundleIdentifier else { continue }
                    _ = app.terminate()
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
            if let bundleID = item.item.bundleIdentifier { return icons.icon(for: bundleID) }
            return NSRunningApplication(processIdentifier: item.item.pid)?.icon
        }
        runtime.$snapshot.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        runtime.$optimisticStatesByWindowID.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        runtime.$heldLabelTitlesByChipID.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        ordering.$liveOrder.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        topology.$table.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        spaces.$snapshot.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        icons.changes.sink { [weak self] in self?.scheduleRefresh() }.store(in: &subscriptions)
        refresh()
    }

    private var refreshScheduled = false

    private func scheduleRefresh() {
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
        defer { refreshing = false }
        let items = StripItem.openWindows(from: runtime.snapshot)
        liveIDs = items.map(\.id)
        let keys = Dictionary(items.map { ($0.id, $0.bundleIdentifier ?? $0.appID) }, uniquingKeysWith: { first, _ in first })
        ordering.sync(current: liveIDs, appKeyOf: keys)
        let order = TaskbarGroupOrdering.contiguous(ordering.reconciled(current: liveIDs, appKeyOf: keys), appKeys: keys)
        let filter = StripDisplayFilter(scope: displayUUID, connectedUUIDs: topology.table.connectedUUIDs,
                                        primaryUUID: topology.table.primaryUUID)
        let groups = TaskbarPresentation.groups(items: items, order: order, filter: filter,
                                                titles: runtime.heldLabelTitlesByChipID,
                                                optimisticStates: runtime.optimisticStatesByWindowID,
                                                spaces: spaces.snapshot) { item in
            if let bundleID = item.bundleIdentifier { return AppDisplayNameResolver.displayName(for: bundleID) }
            return NSRunningApplication(processIdentifier: item.pid)?.localizedName ?? item.appID
        }
        view.taskbarContent.update(groups: groups)
    }
}
