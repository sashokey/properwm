import Foundation

/// 拖动来源：决定投放区、落点动作、载体绘制三处分支。
/// `.folder` = 固定文件夹 chip（区内重排 + 拖出移除 + 拖回窗口区打开）,**与 strip/drawer 收纳
/// 语义完全隔离**：不进 drawerStore、不进投放区（canExternalDrop=false）、不走 convert/revert;
/// DockStripView 只提供落点几何，最终 commit 由 `endDrag()` 的 mouseUp/轮询兜底路径触发。
/// `.messaging` = 消息区 app chip（区内重排 + 拖进抽屉收纳）：投放区与 `.strip` 相同
/// （胶囊 + 打开的抽屉体），任务条其余区域不是它的落点。
/// 定义放本文件（而非 DragController.swift）：测试 target 按"本地编译源文件"工作，纯决策层
/// 必须不带 DragController 的 AppKit 依赖就能编译。
enum DragSource { case strip, drawer, folder, messaging }

/// 抽屉图标拖到任务条时的行为模式（纯决策，DockStripView 喂事实）。
enum DrawerDragOutMode: Equatable {
    case reject             // 未运行的消息应用 → 不接受（留在抽屉）
    case releaseToMessaging // 运行中的消息应用 → 进消息区范围才临时释放回消息区
    case unstash            // 有真窗口 → 现有精确落位路径
    case keepPlacement      // app fallback / kept placeholder → app 级落位，绝不修改 kept
}

/// 跨面板拖拽转换的纯决策层（Codex 评审 2026-07-11 P2-6）。几何、store、面板都不进来——
/// 调用方喂当前事实，这里只回答"该做什么"，转换的执行与回滚在 `DragController`。
enum DragConversionPlan {

    /// 抽屉拖出模式判定。消息判定必须在真窗口判定**之前**——运行中的消息应用有主窗口，
    /// 否则会误入 unstash。
    ///
    /// **消息成员这一支判的是「释放过去之后它会不会真的出现在消息区」**，判据必须和消息区
    /// 自己的可见规则同源（`AppMembershipProjection.visibleMessagingIDs` = 在跑 ∪ 已保留）。
    /// 这里曾经判的是 `isInSnapshot`（窗口清单），那是**另一个真相源**：微信主窗口关着时
    /// 进程在跑、图标下面有运行点、消息区也照样显示它，唯独窗口清单里没有它——于是
    /// 「明明亮着运行点却怎么都拖不回消息区」（owner 2026-08-20 实测，日志实证
    /// `mode=reject 在窗口清单=False 在跑=True`）。
    static func drawerDragOutMode(bundleID: String,
                                  isMessagingMember: Bool,
                                  isInSnapshot: Bool,
                                  isRunningProcess: Bool,
                                  hasRealWindow: Bool,
                                  isKept: Bool) -> DrawerDragOutMode {
        guard !bundleID.isEmpty else { return .reject }
        if isMessagingMember {
            // 两者都不成立才拒收——那种情况释放过去确实会凭空消失。
            return (isRunningProcess || isKept) ? .releaseToMessaging : .reject
        }
        if hasRealWindow { return .unstash }
        // app-* fallback while running, or a kept placeholder while stopped.
        return isInSnapshot || isKept ? .keepPlacement : .reject
    }

    /// `endDrag` 松手收尾动作（`.messaging` / `.drawer` 来源；`.strip`/`.folder` 不经这里）。
    enum EndAction: Equatable {
        case none
        /// 消息区 chip 落在投放区（胶囊/开着的抽屉）→ drawer.add 收纳。
        case stashMessagingChip
        /// 抽屉图标已转正进任务条 → 通知顺序层 commit。
        case commitDrawerToStrip
        /// 抽屉图标未转正、落任务条、非消息成员 → 降级移出（drawer.remove）。
        case fallbackUnstash
    }

    /// 松手决策。消息成员的抽屉图标**永不**走降级 unstash：它回任务条的唯一路径是
    /// 进消息区范围的临时释放（drawerToMessaging），其他位置松手一律留在抽屉（评审 P1-3）。
    /// 已释放回消息区的载荷来源是 `.messaging`：不在投放区 → `.none`（drawer.remove 已发生，
    /// 松手即落定）；在投放区 → 收纳（等效回滚，drawer.add 幂等）。
    static func endAction(source: DragSource,
                          isConvertedToStrip: Bool,
                          isOverDropZone: Bool,
                          isMessagingMember: Bool) -> EndAction {
        switch source {
        case .strip, .folder:
            return .none
        case .messaging:
            return isOverDropZone ? .stashMessagingChip : .none
        case .drawer:
            if isConvertedToStrip { return .commitDrawerToStrip }
            guard isOverDropZone, !isMessagingMember else { return .none }
            return .fallbackUnstash
        }
    }

    /// 拖动落定后是否给这个 app 打开「在程序坞中保留」（owner 2026-08-06 定）。
    ///
    /// **只管进、不管出**：只有这次拖动把它从抽屉外带进抽屉才打开；从抽屉拖回
    /// 任务条一律不关（用户可能本来就自己勾过保留，反向关掉会抹掉与抽屉无关的设置）。
    ///
    /// **每次拖入都会重新打开**，不是一生只播种一次。用户手动取消勾选后再拖进来会
    /// 再次被勾上——这是 owner 定的语义：拖进抽屉是明确的主动动作，每次都算重新表达
    /// 「我要它长期放这里」。**别拿它类比 `AppMembershipController.markMessaging`**：
    /// 那条靠 `MessagingAppStore.mark` 的首次返回值实现真正的一次性播种，这里有意
    /// 不引入等价的「曾经自动勾过谁」历史存档（为边角场景加一份永久数据不划算）。
    /// `DragControllerConversionTests` 有一条用例专门锁这个行为，别当 bug 修。
    ///
    /// 只在 `endDrag()` 落定后调用。转换预览（`convert*`）与回滚（`revert*` /
    /// `cancelDrag`）阶段**一律不碰 kept**，所以那套对称的 placement 事务不变。
    ///
    /// - Parameter originSource: **起拖时**的来源。不能传 `draggingPayload.source`——
    ///   进抽屉体的转换会把它翻成 `.drawer`，与抽屉内重排撞车。
    /// - Parameter endedInDrawer: 落定后它到底还在不在抽屉里（读 `DrawerStore`）。
    static func enablesKeptOnDrop(originSource: DragSource, endedInDrawer: Bool) -> Bool {
        guard endedInDrawer else { return false }
        return originSource == .strip || originSource == .messaging
    }
}
