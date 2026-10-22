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
/// 而不是等宿主传进来。
///
/// ## 为什么这里一个手势都没有
/// 外接屏的 role 是 `windowExternalDisplayNonInteractive` —— 系统不会向它投递
/// 任何触摸事件（真机上 `window.isUserInteractionEnabled = false`，模拟器 mock 里
/// `PassthroughWindow.hitTest` 恒返回 `nil`），SwiftUI 的 accessory 更是在 API 层面
/// 就叫 `ExternalNonInteractiveAccessory`。
///
/// 所以这个视图是**纯输出**的：它只读 `RemoteControl` 与 `DemoFlow` 的共享状态，
/// 滚动 / 缩放 / 光标由手机端的手势面写入，按钮的"点击"也由手机端判定 ——
/// 这一屏只负责把光标悬停到的按钮画成高亮。
///
/// ## 三个页面
/// ```
/// launcher  按钮页：图案画布当背景，按钮浮在正中，光标悬停即高亮
/// capture   录制中：ReplayKit 的实时画面，左上角录制标记、右上角计时
/// playback  回放：录制出来的 mp4 循环播放
/// ```
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
    private let flow = DemoFlow.shared

    /// 轻点反馈的涟漪。
    @State private var rippleScale: CGFloat = 0.35
    @State private var rippleOpacity: Double = 0
    @State private var isPulseOn = false

    /// 内容总高 / 视口高。滚动行程由它决定 —— 取 1.6 表示滚到底时
    /// 内容正好上移 0.6 个视口高，画布底部与视口底部对齐、不露黑边。
    private static let contentHeightRatio: CGFloat = 1.6

    var body: some View {
        GeometryReader { geometry in
            let viewport = geometry.size

            ZStack(alignment: .topLeading) {
                switch flow.phase {
                case .launcher:
                    launcherLayer(viewport)
                case .capture:
                    captureLayer(viewport)
                case .playback:
                    playbackLayer(viewport)
                }

                if flow.phase == .launcher {
                    cursor(viewport)
                    ripple(viewport)
                }
            }
            // 内容容器刻意比视口高（它要能滚动），于是 ZStack 的尺寸会被撑到内容总高 ——
            // 而 `.frame` 默认是**居中**对齐，一旦 ZStack 比 frame 大，它就会被往上
            // 顶掉半个差值，画面看起来"莫名其妙从半截开始"。必须显式写 `.topLeading`。
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .clipped()
            .onAppear { reportMetrics(viewport) }
            .onChange(of: geometry.size) { _, size in reportMetrics(size) }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onChange(of: remote.tapCount) { _, _ in playTapFeedback() }
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

    // MARK: - 按钮页

    private func launcherLayer(_ viewport: CGSize) -> some View {
        let metrics = ScrollMetrics(
            viewport: viewport,
            contentHeight: viewport.height * Self.contentHeightRatio,
            inset: 0
        )

        return ZStack(alignment: .topLeading) {
            content(viewport: viewport, metrics: metrics)
            Color.black.opacity(0.5)
            topScrim(viewport)
            bottomScrim(viewport)

            GlassesLauncherCard(
                viewport: viewport,
                isHighlighted: GlassesLauncherLayout.standard.hitTest(remote.pointer),
                statusText: flow.statusText,
                errorText: flow.errorText
            )

            hud(viewport)
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }

    // MARK: - 录制中

    private func captureLayer(_ viewport: CGSize) -> some View {
        let base = min(viewport.width, viewport.height)

        return ZStack(alignment: .topLeading) {
            Color.black

            preview(viewport)

            HStack(spacing: base * 0.02) {
                Circle()
                    .fill(flow.isCapturing ? Color.red : Color.orange)
                    .frame(width: base * 0.026, height: base * 0.026)
                    .opacity(isPulseOn ? 0.3 : 1)

                Text(captureTitle)
                    .font(.system(size: base * 0.034, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer(minLength: base * 0.04)

                TimelineView(.periodic(from: flow.captureStartedAt ?? .now, by: 0.2)) { _ in
                    Text(flow.isCapturing ? elapsedText : "00:00.0")
                        .font(.system(size: base * 0.05, weight: .thin, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(flow.isCapturing ? Color.white : Color.white.opacity(0.35))
                }
            }
            .padding(.horizontal, base * 0.05)
            .padding(.top, base * 0.045)
            .frame(width: viewport.width, alignment: .topLeading)
            .shadow(color: .black.opacity(0.85), radius: base * 0.02)

            Text("实时画面 · \(flow.statusText) · 长按手机屏幕可中止")
                .font(.system(size: base * 0.026, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
                .padding(base * 0.045)
                .frame(width: viewport.width, height: viewport.height, alignment: .bottomLeading)
                .shadow(color: .black.opacity(0.85), radius: base * 0.02)
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                isPulseOn = true
            }
        }
        // 呼吸动画靠 false→true 这一次状态变化启动。第二次录制时 `isPulseOn` 还是
        // true，`onAppear` 再置一次同值不会触发动画，录制点会僵在 0.3 透明度上。
        .onDisappear { isPulseOn = false }
    }

    private var captureTitle: String {
        guard flow.isCapturing else { return "准备录制" }
        return flow.isSimulatedCapture ? "模拟录制" : "正在录制"
    }

    private var playbackCaption: String {
        guard flow.recordedDuration > 0 else { return "录制结果 · 循环回放" }
        return "录制结果 · \(DemoFlow.secondsText(flow.recordedDuration)) · 循环回放"
    }

    private var elapsedText: String {
        let seconds = max(0, Date().timeIntervalSince(flow.captureStartedAt ?? Date()))
        return String(format: "%02d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    /// 录制中的实时画面：采样按原样送来，按比例装进这块屏，多余的地方留黑边。
    private func preview(_ viewport: CGSize) -> some View {
        LivePreviewView()
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }

    // MARK: - 回放
    private func playbackLayer(_ viewport: CGSize) -> some View {
        let base = min(viewport.width, viewport.height)

        return ZStack(alignment: .bottomLeading) {
            Color.black

            if let url = flow.recordedURL {
                RecordedVideoView(url: url)
                    .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            }

            Text(playbackCaption)
                .font(.system(size: base * 0.028, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .padding(base * 0.045)
                .shadow(color: .black.opacity(0.8), radius: base * 0.02)
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }

    // MARK: - 内容

    /// 一块比视口高的图案画布，随纵向三段位移。
    ///
    /// 位移取自 `ScrollMetrics`（滚动 / 下拉 / 上拉），它是纯几何，手机端只送归一化进度。
    private func content(viewport: CGSize, metrics: ScrollMetrics) -> some View {
        let height = viewport.height * Self.contentHeightRatio

        return DisplayPatternCanvas(pattern: store.pattern, isAnimated: store.isAnimated)
            .scaleEffect(remote.zoom)
            .animation(.easeOut(duration: 0.15), value: remote.zoom)
            .frame(width: viewport.width, height: height)
            .clipped()
            .offset(y: metrics.contentOffset(
                scroll: remote.scroll,
                pull: remote.pull,
                bottomPull: remote.bottomPull
            ))
    }

    /// 顶部压暗。标题是固定层，画布从它下面滑过 —— 没有这层暗角，
    /// 浅色图案经过时标题会读不出来。
    private func topScrim(_ viewport: CGSize) -> some View {
        LinearGradient(
            colors: [.black.opacity(0.78), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: viewport.width, height: viewport.height * 0.34)
        .allowsHitTesting(false)
    }

    private func bottomScrim(_ viewport: CGSize) -> some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.85)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: viewport.width, height: viewport.height * 0.4)
        .frame(width: viewport.width, height: viewport.height, alignment: .bottom)
        .allowsHitTesting(false)
    }

    // MARK: - 固定 HUD

    private func hud(_ viewport: CGSize) -> some View {
        let base = min(viewport.width, viewport.height)
        return VStack(alignment: .trailing, spacing: base * 0.012) {
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                Text(timeline.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: base * 0.075, weight: .thin, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
            }

            Text(readout(for: viewport))
                .font(.system(size: base * 0.03, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(base * 0.05)
        .frame(width: viewport.width, height: viewport.height, alignment: .bottomTrailing)
        .shadow(color: .black.opacity(0.6), radius: base * 0.02)
        .allowsHitTesting(false)
    }

    private func readout(for viewport: CGSize) -> String {
        var parts = [
            resolutionText(for: viewport),
            "滚动 \(Int(remote.scroll * 100))%"
        ]
        if remote.zoom > 1.001 {
            parts.append("缩放 \(String(format: "%.2f", remote.zoom))×")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 光标与轻点反馈

    /// 橙色光标环。落点由手机端手势面写入，归一化 `0...1`。
    @ViewBuilder
    private func cursor(_ viewport: CGSize) -> some View {
        if let pointer = remote.pointer {
            let base = min(viewport.width, viewport.height)
            let diameter = base * 0.1

            ZStack {
                Circle().fill(Color.orange.opacity(0.22))
                Circle().stroke(Color.orange, lineWidth: max(1.5, base * 0.007))
                Circle()
                    .fill(Color.orange)
                    .frame(width: diameter * 0.18, height: diameter * 0.18)
            }
            .frame(width: diameter, height: diameter)
            .position(x: pointer.x * viewport.width, y: pointer.y * viewport.height)
            .shadow(color: .black.opacity(0.6), radius: base * 0.015)
            .allowsHitTesting(false)
        }
    }

    private func ripple(_ viewport: CGSize) -> some View {
        let base = min(viewport.width, viewport.height)
        let center = remote.pointer.map {
            CGPoint(x: $0.x * viewport.width, y: $0.y * viewport.height)
        } ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)

        return Circle()
            .stroke(Color.orange, lineWidth: max(2, base * 0.01))
            .frame(width: base * 0.22, height: base * 0.22)
            .scaleEffect(rippleScale)
            .opacity(rippleOpacity)
            .position(center)
            .allowsHitTesting(false)
    }

    private func playTapFeedback() {
        rippleScale = 0.35
        rippleOpacity = 0.9
        withAnimation(.easeOut(duration: 0.55)) {
            rippleScale = 2.0
            rippleOpacity = 0
        }
    }
}

#Preview {
    ExternalDisplayRootView()
}
