import SwiftUI

/// 外接屏上的图案渲染。
///
/// 用 `TimelineView(.animation)` + `Canvas` 走的是显示链路驱动（内部即 CADisplayLink），
/// 目的是让"外接屏真的由本应用逐帧渲染"这件事可以被肉眼验证：
/// 手机端关掉「帧驱动动画」后外接屏应当立刻静止。
///
/// 真实项目里把 `Canvas` 换成承载 `MTKView` / `AVPlayerLayer` 的
/// `UIViewRepresentable` 即可，scene 接入层不需要任何改动。
struct DisplayPatternCanvas: View {

    let pattern: DisplayContentStore.Pattern
    let isAnimated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isAnimated)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        guard size.width > 0, size.height > 0 else { return }
        switch pattern {
        case .gradient: drawGradient(&context, size: size, time: time)
        case .grid: drawGrid(&context, size: size, time: time)
        case .colorBars: drawColorBars(&context, size: size, time: time)
        }
    }

    // MARK: - Patterns

    private func drawGradient(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        let phase = CGFloat((time * 0.25).truncatingRemainder(dividingBy: 1))
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [.red, .purple, .blue, .cyan, .green, .yellow, .red]),
                startPoint: CGPoint(x: size.width * (phase - 0.5), y: 0),
                endPoint: CGPoint(x: size.width * (phase + 0.5), y: size.height)
            )
        )
    }

    private func drawGrid(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.06)))

        let step = max(40, size.width / 32)
        var grid = Path()
        var x: CGFloat = 0
        while x <= size.width {
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
            x += step
        }
        var y: CGFloat = 0
        while y <= size.height {
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
            y += step
        }
        context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)

        // 扫描线
        let phase = CGFloat((time * 0.5).truncatingRemainder(dividingBy: 1))
        let centerY = size.height * phase
        let band: CGFloat = 90
        context.fill(
            Path(CGRect(x: 0, y: centerY - band / 2, width: size.width, height: band)),
            with: .linearGradient(
                Gradient(colors: [.clear, Color.green.opacity(0.7), .clear]),
                startPoint: CGPoint(x: 0, y: centerY - band / 2),
                endPoint: CGPoint(x: 0, y: centerY + band / 2)
            )
        )
    }

    private func drawColorBars(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        let colors: [Color] = [.white, .yellow, .cyan, .green, .purple, .red, .blue, .black]
        let barWidth = size.width / CGFloat(colors.count)
        let barsHeight = size.height * 0.75

        for (index, color) in colors.enumerated() {
            context.fill(
                Path(CGRect(x: CGFloat(index) * barWidth, y: 0, width: barWidth, height: barsHeight)),
                with: .color(color)
            )
        }
        context.fill(
            Path(CGRect(x: 0, y: barsHeight, width: size.width, height: size.height - barsHeight)),
            with: .color(Color(white: 0.08))
        )

        // 游标，同样用于确认帧驱动
        let phase = CGFloat((time * 0.5).truncatingRemainder(dividingBy: 1))
        context.fill(
            Path(CGRect(x: size.width * phase - 30, y: barsHeight, width: 60, height: size.height - barsHeight)),
            with: .color(.white)
        )
    }
}

#Preview {
    DisplayPatternCanvas(pattern: .grid, isAnimated: true)
}
