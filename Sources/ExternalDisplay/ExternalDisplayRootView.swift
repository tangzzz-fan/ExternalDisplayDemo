import SwiftUI

/// 外接屏上渲染的根视图。
///
/// 它被 `ExternalDisplaySceneDelegate` 通过 `UIHostingController` 挂到
/// 外接屏的 `UIWindow` 上。除了承载它的 window 之外，这个视图和普通
/// SwiftUI 视图没有任何区别。
///
/// 排版全部按画面短边等比缩放，因此同一份代码在 1080p 真外接屏、
/// 4K 外接屏、以及模拟器的 letterbox 小窗口里都不会溢出或截断。
struct ExternalDisplayRootView: View {

    /// 由 scene delegate 从 `windowScene.screen.nativeBounds` 传入。
    let resolution: String

    private let store = DisplayContentStore.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            DisplayPatternCanvas(pattern: store.pattern, isAnimated: store.isAnimated)
                .ignoresSafeArea()

            GeometryReader { geometry in
                overlay(base: min(geometry.size.width, geometry.size.height))
            }
        }
        .preferredColorScheme(.dark)
    }

    private func overlay(base: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: base * 0.02) {
            Text(store.caption)
                .font(.system(size: base * 0.075, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text(resolution + " px")
                .font(.system(size: base * 0.038, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))

            Spacer(minLength: 0)

            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                Text(timeline.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: base * 0.13, weight: .thin, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(base * 0.08)
        .shadow(color: .black.opacity(0.5), radius: base * 0.02, y: base * 0.003)
    }
}

#Preview {
    ExternalDisplayRootView(resolution: "1920 × 1080")
}
