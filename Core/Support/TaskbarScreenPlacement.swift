import Foundation

/// 任务条屏幕安放模式（多屏路线四档：2026-08-26 上 ②，2026-09-02 立项 ③④）。
/// rawValue 即 UserDefaults 持久化值。老版本读到不认识的 rawValue 会按 followMouse 跑
/// 且**不改写键**（`AppSettingsStore`），所以新档位只加不改名。
/// **与已删除的旧 `com.tungsten.edge.displayMode` 键无关**——那个键是孤儿键，永不再读。
enum TaskbarScreenMode: String {
    case followMouse
    case pinned
    /// ③ 所有屏都显示、内容相同。
    case allScreens
    /// ④ 所有屏都显示、各屏只显示本屏窗口。
    case allScreensPerDisplay
}

/// 固定屏的持久化身份。`uuid` 来自 `CGDisplayCreateUUIDFromDisplayID`（基于 EDID，
/// 拔插 / 换口 / 休眠唤醒后稳定）；`name` 是选择那一刻 `localizedName` 的快照，
/// **只供设置页展示**（屏幕拔掉后 Picker 里还能显示「XX（未连接）」），永不参与匹配。
struct PinnedScreenSelection: Equatable {
    let uuid: String
    let name: String
}

/// 任务条显示位置。默认 `.followMouse` = 现状行为（底边停留切屏）。
enum TaskbarScreenPlacement: Equatable {
    case followMouse
    case pinned(PinnedScreenSelection)
    case allScreens
    case allScreensPerDisplay

    /// 悬停切屏（底边停留搬 dock）只在跟随鼠标档生效——所有屏都有条时没有东西要搬。
    var allowsHoverScreenSwitching: Bool {
        self == .followMouse
    }

    /// ③④：每块已连接屏各一个任务条单元。
    var showsOnEveryDisplay: Bool {
        switch self {
        case .allScreens, .allScreensPerDisplay: return true
        case .followMouse, .pinned: return false
        }
    }

    var mode: TaskbarScreenMode {
        switch self {
        case .followMouse: return .followMouse
        case .pinned: return .pinned
        case .allScreens: return .allScreens
        case .allScreensPerDisplay: return .allScreensPerDisplay
        }
    }

    var pinnedSelection: PinnedScreenSelection? {
        switch self {
        case .pinned(let selection): return selection
        case .followMouse, .allScreens, .allScreensPerDisplay: return nil
        }
    }
}

/// 单个任务条单元（一个 `PanelCoordinator`）的安放。①② 下唯一的单元 `.followSettings`
/// 读设置自己决定；③④ 下编排层给每块屏建一个 `.fixed` 单元——它的行为**就是**固定档
///（不切屏、只在本屏底边唤醒、本屏缺席暂回主屏），只是屏由编排层指定而不是由设置指定。
enum TaskbarUnitPlacement: Equatable {
    case followSettings
    case fixed(displayUUID: String)
}

/// 固定屏 → 当前屏幕集合的纯解析。运行时不存任何额外状态：每次屏幕参数变化 /
/// 设置变更时幂等地重解析一遍，屏一回来自然搬回去。
enum TaskbarScreenResolution {
    enum Outcome: Equatable {
        /// 固定的屏在场，落在该下标。
        case matched(index: Int)
        /// 固定的屏缺席，回落主屏（无主屏则 0）。
        case fallback(index: Int)
    }

    /// - Parameters:
    ///   - pinnedUUID: 存下来的固定屏 UUID。
    ///   - screenUUIDs: 当前 `NSScreen.screens` 逐个读出的 UUID；读不出的为 nil（不误匹配）。
    ///   - mainIndex: `NSScreen.main` 在 screens 里的下标（可能为 nil）。
    /// - Returns: 屏幕集合为空时返回 nil（无处可放，交调用方兜底）。
    static func resolve(pinnedUUID: String, screenUUIDs: [String?], mainIndex: Int?) -> Outcome? {
        guard !screenUUIDs.isEmpty else { return nil }
        if let index = screenUUIDs.firstIndex(where: { $0 == pinnedUUID }) {
            return .matched(index: index)
        }
        if let mainIndex, screenUUIDs.indices.contains(mainIndex) {
            return .fallback(index: mainIndex)
        }
        return .fallback(index: 0)
    }

    /// 设置页 Picker 的展示名去重：两台同型号显示器同名时，第二台起加序号
    /// （「LG HDR 4K」「LG HDR 4K (2)」）。顺序与输入一致。
    static func displayTitles(names: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for name in names {
            counts[name, default: 0] += 1
        }
        var seen: [String: Int] = [:]
        return names.map { name in
            guard counts[name, default: 0] > 1 else { return name }
            let ordinal = seen[name, default: 0] + 1
            seen[name] = ordinal
            return ordinal == 1 ? name : "\(name) (\(ordinal))"
        }
    }
}

