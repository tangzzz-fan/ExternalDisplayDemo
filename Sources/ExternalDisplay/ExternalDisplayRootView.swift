import Foundation
import SwiftUI

/// 外接屏上渲染的根视图。
///
/// 它有三个宿主，内容完全相同：
/// - **iOS 17~26**：`ExternalDisplaySceneDelegate` 经 `UIHostingController` 挂到外接屏的 `UIWindow`；
/// - **iOS 27+**：`ExternalNonInteractiveAccessory`（见 `ExternalDisplayAccessory`），由系统呈现；
/// - **无硬件时**：`MockExternalDisplay` 在手机屏上叠的替身窗口。
///
/// 所以它不依赖任何宿主专有的东西 —— **分辨率也由它自己量出来**（视口点数 × 屏幕 scale），
/// 而不是等宿主传进来。这样上面三条路一份代码，且不需要 UIKit 的 `UIScreen` / `windowScene`。
///
/// ## 为什么这里一个手势都没有
/// 外接屏的 role 是 `windowExternalDisplayNonInteractive` —— 系统不会向它投递
/// 任何触摸事件（真机上 `window.isUserInteractionEnabled = false`，模拟器 mock 里
/// `PassthroughWindow.hitTest` 恒返回 `nil`），SwiftUI 的 accessory 更是在 API 层面
/// 就叫 `ExternalNonInteractiveAccessory`。
///
/// 所以这个视图是**纯输出**的：它只读 `RemoteControl` 的共享状态，
/// 滚动 / 缩放 / 光标全部由手机端的遥控板写入。在这里加 `ScrollView`
/// 或 `.gesture` 是无效的 —— 手势根本到不了这棵视图树。
///
/// 排版全部按画面短边等比缩放，因此同一份代码在 1080p 真外接屏、
/// 4K 外接屏、以及模拟器的 letterbox 小窗口里都不会溢出或截断。
struct ExternalDisplayRootView: View {

    /// 内容量出自己的**像素**尺寸后回调。
    ///
    /// 只有 iOS 27 的 accessory 路径需要它 —— 那条路没有 scene delegate，
    /// 也就没有 `UIWindowScene` 可查，手机端的连接状态只能由这里上报。
    /// 另外两条路的宿主自己就能拿到更准的 nativeBounds，都传 `nil`。
    var onMetricsChange: ((_ pixelSize: CGSize, _ nativeScale: CGFloat) -> Void)?

    /// 外接屏自己的缩放比：accessory 内容读到的就是这个 window 所在屏幕的值。
    @Environment(\.displayScale) private var displayScale

    private let store = DisplayContentStore.shared
    private let remote = RemoteControl.shared
    private let airMouse = AirMouse.shared

    /// 轻点反馈的涟漪。
    @State private var rippleScale: CGFloat = 0.35
    @State private var rippleOpacity: Double = 0

    /// 激光拖尾：最近若干个归一化落点，越靠后越淡越小。
    ///
    /// 拖尾必须存在视图侧而不是 `RemoteControl` 里 —— 它是纯渲染状态，
    /// 让共享模型为了画一条尾巴而保存历史位置，是把表现层的事漏进了状态层。
    @State private var laserTrail: [CGPoint] = []
    /// 扳机触发时的瞄准环回弹。
    @State private var reticleScale: CGFloat = 1

    /// 拖尾保留的采样点数。空鼠 60 Hz，10 个点约 0.17 s，视觉上刚好"有余晖"。
    private static let laserTrailLength = 10

    /// 可滚动内容的行数，决定滚动距离。
    private let rowCount = 14

