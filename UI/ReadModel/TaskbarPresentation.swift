import CoreGraphics
import Foundation

struct TaskbarWindowPresentation: Equatable {
    let item: StripItem
    let title: String
    let isActive: Bool

    var id: String { item.id }
}

struct TaskbarGroupPresentation: Equatable {
    let id: String
    let name: String
    let windows: [TaskbarWindowPresentation]

    var isActive: Bool { windows.contains(where: \.isActive) }
}

enum TaskbarPresentation {
    static func groups(items: [StripItem], order: [String], filter: StripDisplayFilter,
                       titles: [String: String], optimisticStates: [String: OptimisticWindowState],
                       spaces: WindowSpaceSnapshot = WindowSpaceSnapshot(),
                       appName: (StripItem) -> String) -> [TaskbarGroupPresentation] {
        let lookup = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var groupOrder: [String] = []
        var members: [String: [TaskbarWindowPresentation]] = [:]
        var names: [String: String] = [:]
        for id in order {
            guard let item = lookup[id], filter.shows(displayUUID: item.displayUUID) else { continue }
            guard spaces.shows(item.spaceIdentity, on: filter.scope ?? filter.resolvedWindowDisplayUUID(item.displayUUID)) else { continue }
            let key = item.applicationKey
            let name = WindowDisplayTitle.bounded(appName(item))
            if members[key] == nil { groupOrder.append(key) }
            names[key] = name
            let status = optimisticStates[item.actionWindowID]?.status.rawValue ?? item.status
            members[key, default: []].append(TaskbarWindowPresentation(
                item: item,
                title: WindowDisplayTitle.resolve(rawTitle: titles[item.id] ?? item.title, fallbackName: name),
                isActive: status == WindowStatus.active.rawValue
            ))
        }
        return groupOrder.map {
            TaskbarGroupPresentation(id: $0, name: names[$0] ?? $0, windows: members[$0] ?? [])
        }
    }

    static func actionWindowIDs(_ windows: [TaskbarWindowPresentation]) -> [String] {
        var seen = Set<String>()
        return windows.map(\.item.actionWindowID).filter { seen.insert($0).inserted }
    }
}

enum TaskbarContextAction: Equatable {
    case closeWindow(String)
    case closeWindows([String])
    case quitApplication
}

enum TaskbarContextMenuModel {
    static func actions(button: TaskbarButtonLayout, group: TaskbarGroupPresentation) -> [TaskbarContextAction] {
        let windows = group.windows.filter { button.windowIDs.contains($0.id) }
        let ids = TaskbarPresentation.actionWindowIDs(windows)
        guard let first = ids.first else { return [.quitApplication] }
        return [button.isCombined ? .closeWindows(ids) : .closeWindow(first), .quitApplication]
    }
}
