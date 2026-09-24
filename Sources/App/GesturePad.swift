import Foundation
import SwiftUI

/// 采集面静止时显示的一行提示。
struct GesturePadHint {

    let text: String

    /// 次要提示。操作难度高、或只在模拟器里好做的那些用更暗的颜色 ——
    /// 提示区的主次必须一眼分得开，否则三行字会互相抢注意力。
    var isSecondary = false
}

/// 一块**手势采集面** —— 手机端所有「手势 → 外接屏」的输入都从这里进。
///
/// 两个宿主做的事几乎一样，只差在"多少根手指算滚动"：
/// - 触控板（`RemoteControlPad`）：主控面，手指落点同时当作外接屏上的光标，
///   单指只移光标、**双指**才滚画面（`.twoFinger`）；
/// - 空鼠栏（`AirMousePad`）：空鼠开着时的补充面，落点**不**映射光标，
///   单指就能滚（`.oneFinger`）。
///
/// 做成一个视图而不是复制两份，是为了让两处的判定逻辑**必然**一致：
/// 复制的话，迟早有一处被改了阻尼或分母而另一处没跟上。
///
/// ## 触摸从哪来
/// 由 `TouchSurface`（UIKit）采集，再交给 `PadGesture` 这个纯状态机。
/// 换掉 SwiftUI 的 `DragGesture` 是因为它**读不到手指数量**，
/// 而"单指移光标 / 双指滚画面"唯一的分辨依据就是它。详见 `TouchSurface`。
///
/// ## 一个状态机同时管两件事
///
/// ```
/// 按下 ──┬─ 位移没越过 slop 就抬起 ──▶ 轻点：点击确认
///        └─ 位移越过 slop ──────────▶ 拖动：开始滚动
/// ```
///
/// 两者共用一个状态机，靠**位移阈值**（`slop`）区分。
/// 判定逻辑全部在 `PadGesture` 里 —— 本视图只负责
/// 「把触摸转发进去、把动作转发给 `RemoteControl`」。
/// 抽出去的理由见 `PadGesture` 的类型文档：`simctl` 没有触摸注入 API，
/// 留在视图里的话这段逻辑就完全无法自动验证。
///
/// ## 为什么空鼠栏也需要"点击确认"
/// 空鼠的交互是「抬手瞄准 + 确认」，而确认原本只有一个「扳机」按钮。
/// 但空鼠工作时手机是被举起来的，手指去够底部那个按钮既别扭、又会带歪姿态 ——
/// 瞄准的那只手没法稳定地去点一个具体控件。所以确认必须能落在**手边的任意位置**：
/// 整块面板都是轻点目标。
///
/// ## 两条输出轴
/// 越过 slop 的那一帧由 `PadGesture` 锁定一条**主轴**（`|dx|` 与 `|dy|` 谁大听谁的），
/// 本次会话余下的帧只在这一条轴上出动作：
///
/// - 纵轴 → 滚动 / 顶部下拉 / 底部上拉；
/// - 横轴 → 幕墙横向推开（露出左或右侧星海）。
///
/// 锁定而不是"两条轴同时生效"，是为了保住原有的手感：改动之前横向是
/// "刻意忽略但不拦截"的，等价于**隐式锁了纵轴** —— 斜着拖照样能滚。
/// 显式锁定把这条手感完整保留，同时让横向从"被丢弃"变成"真的推得动"。
///
/// 平手判给纵轴，于是老用例的归属一字不变。
struct GesturePad: View {

    /// 静止时显示的提示行。
    let hints: [GesturePadHint]

    /// 采集面高度。
    var height: CGFloat = 168

    /// 是否把手指落点同时映射为外接屏光标。
    ///
    /// 触控板要（它就是靠落点控制光标的），空鼠不要 ——
    /// 那一栏的光标归陀螺仪管，手指再插一脚会让激光乱跳。
    var mapsPointer: Bool = true

    /// 多少根手指算滚动。触控板给 `.twoFinger`，空鼠栏给 `.oneFinger`。
    var scrollGesture: PadGesture.ScrollGesture = .oneFinger

    /// 是否允许滚动。触控板上捏合进行中由调用方置 `false`，
    /// 否则一次捏合会顺带把画面滑走。
    var isScrollEnabled: Bool = true

    /// 外部正在进行的手势（触控板上的捏合）。为 `true` 时同样收起提示文案。
    var isBusy: Bool = false

    /// 轻点回调。为 `nil` 时这一块只支持滚动。
    var onTap: (() -> Void)?

    private let remote = RemoteControl.shared

