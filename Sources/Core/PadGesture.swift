import CoreGraphics
import Foundation

/// 单指手势面的识别逻辑 —— **纯状态机，不认识 SwiftUI**。
///
/// ## 为什么值得单独抽出来
/// `simctl` 没有触摸注入 API，`xcrun simctl` 与模拟器 GUI 都没有可脚本化的设备窗口，
/// 所以「手指按下 → 产生什么动作」这条链路本来**完全无法自动验证**。
/// 状态机一旦纯化，就可以直接喂一串模拟事件、断言它吐出的动作序列 ——
/// 而 slop 边界、轻点判定、逐帧增量恰恰是这里最容易写错的地方。
///
/// 视图（`GesturePad`）只剩两件事：把手势事件转发进来、把动作转发给 `RemoteControl`。
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
/// `DragGesture.translation` 是**累计**值。直接拿它当增量，
/// 滚动速度会随拖拽时长线性放大（拖 1 秒滚 1 屏、拖 2 秒滚 3 屏）。
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
    private var lastTranslation = CGSize.zero

    /// 手指是否停在采集面上（含尚未越过 slop 的那一段）。
    var isActive: Bool { phase != .idle }

    /// 是否已进入拖动。视图用它决定要不要收起提示文案。
    var isDragging: Bool { phase == .dragging }

    init() {}

    // MARK: - 事件

    /// 手指按下或移动。
    ///
    /// - Parameters:
    ///   - translation: `DragGesture` 给的**累计**位移。
    ///   - location: 手指当前位置（采集面坐标）。
    ///   - time: 事件时间。
    ///   - padSize: 采集面尺寸，用来归一化。
    ///   - mapsPointer: 是否把落点映射成光标。
    ///   - isScrollEnabled: 捏合进行中由调用方置 `false`。
    mutating func moved(
        translation: CGSize,
        location: CGPoint,
        time: Date,
        padSize: CGSize,
        mapsPointer: Bool,
        isScrollEnabled: Bool
    ) -> [Action] {
        guard padSize.width > 0, padSize.height > 0 else { return [] }

        if phase == .idle {
            phase = .touching
            startTime = time
            lastTranslation = translation
        }

        var actions: [Action] = []

        // 落点映射是**立即**的：光标就该跟着手指走，不该等 slop。
        // slop 只约束滚动。
        if mapsPointer {
            actions.append(.pointer(CGPoint(
                x: clamp(location.x / padSize.width),
                y: clamp(location.y / padSize.height)
            )))
        }

        guard phase == .dragging || Self.exceedsSlop(translation) else { return actions }

        if phase != .dragging {
            phase = .dragging
            // 把此刻的位移记成基准，也就是**吃掉 slop 内的位移**。
            // 不这样做的话，这一帧会一次性补上之前积攒的全部位移，画面"跳"一下。
            lastTranslation = translation
            return actions
        }

        let delta = CGSize(
            width: translation.width - lastTranslation.width,
            height: translation.height - lastTranslation.height
        )
        lastTranslation = translation

        // 横向分量**刻意忽略但不拦截**：斜着拖照样能滚，只是横向那段不产生位移。
        // 若改成"只认纯竖向拖动"，斜拖会被判成手势失败，手感立刻变差。
        if isScrollEnabled, delta.height != 0 {
            actions.append(.scroll(delta.height / padSize.height))
        }
        return actions
    }

    /// 手指抬起。
    mutating func ended(time: Date) -> [Action] {
        defer { reset() }

        // 轻点的充要条件：**从未越过 slop**，且按得够短。
        // 越过 slop 之后即使又拖回原点也不算 —— 手指已经明确表达了拖动的意图。
        guard phase != .dragging else { return [] }
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
        lastTranslation = .zero
    }

    /// 位移是否越过了阈值。
    ///
    /// 取两轴的最大值而不是欧氏距离：横向拖动在这一层是"允许但不产生位移"的，
    /// 用最大值语义更直白 —— 任一轴明显动了就不算轻点。
    private static func exceedsSlop(_ translation: CGSize) -> Bool {
        max(abs(translation.width), abs(translation.height)) > slop
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}
