import CoreGraphics
import Foundation

/// 手势面的识别逻辑 —— **纯状态机，不认识 SwiftUI，也不认识 UIKit**。
///
/// ## 为什么值得单独抽出来
/// `simctl` 没有触摸注入 API，`xcrun simctl` 与模拟器 GUI 都没有可脚本化的设备窗口，
/// 所以「手指按下 → 产生什么动作」这条链路本来**完全无法自动验证**。
/// 状态机一旦纯化，就可以直接喂一串模拟事件、断言它吐出的动作序列 ——
/// 而 slop 边界、轻点判定、逐帧增量恰恰是这里最容易写错的地方。
///
/// 视图侧只剩两件事：把触摸转发进来、把动作转发给 `RemoteControl`。
/// 触摸由 `TouchSurface`（UIKit）采集 —— SwiftUI 的 `DragGesture` **读不到手指数量**，
/// 而"有几根手指"正是触摸板与空鼠栏唯一的分歧点。
///
/// ## 一个状态机同时管两件事
///
/// ```
/// idle ──按下──▶ touching ──位移越过 slop──▶ dragging
///                   │                          │
///                   └─抬起且够短─▶ 轻点          └─抬起─▶ 什么都不做
/// ```
///
/// 关键在 `touching` 这一段**不产生任何滚动**：它吃掉 slop 内的位移。
/// - 若一开始就滚动、抬起时再补一次点击 → 每次轻点都会顺带把画面推走几个点；
/// - 若把 slop 内积攒的位移补发出去 → 起手会"跳"一下。
///
/// 吃掉它，两边都干净。
///
/// ## 为什么要自己算逐帧增量
/// 每次采样的锚点是**手指当前位置**，逐帧增量由相邻两个锚点相减得到。
/// 直接拿"从按下到现在的总位移"当增量，滚动速度会随拖拽时长线性放大
/// （拖 1 秒滚 1 屏、拖 2 秒滚 3 屏）。
///
/// ## 单指会话与多指会话
/// 一次会话（按下 → 全部抬起）内只要出现过两根以上手指，就**整段**按多指处理，
/// 光标与轻点全部关掉。理由是锚点会在指数变化时**跳**（两指质心 → 剩下那根手指）：
/// 那一跳若漏出去，光标会被瞬间拽走，或被当成一次大位移滚出去。
///
/// - 单指会话 → 光标 + 轻点（滚动与否看 `ScrollGesture`）；
/// - 多指会话 → 只滚动，光标与轻点都不参与。
///
/// 指数变化的那一帧和"吃掉 slop"是同一个道理：**吃掉，不补发**，并且把死区重开。
struct PadGesture {

    /// 状态机吐出的一格动作。一帧可能同时产生多个（移动光标 + 滚动）。
    enum Action: Equatable {

        /// 更新光标落点，已归一化到 `0...1`。
        case pointer(CGPoint)

        /// 滚动，增量是**已除以采集面高度**的归一化位移。
        case scroll(CGFloat)

        /// 点击确认。
        case tap
    }

    /// 采集面认不认单指滚动 —— 触摸板与空鼠栏唯一的分歧点。
    enum ScrollGesture: Equatable {

        /// 单指会话就能滚动。
        ///
        /// 空鼠栏用的就是它：手机举在手上，再腾出第二根手指不现实。
        case oneFinger

        /// 只有多指会话才滚动，单指留给光标。
        ///
        /// 触摸板用这个 —— 单指移光标、双指滚画面，两种意图各自独占一种指数。
        case twoFinger
    }

    /// 判定"这是拖动而不是轻点"的位移阈值（点）。
    ///
    /// 同时兼任滚动的起手死区。8pt 与 UIKit 的手势识别容差同量级 ——
    /// 比它小会让手指的天然抖动被当成拖动，比它大则轻点会变得难以触发。
    static let slop: CGFloat = 8

    /// 轻点的最长按下时长（秒）。
    ///
    /// 没有这一条的话，"按住不动再抬手"也会被算成轻点 ——
    /// 而空鼠瞄准时手指自然搭在面板上是很常见的姿势。
    /// 抬手时误触发一次点击，比漏掉一次点击更让人恼火。
    static let tapMaxDuration: TimeInterval = 0.4

    private enum Phase: Equatable {
        case idle
        /// 手指在屏上，但位移还没越过 slop。
        case touching
        /// 已越过 slop，进入拖动。
        case dragging
    }

    private var phase: Phase = .idle
    private var startTime = Date.distantPast

    /// 上一次采样的锚点：单指时是落点，多指时是质心。
    private var lastAnchor = CGPoint.zero

    private var lastCount = 0

    /// 本次会话里出现过的最大指数。一旦超过 1，整段会话按多指处理。
    private var peakCount = 0

    /// 本次会话里累计的**同指数**位移，只用来判 slop。
    /// 指数变化时的锚点跳变不进这里 —— 它压根不该算成位移。
    private var accumulated = CGSize.zero

    /// 手指是否停在采集面上（含尚未越过 slop 的那一段）。
    var isActive: Bool { phase != .idle }

    /// 是否已进入拖动。视图用它决定要不要收起提示文案。
    var isDragging: Bool { phase == .dragging }

    init() {}

    // MARK: - 事件

