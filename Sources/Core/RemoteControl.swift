import CoreGraphics
import Foundation
import Observation

/// 手机端遥控板 → 外接屏的**单向**交互状态。
///
/// ## 为什么必须有这一层
/// 外接屏的 role 是 `windowExternalDisplayNonInteractive` —— 它**收不到任何触摸事件**：
///
/// - 真机：`ExternalDisplaySceneDelegate` 里 `window.isUserInteractionEnabled = false`，
///   系统本来也不向该 role 投递触摸。
/// - 模拟器 mock：`PassthroughWindow.hitTest` 恒返回 `nil`，触摸全部落到下层窗口。
///
/// 所以「在外接屏上上下滑动」这件事，物理上不可能由外接屏自己完成，
/// 必须在手机屏采集手势，再送到外接屏的渲染视图上。这就是本类的职责。
///
/// ## 与 `DisplayContentStore` 的分工
/// - `DisplayContentStore`：内容本身（图案、标题、动画开关）—— 手机端"选什么"。
/// - `RemoteControl`：视口状态（滚动、下拉、缩放、光标）—— 手机端"怎么看"。
///
/// 两者都是同进程单例，外接屏侧直接读，不需要任何跨 scene 通道。
///
/// ## 滚动为什么是**一个**标量而不是两个
/// 外接屏上有两件相关但语义不同的事：
/// - **滚动**：内容在瀑布流里往上走，`0...1`；
/// - **下拉**：已经在顶部还继续往下拽，把内容推下去露出背景墙。
///
/// 它们看似两个维度，实际是**同一条数轴上的两段**：手指一直在往一个方向拖，
/// 只是越过顶部之后语义变了。所以内部只留一个权威标量 `position`：
///
/// ```
/// position > 0  →  正常滚动进度（0 = 顶部，1 = 底部）
/// position < 0  →  顶部下拉的超出行程
/// ```
///
/// 对外仍然暴露两个属性，因为渲染侧关心的是两件不同的事（内容位移 / 背景墙露出量）。
/// 但**唯一权威只有 `position`** —— 若把它拆成两个可独立写的存储属性，
/// 下拉时被阻尼吃掉的那部分行程，在回拉时会变成凭空多出来的滚动，手指一松内容就跳。
@MainActor
@Observable
final class RemoteControl {

    static let shared = RemoteControl()

    /// 缩放倍率的合法区间，滑杆与手势都以此为准。
    static let zoomRange: ClosedRange<CGFloat> = 1...3

    /// **唯一权威**标量。见类型文档。
    ///
    /// 存归一化值而不是像素位移：外接屏可能是 1080p / 4K / 模拟器里的
    /// letterbox 小窗口，尺寸差异巨大。归一化之后，外接屏侧按自身内容高度
    /// 换算成实际位移，同一份手机端状态在哪块屏上都成立。
    private var position: CGFloat = 0

    /// 归一化滚动进度：`0` = 顶部，`1` = 底部。
    var scroll: CGFloat { max(0, position) }

    /// 顶部下拉进度：`0` = 没下拉，`1` = 内容顶边落到屏幕中线。
    ///
    /// 手感曲线由 `PullCurve` 提供 —— 渲染侧拿到的是**已含阻尼**的值，
    /// 直接乘 `ScrollMetrics.maxPullDistance` 即可，不必再处理一次曲线。
    var pull: CGFloat {
        PullCurve.progress(raw: -min(0, position))
    }

    /// 画面缩放倍率。
    private(set) var zoom: CGFloat = 1

    /// 光标当前由谁驱动。外接屏据此换渲染样式：
    /// 触控板画环形光标，空鼠画激光。
    enum PointerSource: String {
        case touch
        case airMouse
    }

    /// 手机端手指在外接屏上的归一化落点（0...1）；`nil` 表示光标不在屏上。
    private(set) var pointer: CGPoint?

    /// 光标的当前归属。空鼠与触控板共用同一个落点，谁在动谁说了算。
    private(set) var pointerSource: PointerSource = .touch

    /// 轻点计数。外接屏侧靠它的变化触发一次涟漪反馈。
    private(set) var tapCount: Int = 0

    /// 最近一次离散手势的说明，手机端面板上直读。
    private(set) var lastEvent: String = "等待操作"

    private init() {}

    // MARK: - 滚动与下拉

    /// 拖动增量，`dy` 为**归一化**位移（已除以触控板高度）。
    ///
    /// 方向约定跟手指走：手指上滑 `dy < 0` → 内容上移 → 进度增大。
    /// 越过顶部后自动转成下拉，调用方不需要自己判断边界。
    func scroll(by dy: CGFloat) {
        guard dy != 0 else { return }
        let next = min(max(position - dy, -PullCurve.rawLimit), 1)

        // 只在下拉真正开始的那一刻记一次事件，避免逐帧刷屏
        if next < 0, position >= 0 {
            lastEvent = "下拉露出背景墙"
        }
        position = next
    }

    /// 直接落到某个滚动进度，供滑杆等绝对定位控件使用。
    ///
    /// 会把下拉一并收掉 —— 绝对定位的语义是"把画面挪到某个位置"，
    /// 留着下拉会让内容停在半路。
    func scroll(to value: CGFloat) {
        position = Self.clamp(value, 0, 1)
        lastEvent = "跳转到 \(Int(scroll * 100))%"
    }

    func scrollToTop() {
        position = 0
        lastEvent = "回到顶部"
    }

    /// 直接落到某个下拉进度（`0...1`），供滑杆、按钮与调试预置使用。
    ///
    /// 会先把滚动收掉 —— 下拉只在顶部成立，`position` 是**一个**标量，
    /// 不可能同时是正的滚动进度和负的下拉行程。
    func pull(to value: CGFloat) {
        position = -PullCurve.rawValue(forProgress: Self.clamp(value, 0, 1))
        lastEvent = value > 0
            ? "下拉 \(Int(pull * 100))%"
            : "收起背景墙"
    }

    // MARK: - 光标

    /// 更新外接屏上的光标位置，入参为归一化坐标。
    ///
    /// - Parameter source: 本次写入的来源。传 `nil` 则沿用上一次的来源，
    ///   只有 `point != nil` 时才改写归属 —— 清空光标不该顺手把归属也改掉。
    func movePointer(to point: CGPoint?, source: PointerSource? = nil) {
        pointer = point.map { CGPoint(x: Self.clamp($0.x, 0, 1), y: Self.clamp($0.y, 0, 1)) }
        if pointer != nil, let source {
            pointerSource = source
        }
    }

    /// 清空光标（空鼠停止时调用），归属保持不变。
    func clearPointer() {
        pointer = nil
    }

    /// 记录一条来自空鼠的离散事件，手机端读数栏直读。
    func noteAirMouseEvent(_ text: String) {
        lastEvent = text
    }

    // MARK: - 缩放

    func setZoom(_ value: CGFloat) {
        zoom = Self.clamp(value, Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
        lastEvent = String(format: "缩放 %.2f×", zoom)
    }

    /// 相对缩放，`factor > 1` 放大。捏合手势逐帧调用。
    func zoom(by factor: CGFloat) {
        guard factor > 0 else { return }
        setZoom(zoom * factor)
    }

    // MARK: - 轻点

    func tap() {
        tapCount += 1
        lastEvent = "轻点 #\(tapCount)"
    }

    // MARK: - 复位

    func reset() {
        position = 0
        zoom = 1
        pointer = nil
        pointerSource = .touch
        lastEvent = "已复位"
    }

    // MARK: - Helpers

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
