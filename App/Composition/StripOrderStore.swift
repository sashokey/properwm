import Foundation

@MainActor
final class StripOrderStore: ObservableObject {
    @Published private(set) var liveOrder: [String] = []

    private let orderKey = "properwm.windowOrder"
    private let bootKey = "properwm.windowOrderBootTime"
    private let bootTime: Int

    private var absentSince: [String: Date] = [:]
    private static let rankRetentionGrace: TimeInterval = 5.0

    private var stickyAppKeys: [String: String] = [:]

    private let defaults: UserDefaults
    private let now: () -> Date
    private let inventoryLog: WindowInventoryAnomalyLog
    private var lastProjectionSample: InventoryOrderProjectionSample?

    var isInventoryLogEnabled: Bool { inventoryLog.isEnabled }

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         bootTimeProvider: () -> Int = StripOrderStore.bootTimeSeconds,
         inventoryLog: WindowInventoryAnomalyLog = WindowInventoryAnomalyLog()) {
        self.defaults = defaults
        self.now = now
        self.inventoryLog = inventoryLog
        bootTime = bootTimeProvider()

        if defaults.object(forKey: bootKey) != nil,
           defaults.integer(forKey: bootKey) == bootTime,
           let saved = defaults.stringArray(forKey: orderKey) {
            liveOrder = saved
        }
    }

    func reconciled(current: [String], appKeyOf: [String: String] = [:]) -> [String] {
        var merged = stickyAppKeys
        merged.merge(appKeyOf) { _, new in new }
        let currentSet = Set(current)
        let anchors = absentRankAnchors(current: currentSet, now: now())
        let effectiveCurrent = current + anchors
        let ordered = StripOrdering.reconcile(
            remembered: liveOrder,
            current: effectiveCurrent,
            appKeyOf: merged
        )
        let anchorSet = Set(anchors)
        return ordered.filter { !anchorSet.contains($0) }
    }

    private func absentRankAnchors(current: Set<String>, now: Date) -> [String] {
        liveOrder.filter { id in
            guard !current.contains(id) else { return false }
            guard let t = absentSince[id] else { return true }   // 刚缺席（sync 尚未打戳）→ elapsed=0
            return now.timeIntervalSince(t) <= Self.rankRetentionGrace
        }
    }

    func sync(
        current: [String],
        appKeyOf: [String: String] = [:],
        projectionSample: InventoryOrderProjectionSample? = nil
    ) {
        let now = self.now()
        if let projectionSample, projectionSample != lastProjectionSample {
            inventoryLog.record(.orderProjectionChanged(
                projectionSample.payload(previousLiveIDs: lastProjectionSample?.currentLiveIDs ?? [])
            ))
            lastProjectionSample = projectionSample
        }
        stickyAppKeys.merge(appKeyOf) { _, new in new }

        let currentSet = Set(current)

        for id in current { absentSince.removeValue(forKey: id) }
        for id in liveOrder where !currentSet.contains(id) && absentSince[id] == nil {
            absentSince[id] = now
        }
        let anchors = absentRankAnchors(current: currentSet, now: now)
        let effectiveCurrent = current + anchors
        let expiredMemory = absentSince.filter {
            now.timeIntervalSince($0.value) > Self.rankRetentionGrace
        }
        let reconcileResult = StripOrdering.reconcileWithTrace(
            remembered: liveOrder,
            current: effectiveCurrent,
            appKeyOf: stickyAppKeys
        )
        let next = reconcileResult.order
        absentSince = absentSince.filter { now.timeIntervalSince($0.value) <= Self.rankRetentionGrace }
        for (chipID, since) in expiredMemory {
            inventoryLog.record(.orderMemoryDropped(InventoryOrderMemoryDroppedPayload(
                chipID: chipID,
                appKey: stickyAppKeys[chipID],
                previousIndex: liveOrder.firstIndex(of: chipID) ?? -1,
                absentForMs: max(0, Int((now.timeIntervalSince(since) * 1_000).rounded()))
            )))
        }
        let currentSetForLog = Set(current)
        let visibleNextForLog = next.filter(currentSetForLog.contains)
        for placement in reconcileResult.placements where currentSetForLog.contains(placement.chipID) {
            inventoryLog.record(.orderChipPlaced(InventoryOrderChipPlacedPayload(
                chipID: placement.chipID,
                appKey: stickyAppKeys[placement.chipID],
                index: visibleNextForLog.firstIndex(of: placement.chipID) ?? placement.index,
                reason: placement.reason.rawValue
            )))
        }
        if next != liveOrder {
            liveOrder = next
            persistLiveOrder()
        }

        let aliveKeys = currentSet.union(Set(liveOrder))
        stickyAppKeys = stickyAppKeys.filter { aliveKeys.contains($0.key) }
    }

    func reorder(draggedID: String, relativeTo targetID: String, after: Bool, current: [String]) {
        let base = StripOrdering.reconcile(remembered: liveOrder, current: current, appKeyOf: stickyAppKeys)
        let next = StripOrdering.reordering(base, move: draggedID, relativeTo: targetID, after: after)
        if next != liveOrder { liveOrder = next; persistLiveOrder() }
    }

    private func persistLiveOrder() {
        defaults.set(StripOrdering.persistableLiveOrder(liveOrder), forKey: orderKey)
        defaults.set(bootTime, forKey: bootKey)
    }

    private nonisolated static func bootTimeSeconds() -> Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        return sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 ? Int(tv.tv_sec) : 0
    }
}
