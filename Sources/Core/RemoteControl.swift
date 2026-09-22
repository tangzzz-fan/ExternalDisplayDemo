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
/// - `RemoteControl`：视口状态（滚动、缩放、光标）—— 手机端"怎么看"。
///
/// 两者都是同进程单例，外接屏侧直接读，不需要任何跨 scene 通道。
@MainActor
@Observable
final class RemoteControl {

    static let shared = RemoteControl()

    /// 缩放倍率的合法区间，滑杆与手势都以此为准。
    static let zoomRange: ClosedRange<CGFloat> = 1...3

    /// 归一化滚动进度：`0` = 顶部，`1` = 底部。
    ///
    /// 刻意存归一化值而不是像素位移：外接屏可能是 1080p / 4K / 模拟器里的
    /// letterbox 小窗口，尺寸差异巨大。归一化之后，外接屏侧按自身内容高度
    /// 换算成实际位移，同一份手机端状态在哪块屏上都成立。
    private(set) var scroll: CGFloat = 0

    /// 画面缩放倍率。
    private(set) var zoom: CGFloat = 1

    /// 手机端手指在外接屏上的归一化落点（0...1）；`nil` 表示光标不在屏上。
    private(set) var pointer: CGPoint?

    /// 轻点计数。外接屏侧靠它的变化触发一次涟漪反馈。
    private(set) var tapCount: Int = 0

    /// 最近一次离散手势的说明，手机端面板上直读。
    private(set) var lastEvent: String = "等待操作"

    private init() {}

    // MARK: - 滚动

    /// 拖动增量，`dy` 为**归一化**位移（已除以触控板高度）。
    ///
    /// 方向约定跟手指走：手指上滑 `dy < 0` → 内容上移 → 进度增大。
    func scroll(by dy: CGFloat) {
        guard dy != 0 else { return }
        scroll = Self.clamp(scroll - dy, 0, 1)
    }

    /// 直接落到某个进度，供滑杆等绝对定位控件使用。
    func scroll(to value: CGFloat) {
        scroll = Self.clamp(value, 0, 1)
        lastEvent = "跳转到 \(Int(scroll * 100))%"
    }

    func scrollToTop() {
        scroll = 0
        lastEvent = "回到顶部"
    }

    // MARK: - 光标

    /// 更新外接屏上的光标位置，入参为归一化坐标。
    func movePointer(to point: CGPoint?) {
        pointer = point.map { CGPoint(x: Self.clamp($0.x, 0, 1), y: Self.clamp($0.y, 0, 1)) }
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
        scroll = 0
        zoom = 1
        pointer = nil
        lastEvent = "已复位"
    }

    // MARK: - Helpers

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
