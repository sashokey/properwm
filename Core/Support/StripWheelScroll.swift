import CoreGraphics

/// 任务条横向滚动的纯决策：把一个滚动事件折算成条内的横向位移。
///
/// 为什么需要它：任务条装不下时靠横向 `ScrollView` 滚，而横向 ScrollView **对垂直滑动本来就
/// 不响应**。原来只接管离散滚轮（`hasPreciseScrollingDeltas == false`），于是触控板、妙控鼠标、
/// 开了平滑滚动的鼠标（Logitech Options 等）——它们发的都是连续事件，见
/// `Docs/27-product-decisions.md`「鼠标滚轮反转」——垂直滑一律石沉大海（issue #14）。
///
/// 副作用（读 `NSEvent`、写 `NSScrollView`）留在 `DockStripView` 的拦截视图里。
enum StripWheelScroll {
    /// 离散滚轮一格换算成多少 pt。已定稿的手感，改动前后必须一致。
    static let wheelSpeed: CGFloat = 56
    /// 离散滚轮单次步长上限。快速甩轮时的 delta 可以很大，不封顶会一下飞到头。
    static let maxStep: CGFloat = 120

    /// 从 `NSEvent` 提炼出来的纯输入。
    struct Input: Equatable {
        var deltaX: CGFloat
        var deltaY: CGFloat
        /// `NSEvent.hasPreciseScrollingDeltas`：true = 连续事件（触控板 / 妙控 / 平滑滚轮）。
        var hasPreciseDeltas: Bool
        /// `NSEvent.isDirectionInvertedFromDevice`：即系统「自然滚动」对该设备是否生效。
        /// **取自事件本身而不是读 `com.apple.swipescrolldirection`**：逐设备正确，
        /// 而且事件热路径上不再有 UserDefaults 读取。
        var isDirectionInverted: Bool

        init(deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool, isDirectionInverted: Bool) {
            self.deltaX = deltaX
            self.deltaY = deltaY
            self.hasPreciseDeltas = hasPreciseDeltas
            self.isDirectionInverted = isDirectionInverted
        }
    }

    /// 条内要走的横向位移（pt，正 = 往后翻）；`nil` = 本事件不接管，原样交给底下的 `NSScrollView`。
    static func horizontalStep(for input: Input) -> CGFloat? {
        guard input.deltaY != 0 else { return nil }
        // **横向为主的手势必须放行**：触控板左右滑、妙控鼠标左右滑现在就由 NSScrollView
        // 原生处理，带惯性和橡皮筋；接管过来只会更差。
        guard abs(input.deltaY) > abs(input.deltaX) else { return nil }

        let sign: CGFloat = input.isDirectionInverted ? -1 : 1
        if input.hasPreciseDeltas {
            // 连续事件的 delta 本来就是点数，1:1 即可；再乘 wheelSpeed 会飞出去。
            // 也不封顶——惯性阶段的大 delta 正是它该有的手感。
            let step = sign * input.deltaY
            return step == 0 ? nil : step
        }
        let raw = sign * input.deltaY * wheelSpeed
        let step = min(max(raw, -maxStep), maxStep)
        return step == 0 ? nil : step
    }
}