    @State private var gesture = PadGesture()

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))

                if !gesture.isDragging && !isBusy {
                    hintStack(size: size)
                }

                RemoteScrollIndicator(
                    progress: remote.scroll,
                    pull: remote.pull,
                    bottom: remote.bottomPull,
                    size: size
                )

                if mapsPointer, let pointer = remote.pointer {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 20, height: 20)
                        .position(x: pointer.x * size.width, y: pointer.y * size.height)
                        .allowsHitTesting(false)
                }

                // 放在最上层：触摸归它，下面那些只负责显示。
                // 透明的 UIKit 视图照样能命中 —— 命中判定不看 `backgroundColor`。
                TouchSurface { event in
                    handle(event, size: size)
                }
                .frame(width: size.width, height: size.height)
            }
        }
        .frame(height: height)
    }

    private func hintStack(size: CGSize) -> some View {
        VStack(spacing: 4) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                Text(hint.text)
                    .foregroundStyle(hint.isSecondary ? Color.secondary.opacity(0.6) : Color.secondary)
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .frame(width: size.width, height: size.height)
    }

    // MARK: - 触摸

    private func handle(_ event: TouchSurfaceEvent, size: CGSize) {
        switch event {
        case .sample(let sampling):
            perform(gesture.touched(
                sampling.points,
                time: sampling.time,
                padSize: size,
                mapsPointer: mapsPointer,
                scrollGesture: scrollGesture,
                isScrollEnabled: isScrollEnabled
            ))

        case .ended(let time):
            perform(gesture.ended(time: time))

        case .cancelled:
            gesture.cancelled()
        }
    }

    /// 把状态机吐出的动作转发给共享状态。
    private func perform(_ actions: [PadGesture.Action]) {
        for action in actions {
            switch action {
            case .pointer(let point):
                remote.movePointer(to: point)
            case .scroll(let dy):
                remote.scroll(by: dy)
            case .lateral(let dx):
                remote.lateral(by: dx)
            case .tap:
                onTap?()
            }
        }
    }
}

/// 采集面右侧的滚动 / 过卷指示条。
///
/// - **橙色块**：滚动位置，从上往下走，与外接屏上的内容进度一一对应；
/// - **青色条**：过卷量。下拉时从顶端往下画、上拉时从底端往上画 ——
///   外接屏上露出的星海在哪一侧，条就画在哪一侧。
///
/// 三者同框对照，手指往哪边拽、外接屏发生什么，一眼能对上。
///
/// 横推量不在这里画：它是一条**竖**向的量，塞进这条竖条里只能靠颜色再区分一次，
/// 而右上角的读数栏本来就有数字。加一个方向标记的收益不值那一份歧义。
struct RemoteScrollIndicator: View {

    let progress: CGFloat
    let pull: CGFloat
    let bottom: CGFloat
    let size: CGSize

    var body: some View {
        let trackWidth: CGFloat = 4
        let knobHeight: CGFloat = 30
        let travel = max(0, size.height - knobHeight - 16)
        let x = size.width - trackWidth - 10
        let maxOverScroll = size.height * 0.5

        return ZStack(alignment: .topLeading) {
            if pull > 0 {
                Capsule()
                    .fill(Color.cyan.opacity(0.85))
                    .frame(width: trackWidth, height: max(6, maxOverScroll * pull))
                    .offset(x: x, y: 8)
            }

            if bottom > 0 {
                Capsule()
                    .fill(Color.cyan.opacity(0.85))
                    .frame(width: trackWidth, height: max(6, maxOverScroll * bottom))
                    .offset(x: x, y: size.height - 8 - max(6, maxOverScroll * bottom))
            }

            Capsule()
                .fill(Color.orange.opacity(0.75))
                .frame(width: trackWidth, height: knobHeight)
                .offset(x: x, y: 8 + travel * progress)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

#Preview {
    VStack(spacing: 16) {
        GesturePad(
            hints: [
                GesturePadHint(text: "单指移动 → 移动光标"),
                GesturePadHint(text: "双指滑动 → 滚动外接屏"),
                GesturePadHint(text: "轻点 → 点击确认"),
                GesturePadHint(text: "双指捏合 → 缩放（模拟器按住 Option）", isSecondary: true)
            ],
            scrollGesture: .twoFinger
        )
        GesturePad(
            hints: [
                GesturePadHint(text: "轻点面板 → 点击确认（等同扳机）"),
                GesturePadHint(text: "单指上下拖动 → 滚动外接屏"),
                GesturePadHint(text: "抬手转动手机 → 移动激光", isSecondary: true)
            ],
            height: 120,
            mapsPointer: false,
            scrollGesture: .oneFinger
        )
    }
    .padding()
}