    var body: some View {
        GeometryReader { geometry in
            let metrics = ScrollMetrics(
                base: min(geometry.size.width, geometry.size.height),
                viewport: geometry.size,
                rowCount: rowCount
            )

            ZStack(alignment: .topLeading) {
                Color.black

                DisplayPatternCanvas(pattern: store.pattern, isAnimated: store.isAnimated)
                    .scaleEffect(remote.zoom)
                    .animation(.easeOut(duration: 0.15), value: remote.zoom)

                scrollColumn(metrics: metrics)

                hud(metrics: metrics)

                pointer(metrics: metrics)

                ripple(metrics: metrics)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .onAppear { reportMetrics(geometry.size) }
            .onChange(of: geometry.size) { _, size in reportMetrics(size) }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onChange(of: remote.tapCount) { _, _ in playTapFeedback() }
        .onChange(of: remote.pointerSource) { _, _ in laserTrail.removeAll() }
        .onChange(of: remote.pointer) { _, point in appendToLaserTrail(point) }
    }

    // MARK: - 自测量

    /// 视口点数 × 屏幕 scale 即为像素尺寸。
    ///
    /// 不使用 `UIScreen`：`UIScreen.screens` / `didConnectNotification` 在 iOS 16 已废弃，
    /// `UIScreen.main` 在 iOS 26 已废弃，而 SwiftUI 的 accessory 内容本来也拿不到 `windowScene`。
    private func pixelSize(for viewport: CGSize) -> CGSize {
        CGSize(
            width: (viewport.width * displayScale).rounded(),
            height: (viewport.height * displayScale).rounded()
        )
    }

    private func resolutionText(for viewport: CGSize) -> String {
        let size = pixelSize(for: viewport)
        return "\(Int(size.width)) × \(Int(size.height)) px"
    }

    private func reportMetrics(_ viewport: CGSize) {
        guard let onMetricsChange, viewport.width > 0, viewport.height > 0 else { return }
        onMetricsChange(pixelSize(for: viewport), displayScale)
    }

    // MARK: - 可滚动内容

    private func scrollColumn(metrics: ScrollMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            header(metrics: metrics)

            ForEach(1...metrics.rowCount, id: \.self) { index in
                row(index: index, metrics: metrics)
            }
        }
        .padding(metrics.inset)
        .offset(y: -metrics.offset(for: remote.scroll))
        .shadow(color: .black.opacity(0.55), radius: metrics.base * 0.02, y: metrics.base * 0.003)
        // 内容高度远超视口，`.frame` 必须显式指定 topLeading —— 默认是居中，
        // 会让画面在滚动起点就偏移半屏。`.clipped()` 负责把溢出的部分切掉。
        .frame(
            width: metrics.viewport.width,
            height: metrics.viewport.height,
            alignment: .topLeading
        )
        .clipped()
    }

    private func header(metrics: ScrollMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.base * 0.02) {
            Text(store.caption)
                .font(.system(size: metrics.base * 0.075, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text(resolutionText(for: metrics.viewport))
                .font(.system(size: metrics.base * 0.038, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(width: metrics.contentWidth, height: metrics.headerHeight, alignment: .leading)
    }

    private func row(index: Int, metrics: ScrollMetrics) -> some View {
        HStack(spacing: metrics.base * 0.03) {
            Text(String(format: "%02d", index))
                .font(.system(size: metrics.base * 0.045, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: metrics.base * 0.1, alignment: .leading)

            Text("内容条目 \(index)")
                .font(.system(size: metrics.base * 0.05, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Spacer(minLength: 0)

            Rectangle()
                .fill(.white.opacity(0.16))
                .frame(width: metrics.base * 0.12, height: 1)
        }
        .padding(.horizontal, metrics.base * 0.03)
        .frame(width: metrics.contentWidth, height: metrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: metrics.base * 0.015, style: .continuous)
                .fill(.white.opacity(index.isMultiple(of: 2) ? 0.06 : 0.02))
        )
    }

    // MARK: - 固定 HUD

    private func hud(metrics: ScrollMetrics) -> some View {
        VStack(alignment: .trailing, spacing: metrics.base * 0.012) {
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                Text(timeline.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: metrics.base * 0.1, weight: .thin, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }

            Text("滚动 \(Int(remote.scroll * 100))% · 缩放 \(String(format: "%.2f", remote.zoom))×")
                .font(.system(size: metrics.base * 0.032, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))

            if let text = airMouseHudText {
                Text(text)
                    .font(.system(size: metrics.base * 0.032, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(LaserPalette.core.opacity(0.85))
            }
        }
        .padding(metrics.base * 0.06)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .shadow(color: .black.opacity(0.6), radius: metrics.base * 0.02)
    }

    // MARK: - 光标与轻点反馈

    /// 光标渲染按归属分派：触控板画环形光标，空鼠画激光。
    ///
    /// 两者共用 `RemoteControl.pointer` 这一个落点，只是外观不同 ——
    /// 这样"谁在动"就完全由 `pointerSource` 决定，不需要两套坐标互相同步。
    @ViewBuilder
    private func pointer(metrics: ScrollMetrics) -> some View {
        if let pointer = remote.pointer {
            switch remote.pointerSource {
            case .touch:
                touchCursor(at: pointer, metrics: metrics)
            case .airMouse:
                laserCursor(at: pointer, metrics: metrics)
            }
        }
    }

    // MARK: 触控板光标

    private func touchCursor(at pointer: CGPoint, metrics: ScrollMetrics) -> some View {
        let diameter = metrics.base * 0.1
        return ZStack {
            Circle().fill(LaserPalette.touch.opacity(0.22))
            Circle().stroke(LaserPalette.touch, lineWidth: max(1.5, metrics.base * 0.007))
            Circle()
                .fill(LaserPalette.touch)
                .frame(width: diameter * 0.18, height: diameter * 0.18)
        }
        .frame(width: diameter, height: diameter)
        .position(point(pointer, in: metrics))
        .shadow(color: .black.opacity(0.6), radius: metrics.base * 0.015)
    }

    // MARK: 激光光标

    /// 激光指针：拖尾 + 光晕 + 白芯光斑 + 瞄准环。
    ///
    /// 后三层各自独立 `.position`，都落在与外层 `ZStack` 同一坐标系里。
    /// **不要**把它们再套一层 ZStack 后整体 position —— 内层已经用绝对坐标定位，
    /// 再套一层会二次偏移。拖尾是铺满视口的 `Canvas`，自己按归一化坐标换算，
    /// 同样不参与这条 `.position` 约定。
    @ViewBuilder
    private func laserCursor(at pointer: CGPoint, metrics: ScrollMetrics) -> some View {
        let unit = metrics.base * 0.1
        let center = point(pointer, in: metrics)

        // 1. 拖尾
        laserTrailCanvas(metrics: metrics)

        // 2. 光晕
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        LaserPalette.core.opacity(0.7),
                        LaserPalette.glow.opacity(0.2),
                        LaserPalette.core.opacity(0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: unit * 0.95
                )
            )
            .frame(width: unit * 1.9, height: unit * 1.9)
            .position(center)

        // 3. 光斑本体：红边包白芯，白芯是"过曝"的部分
        Circle()
            .fill(LaserPalette.core)
            .frame(width: unit * 0.4, height: unit * 0.4)
            .overlay {
                Circle()
                    .fill(.white)
                    .frame(width: unit * 0.16, height: unit * 0.16)
            }
            .shadow(color: LaserPalette.core.opacity(0.9), radius: unit * 0.22)
            .position(center)

        // 4. 瞄准环 + 四向刻度
        reticle(unit: unit)
            .position(center)
    }

    /// 拖尾：一条渐细渐淡的折线，从尾到头收敛到当前光斑。
    ///
    /// 用**单张 `Canvas` 一次描完**，而不是给每个采样点各挂一个带 `.blur` 的
    /// `Circle`。拖尾随光标每帧重算，而空鼠是 60 Hz；10 个模糊图层意味着外接屏
    /// 每个采样周期都要重新合成 10 次离屏模糊 —— 在 4K 外接屏上是实打实的掉帧源。
    /// 描边一次就没有这层开销，且省掉了每段的布局抖动。
    private func laserTrailCanvas(metrics: ScrollMetrics) -> some View {
        let unit = metrics.base * 0.1
        let points = laserTrail.map { point($0, in: metrics) }

        return Canvas { context, _ in
            guard points.count >= 2 else { return }

            for index in 1..<points.count {
                // 0（最早）→ 1（最新）
                let progress = CGFloat(index) / CGFloat(points.count - 1)

                var path = Path()
                path.move(to: points[index - 1])
                path.addLine(to: points[index])

                context.stroke(
                    path,
                    with: .color(LaserPalette.core.opacity(Double(progress * progress) * 0.55)),
                    style: StrokeStyle(
                        lineWidth: unit * 0.24 * progress,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        .frame(width: metrics.viewport.width, height: metrics.viewport.height)
        .allowsHitTesting(false)
    }

    private func reticle(unit: CGFloat) -> some View {
        let diameter = unit * 0.95
        return ZStack {
            Circle()
                .stroke(LaserPalette.core.opacity(0.6), lineWidth: max(1, unit * 0.02))

            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(LaserPalette.core.opacity(0.8))
                    .frame(width: max(1, unit * 0.016), height: unit * 0.14)
                    // 先位移再旋转：offset 不改变布局框，rotationEffect 仍绕
                    // ZStack 中心转，于是四根刻度均匀落在环外。
                    .offset(y: -(diameter / 2 + unit * 0.1))
                    .rotationEffect(.degrees(Double(index) * 90))
            }
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(reticleScale)
        .shadow(color: LaserPalette.core.opacity(0.5), radius: unit * 0.08)
    }

    // MARK: 涟漪

    private func ripple(metrics: ScrollMetrics) -> some View {
        let center = remote.pointer.map { point($0, in: metrics) }
            ?? CGPoint(x: metrics.viewport.width / 2, y: metrics.viewport.height / 2)
        let color = remote.pointerSource == .airMouse ? LaserPalette.core : LaserPalette.touch

        return Circle()
            .stroke(color, lineWidth: max(2, metrics.base * 0.01))
            .frame(width: metrics.base * 0.22, height: metrics.base * 0.22)
            .scaleEffect(rippleScale)
            .opacity(rippleOpacity)
            .position(center)
            .allowsHitTesting(false)
    }

    // MARK: 反馈与拖尾

    private func playTapFeedback() {
        rippleScale = 0.35
        rippleOpacity = 0.9
        withAnimation(.easeOut(duration: 0.55)) {
            rippleScale = 2.0
            rippleOpacity = 0
        }
        // 瞄准环先弹开再收回，给扳机一个"咔哒"的视觉对应
        withAnimation(.spring(response: 0.26, dampingFraction: 0.42)) {
            reticleScale = 1.45
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.6).delay(0.08)) {
            reticleScale = 1
        }
    }

    /// 拖尾只在空鼠驱动光标时累积；切回触控板立刻清空。
    private func appendToLaserTrail(_ normalized: CGPoint?) {
        guard remote.pointerSource == .airMouse, let normalized else {
            if !laserTrail.isEmpty { laserTrail.removeAll() }
            return
        }
        laserTrail.append(normalized)
        if laserTrail.count > Self.laserTrailLength {
            laserTrail.removeFirst()
        }
    }

    // MARK: - 几何与文案

    private func point(_ normalized: CGPoint, in metrics: ScrollMetrics) -> CGPoint {
        CGPoint(
            x: normalized.x * metrics.viewport.width,
            y: normalized.y * metrics.viewport.height
        )
    }

    /// 空鼠状态行。未启动时不占地方，故障状态则必须显示 ——
    /// 否则眼镜屏上什么都看不到，手机端又不在眼前，用户无从判断。
    private var airMouseHudText: String? {
        switch airMouse.state {
        case .idle, .stopped:
            return nil
        case .warming:
            return "空鼠预热中…"
        case .tracking:
            if airMouse.warmup.isSynthetic { return "空鼠 模拟源" }
            guard let usable = airMouse.warmup.milestones.usable else { return "空鼠 就绪" }
            return String(format: "空鼠 可用 %.2fs", usable)
        case .noSamples:
            return "空鼠 无数据"
        case .unavailable:
            return "空鼠 不可用"
        }
    }
}

/// 光标配色。触控板沿用原来的橙色，空鼠用红色激光系。
private enum LaserPalette {
    static let core = Color(red: 1.0, green: 0.21, blue: 0.25)
    static let glow = Color(red: 1.0, green: 0.45, blue: 0.28)
    static let touch = Color.orange
}

/// 外接屏内容的滚动几何。
///
/// 手机端只传归一化进度，实际位移在这里按画面尺寸换算 —— 这样同一份
/// 手机端状态在 1080p / 4K / 模拟器 letterbox 小窗口上都成立。
private struct ScrollMetrics {

    let base: CGFloat
    let viewport: CGSize
    let rowCount: Int

    var inset: CGFloat { base * 0.08 }
    var headerHeight: CGFloat { base * 0.26 }
    var rowHeight: CGFloat { base * 0.115 }
    var rowSpacing: CGFloat { base * 0.012 }
    var contentWidth: CGFloat { viewport.width - inset * 2 }

    /// 标题 + 所有行的高度（不含内边距）。
    var contentHeight: CGFloat {
        headerHeight + CGFloat(rowCount) * (rowHeight + rowSpacing)
    }

    /// 含四周内边距的完整高度，即需要滚动的总长度。
    var totalHeight: CGFloat { contentHeight + inset * 2 }

    /// 滚到底时内容需要上移的距离。
    var maxOffset: CGFloat { max(0, totalHeight - viewport.height) }

    func offset(for scroll: CGFloat) -> CGFloat {
        maxOffset * min(max(scroll, 0), 1)
    }
}

#Preview {
    ExternalDisplayRootView()
}
