import Foundation
import SwiftUI

/// 外接屏上渲染的根视图。
///
/// 它被 `ExternalDisplaySceneDelegate` 通过 `UIHostingController` 挂到
/// 外接屏的 `UIWindow` 上。除了承载它的 window 之外，这个视图和普通
/// SwiftUI 视图没有任何区别。
///
/// ## 为什么这里一个手势都没有
/// 外接屏的 role 是 `windowExternalDisplayNonInteractive` —— 系统不会向它投递
/// 任何触摸事件（真机上 `window.isUserInteractionEnabled = false`，模拟器 mock 里
/// `PassthroughWindow.hitTest` 恒返回 `nil`）。
///
/// 所以这个视图是**纯输出**的：它只读 `RemoteControl` 的共享状态，
/// 滚动 / 缩放 / 光标全部由手机端的遥控板写入。在这里加 `ScrollView`
/// 或 `.gesture` 是无效的 —— 手势根本到不了这棵视图树。
///
/// 排版全部按画面短边等比缩放，因此同一份代码在 1080p 真外接屏、
/// 4K 外接屏、以及模拟器的 letterbox 小窗口里都不会溢出或截断。
struct ExternalDisplayRootView: View {

    /// 由 scene delegate 从 `windowScene.screen.nativeBounds` 传入。
    let resolution: String

    private let store = DisplayContentStore.shared
    private let remote = RemoteControl.shared

    /// 轻点反馈的涟漪。
    @State private var rippleScale: CGFloat = 0.35
    @State private var rippleOpacity: Double = 0

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

                pointerRing(metrics: metrics)

                ripple(metrics: metrics)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onChange(of: remote.tapCount) { _, _ in playRipple() }
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

            Text(resolution + " px")
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
        }
        .padding(metrics.base * 0.06)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .shadow(color: .black.opacity(0.6), radius: metrics.base * 0.02)
    }

    // MARK: - 光标与轻点反馈

    private func pointerRing(metrics: ScrollMetrics) -> some View {
        Group {
            if let pointer = remote.pointer {
                let diameter = metrics.base * 0.1
                ZStack {
                    Circle().fill(Color.orange.opacity(0.22))
                    Circle().stroke(Color.orange, lineWidth: max(1.5, metrics.base * 0.007))
                    Circle()
                        .fill(Color.orange)
                        .frame(width: diameter * 0.18, height: diameter * 0.18)
                }
                .frame(width: diameter, height: diameter)
                .position(
                    x: pointer.x * metrics.viewport.width,
                    y: pointer.y * metrics.viewport.height
                )
                .shadow(color: .black.opacity(0.6), radius: metrics.base * 0.015)
            }
        }
    }

    private func ripple(metrics: ScrollMetrics) -> some View {
        let center = remote.pointer.map {
            CGPoint(x: $0.x * metrics.viewport.width, y: $0.y * metrics.viewport.height)
        } ?? CGPoint(x: metrics.viewport.width / 2, y: metrics.viewport.height / 2)

        return Circle()
            .stroke(Color.orange, lineWidth: max(2, metrics.base * 0.01))
            .frame(width: metrics.base * 0.22, height: metrics.base * 0.22)
            .scaleEffect(rippleScale)
            .opacity(rippleOpacity)
            .position(center)
            .allowsHitTesting(false)
    }

    private func playRipple() {
        rippleScale = 0.35
        rippleOpacity = 0.9
        withAnimation(.easeOut(duration: 0.55)) {
            rippleScale = 2.0
            rippleOpacity = 0
        }
    }
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
    ExternalDisplayRootView(resolution: "1920 × 1080")
}