/// 状态菜单「单/多屏模式 ▸」子菜单的纯展示模型（2026-08-26 入口从设置窗口搬到菜单）。
/// 与 `LaunchAtLoginMenuPresentation` 同一房规：判定在这里、可单测，controller 只负责渲染。
struct TaskbarScreenMenuPresentation {
    /// 一行代表的选择。`token` 是给 `NSMenuItem.representedObject` 用的字符串往返
    /// （controller 在测试 target 也编译，不能用 ClosureMenuItem）。
    enum Selection: Equatable {
        case followMouse
        case screen(uuid: String)
        case allScreens
        case allScreensPerDisplay

        private static let screenPrefix = "screen:"

        var token: String {
            switch self {
            case .followMouse: return "followMouse"
            case .allScreens: return "allScreens"
            case .allScreensPerDisplay: return "allScreensPerDisplay"
            case .screen(let uuid): return Self.screenPrefix + uuid
            }
        }

        init?(token: String) {
            switch token {
            case "followMouse": self = .followMouse
            case "allScreens": self = .allScreens
            case "allScreensPerDisplay": self = .allScreensPerDisplay
            default:
                guard token.hasPrefix(Self.screenPrefix) else { return nil }
                let uuid = String(token.dropFirst(Self.screenPrefix.count))
                guard !uuid.isEmpty else { return nil }
                self = .screen(uuid: uuid)
            }
        }

        /// 便于旧测试 / 调用方按屏 UUID 取值；非屏幕行为 nil。
        var screenUUID: String? {
            if case .screen(let uuid) = self { return uuid }
            return nil
        }
    }

    struct Item: Equatable {
        let selection: Selection
        let title: String
        /// Grey text after the title, on the same line. Only 跟随栏 has one: its short name hides the
        /// trigger (the bar moves only after the pointer dwells on a screen's bottom edge).
        let hint: String?
        let isChecked: Bool
    }

    /// 子菜单的一行：灰色组标题（不可点）/ 分隔线 / 可选项。两组 + 组标题是 owner 2026-09-02 定的形态
    ///（五行平铺时「所有屏幕」和「所有屏幕，各屏只显示本屏窗口」两行意义不清）。
    enum Row: Equatable {
        case header(String)
        case separator
        case option(Item)
    }

    /// Everything before the screen name on a 固定在 row. 跟随栏's hint is aligned to start after it.
    static var pinnedTitlePrefix: String {
        String(format: String(localized: "Pinned to %@"), "")
    }

    /// 整行（连同子菜单）不显示。
    let isHidden: Bool
    let rows: [Row]
    /// 可选项（按出现顺序），给测试 / 老调用方。
    var items: [Item] {
        rows.compactMap { row in
            if case let .option(item) = row { return item }
            return nil
        }
    }

    /// - Parameter connectedScreens: 当前在场的屏，`title` 已去重（`displayTitles`）。
    init(placement: TaskbarScreenPlacement, connectedScreens: [(uuid: String, title: String)]) {
        let pinned = placement.pinnedSelection
        // 只有一块屏**且**当前既不是固定档也不是所有屏档才隐藏。少了后半句会出死角：
        // 固定到外接屏后把它拔掉 / 开着「所有屏幕」拔到只剩一块，整行消失 → 再也切不回「跟随鼠标」。
        isHidden = connectedScreens.count < 2 && pinned == nil && !placement.showsOnEveryDisplay

        // Group 1 — single-display mode: hover-to-switch, or pinned to one screen.
        var rows: [Row] = [
            .header(String(localized: "Single-display mode")),
            .option(Item(
                selection: .followMouse,
                title: String(localized: "Follows the pointer"),
                hint: String(localized: "Hover a screen's bottom edge to switch"),
                isChecked: placement == .followMouse
            ))
        ]
        rows += connectedScreens.map { screen in
            .option(Item(
                selection: .screen(uuid: screen.uuid),
                title: String(format: String(localized: "Pinned to %@"), screen.title),
                hint: nil,
                isChecked: pinned?.uuid == screen.uuid
            ))
        }
        // 固定的屏此刻不在场：第一组末尾补一项「固定在 XX（未连接）」并保持选中——选择不丢，接回自动生效。
        if let pinned, !connectedScreens.contains(where: { $0.uuid == pinned.uuid }) {
            rows.append(.option(Item(
                selection: .screen(uuid: pinned.uuid),
                title: String(
                    format: String(localized: "Pinned to %@"),
                    String(format: String(localized: "%@ (disconnected)"), pinned.name)
                ),
                hint: nil,
                isChecked: true
            )))
        }
        // Group 2 — multi-display mode: ③ same content everywhere / ④ each bar lists only its own screen.
        rows.append(.separator)
        rows.append(.header(String(localized: "Multi-display mode")))
        rows.append(.option(Item(
            selection: .allScreens,
            title: String(localized: "Mirrored bars"),
            hint: nil,
            isChecked: placement == .allScreens
        )))
        rows.append(.option(Item(
            selection: .allScreensPerDisplay,
            title: String(localized: "Separate bar per display"),
            hint: nil,
            isChecked: placement == .allScreensPerDisplay
        )))
        self.rows = rows
    }
}
