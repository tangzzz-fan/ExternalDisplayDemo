import SwiftUI
import UIKit

/// 一次触摸采样：此刻屏上的**全部**手指，坐标在采集面内部。
struct TouchSampling {

    /// 手指落点。空数组不会被上报 —— 全部抬起走 `TouchSurfaceEvent.ended`。
    let points: [CGPoint]

    let time: Date
}

/// 触摸层向上报的事件。
enum TouchSurfaceEvent {

    /// 还在按着，手指位置有更新。
    case sample(TouchSampling)

    /// 全部手指都抬起了。
    case ended(Date)

    /// 被系统取消（来电、切后台…）。
    case cancelled
}

/// 一块**把触摸原样上抛的透明层**，用来取代 SwiftUI 的 `DragGesture`。
///
/// ## 为什么不继续用 `DragGesture`
/// SwiftUI 在 iOS 17 上拿不到"有几根手指"：
///
/// | 手势 | 拿得到什么 | 拿不到什么 |
/// |---|---|---|
/// | `DragGesture` | 第 1 指的累计位移 + 落点 | **手指数量** |
/// | `MagnifyGesture` | 两指间距比 | 质心平移 |
/// | `RotateGesture` | 旋转角 | 与需求无关 |
/// | `SpatialEventGesture` | 多指事件流 | **iOS 18+**，本工程 target 17.0 |
///
/// 而触摸板要"单指移光标、双指滚画面"，唯一的依据就是手指数量 ——
/// 所以这一层必须落到 UIKit。
///
/// ## 为什么用 `touchesBegan/Moved/Ended` 而不是手势识别器
/// 手势识别器是"多个识别器互相竞争"的模型，要表达"按指数分流"就得让它们
/// 互相依赖或互相失败，比直接读触摸更绕。而且 `UIPanGestureRecognizer` 只在
/// 自己认可之后才开始上报，起手那段位移会被它吞掉 —— 而这段位移在
/// `PadGesture` 里是要参与 slop 判定的。
///
/// 直接读触摸，`PadGesture` 拿到的是完整序列。
///
/// ## `isMultipleTouchEnabled` 是这块视图的全部意义
/// 默认是 `false`，此时 UIKit 只投递**第一根**手指 —— 症状与 SwiftUI 的
/// `DragGesture` 一模一样，而且不会报任何错。少了这一行，本文件就白写。
struct TouchSurface: UIViewRepresentable {

    let onEvent: (TouchSurfaceEvent) -> Void

    func makeUIView(context: Context) -> TouchCaptureView {
        let view = TouchCaptureView()
        view.onEvent = onEvent
        return view
    }

    func updateUIView(_ uiView: TouchCaptureView, context: Context) {
        uiView.onEvent = onEvent
    }
}

/// 透明的触摸采集视图。
final class TouchCaptureView: UIView {

    var onEvent: ((TouchSurfaceEvent) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        report(event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        report(event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(event, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(event, cancelled: true)
    }

    // MARK: - 上报

    private func report(_ event: UIEvent?) {
        let live = liveTouches(event)
        guard !live.isEmpty else { return }
        onEvent?(.sample(sampling(live)))
    }

    /// 抬手 / 取消。
    ///
    /// **只在一根手指都不剩时才终结会话**：两指下滑的过程中先抬一根是常态，
    /// 那一帧必须原样报出去（指数 2 → 1），不然状态机就看不到指数变化，
    /// 质心那一跳会被算成一次位移。
    private func finish(_ event: UIEvent?, cancelled: Bool) {
        let live = liveTouches(event)
        guard live.isEmpty else {
            onEvent?(.sample(sampling(live)))
            return
        }

        let terminal: TouchSurfaceEvent = cancelled ? .cancelled : .ended(Date())
        onEvent?(terminal)
    }

    /// 此刻仍然按在屏上的手指。
    ///
    /// 用 `event.allTouches` 而不是回调参数里的那个集合：参数只带**本次变化**的手指，
    /// 而状态机需要的是"现在一共几根"。第二根手指落下时，参数里只有它自己，
    /// `allTouches` 才有两根。
    private func liveTouches(_ event: UIEvent?) -> [UITouch] {
        (event?.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
    }

    private func sampling(_ touches: [UITouch]) -> TouchSampling {
        TouchSampling(points: touches.map { $0.location(in: self) }, time: Date())
    }
}
