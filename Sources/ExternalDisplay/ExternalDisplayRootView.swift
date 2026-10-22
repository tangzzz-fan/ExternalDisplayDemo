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
/// 所以这个视图是**纯输出**的：它只读 `RemoteControl` 的共享状态，
/// 滚动 / 下拉 / 缩放 / 光标全部由手机端的手势面写入。在这里加 `ScrollView`
/// 或 `.gesture` 是无效的 —— 手势根本到不了这棵视图树。
///
/// ## 层次
/// ```
/// backdrop                 纯黑 + 一行很暗的字，下拉时露出的就是它
/// └ content                图案画布，1.6 倍视口高，随 scroll / pull 位移
///   └ caption              标题与分辨率，贴在画布顶上，随内容滚走
/// hud                      固定，右下角：时钟 + 读数
/// ripple / cursor          固定，跟随手机端光标
/// ```
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

    /// 轻点反馈的涟漪。
    @State private var rippleScale: CGFloat = 0.35
    @State private var rippleOpacity: Double = 0

    /// 内容总高 / 视口高。滚动行程由它决定 —— 取 1.6 表示滚到底时
    /// 内容正好上移 0.6 个视口高，画布底部与视口底部对齐、不露黑边。
    private static let contentHeightRatio: CGFloat = 1.6

    var body: some View {
        GeometryReader { geometry in
            let viewport = geometry.size
            let metrics = ScrollMetrics(
                viewport: viewport,
                contentHeight: viewport.height * Self.contentHeightRatio,
                inset: 0
            )

            ZStack(alignment: .topLeading) {
                backdrop(viewport)
                content(viewport: viewport, metrics: metrics)
                topScrim(viewport)
                caption(viewport)
                hud(viewport)
                ripple(viewport)
                cursor(viewport)
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

    // MARK: - 底层

    /// 常驻在最底下的一层。内容被推走 / 滚到底之后露出来的就是它。
    ///
    /// 标识上下各放一处：下拉满行程露出上半屏、上拉满行程露出下半屏，
    /// 只放一处的话总有一次露出的是纯黑，看起来像渲染没跟上。
    private func backdrop(_ viewport: CGSize) -> some View {
        let base = min(viewport.width, viewport.height)
        return ZStack {
            Color.black

            VStack(spacing: 0) {
                marker(base).padding(.top, viewport.height * 0.2)
                Spacer(minLength: 0)
                marker(base).padding(.bottom, viewport.height * 0.26)
            }
        }
        .frame(width: viewport.width, height: viewport.height)
        .clipped()
    }

    private func marker(_ base: CGFloat) -> some View {
        Text("EXTERNAL DISPLAY")
            .font(.system(size: base * 0.038, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.15))
    }

    // MARK: - 内容

    /// 一块比视口高的图案画布，随纵向三段位移。
    ///
    /// 位移取自 `ScrollMetrics`（滚动 / 下拉 / 上拉），它是纯几何，手机端只送归一化进度。
    ///
    /// 刻意**不做**横向位移：屏幕后面没有第二层内容可以露出来，
    /// 推走之后只会留下一条黑边 —— 那不是"被推开"，看起来像没铺满。
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
            colors: [.black.opacity(0.72), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: viewport.width, height: viewport.height * 0.3)
        .allowsHitTesting(false)
    }

    /// 标题与分辨率。**固定**在左上角，不随内容滚动 ——
    /// 画布滚走之后屏幕上仍要有一个"这是什么"的标识。
    private func caption(_ viewport: CGSize) -> some View {
        let base = min(viewport.width, viewport.height)
        return VStack(alignment: .leading, spacing: base * 0.014) {
            Text(store.caption)
                .font(.system(size: base * 0.072, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text(resolutionText(for: viewport))
                .font(.system(size: base * 0.036, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(base * 0.055)
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: - 固定 HUD

    private func hud(_ viewport: CGSize) -> some View {
        let base = min(viewport.width, viewport.height)
        return VStack(alignment: .trailing, spacing: base * 0.012) {
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                Text(timeline.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: base * 0.1, weight: .thin, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }

            Text(readout)
                .font(.system(size: base * 0.032, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(base * 0.06)
        .frame(width: viewport.width, height: viewport.height, alignment: .bottomTrailing)
        .shadow(color: .black.opacity(0.6), radius: base * 0.02)
        .allowsHitTesting(false)
    }

    private var readout: String {
        var parts = [
            "滚动 \(Int(remote.scroll * 100))%",
            "缩放 \(String(format: "%.2f", remote.zoom))×"
        ]
        if remote.pull > 0 {
            parts.append("下拉 \(Int(remote.pull * 100))%")
        }
        if remote.bottomPull > 0 {
            parts.append("上拉 \(Int(remote.bottomPull * 100))%")
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