    /// 一次触摸采样：当前所有手指的位置。
    ///
    /// - Parameters:
    ///   - touches: 采集面坐标下的**全部**手指落点，空数组表示没有手指。
    ///   - time: 采样时间。
    ///   - padSize: 采集面尺寸，用来归一化。
    ///   - mapsPointer: 是否把落点映射成光标。
    ///   - scrollGesture: 单指还是多指才滚动。
    ///   - isScrollEnabled: 捏合进行中由调用方置 `false`。
    mutating func touched(
        _ touches: [CGPoint],
        time: Date,
        padSize: CGSize,
        mapsPointer: Bool,
        scrollGesture: ScrollGesture,
        isScrollEnabled: Bool
    ) -> [Action] {
        guard padSize.width > 0, padSize.height > 0 else { return [] }
        guard let anchor = Self.anchor(of: touches) else { return [] }

        let count = touches.count

        if phase == .idle {
            phase = .touching
            startTime = time
            lastAnchor = anchor
            lastCount = count
            peakCount = count
            accumulated = .zero
        }

        // 先更新峰值再判语义：第二根手指落下的那一帧就应该算多指，
        // 否则它会以"两指质心"的姿态写一次光标。
        peakCount = max(peakCount, count)
        let isMultiTouch = peakCount > 1

        var actions: [Action] = []

        // 落点映射是**立即**的：光标就该跟着手指走，不该等 slop。
        // slop 只约束滚动。
        if mapsPointer, !isMultiTouch {
            actions.append(.pointer(Self.normalized(anchor, in: padSize)))
        }

        // 指数一变，锚点会跳（两指质心 → 剩下那根手指）。
        // 这一帧整个吃掉：不累加、不出位移。死区也跟着重开 ——
        // 换了一种手指组合，就是换了一种手势意图。
        if count != lastCount {
            lastCount = count
            lastAnchor = anchor
            accumulated = .zero
            return actions
        }

        let delta = CGSize(
            width: anchor.x - lastAnchor.x,
            height: anchor.y - lastAnchor.y
        )
        lastAnchor = anchor
        accumulated.width += delta.width
        accumulated.height += delta.height

        guard phase == .dragging || Self.exceedsSlop(accumulated) else { return actions }

        if phase != .dragging {
            phase = .dragging
            // 把此刻的位移记成基准，也就是**吃掉 slop 内的位移**。
            // 不这样做的话，这一帧会一次性补上之前积攒的全部位移，画面"跳"一下。
            accumulated = .zero
            return actions
        }

        guard isScrollEnabled, Self.allowsScroll(scrollGesture, isMultiTouch: isMultiTouch) else {
            return actions
        }

        // 横向分量**刻意忽略但不拦截**：斜着拖照样能滚，只是横向那段不产生位移。
        // 若改成"只认纯竖向拖动"，斜拖会被判成手势失败，手感立刻变差。
        if delta.height != 0 {
            actions.append(.scroll(delta.height / padSize.height))
        }
        return actions
    }

    /// 手指全部抬起。
    mutating func ended(time: Date) -> [Action] {
        defer { reset() }

        // 轻点的充要条件：**从未越过 slop**、**全程只有一根手指**，且按得够短。
        // 越过 slop 之后即使又拖回原点也不算 —— 手指已经明确表达了拖动的意图。
        // 多指会话同样不算：双指滑完顺手抬起，不该把脚下那张卡选中。
        guard phase != .dragging else { return [] }
        guard peakCount <= 1 else { return [] }
        guard time.timeIntervalSince(startTime) <= Self.tapMaxDuration else { return [] }
        return [.tap]
    }

    /// 手势被系统取消（来电、切后台…）。
    ///
    /// **不产生点击** —— 取消不是确认。用户没抬手，就不该当成按下了扳机。
    mutating func cancelled() {
        reset()
    }

    // MARK: - Helpers

    private mutating func reset() {
        phase = .idle
        startTime = .distantPast
        lastAnchor = .zero
        lastCount = 0
        peakCount = 0
        accumulated = .zero
    }

    /// 一次采样的锚点：单指取落点，多指取质心。
    ///
    /// 取质心而不是"第一根手指"：两指的整体平移才是滚动的意图，
    /// 盯着其中一根的话，另一根绕它转一圈也会被算成滚动。
    private static func anchor(of touches: [CGPoint]) -> CGPoint? {
        guard let first = touches.first else { return nil }
        guard touches.count > 1 else { return first }

        let sum = touches.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(touches.count), y: sum.y / CGFloat(touches.count))
    }

    /// 这种手指组合认不认滚动。
    private static func allowsScroll(_ policy: ScrollGesture, isMultiTouch: Bool) -> Bool {
        switch policy {
        case .oneFinger: return true
        case .twoFinger: return isMultiTouch
        }
    }

    /// 位移是否越过了阈值。
    ///
    /// 取两轴的最大值而不是欧氏距离：横向拖动在这一层是"允许但不产生位移"的，
    /// 用最大值语义更直白 —— 任一轴明显动了就不算轻点。
    private static func exceedsSlop(_ translation: CGSize) -> Bool {
        max(abs(translation.width), abs(translation.height)) > slop
    }

    private static func normalized(_ point: CGPoint, in padSize: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x / padSize.width, 0), 1),
            y: min(max(point.y / padSize.height, 0), 1)
        )
    }
}
