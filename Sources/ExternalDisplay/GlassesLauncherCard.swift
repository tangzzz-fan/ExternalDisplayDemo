import SwiftUI

struct GlassesLauncherCard: View {

    let viewport: CGSize
    let isHighlighted: Bool
    let statusText: String
    let errorText: String?

    var body: some View {
        let base = min(viewport.width, viewport.height)
        let rect = GlassesLauncherLayout.standard.rect(in: viewport)

        ZStack(alignment: .topLeading) {
            title(base: base, rect: rect)
            button(base: base, rect: rect)
            footer(base: base, rect: rect)
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func title(base: CGFloat, rect: CGRect) -> some View {
        VStack(spacing: base * 0.014) {
            Text("苏州 · 录屏演示")
                .font(.system(size: base * 0.068, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("手机端播 HTML，ReplayKit 录屏，回放到这块屏")
                .font(.system(size: base * 0.03, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .multilineTextAlignment(.center)
        .frame(width: viewport.width * 0.86)
        .position(x: viewport.width / 2, y: rect.minY - base * 0.14)
    }

    private func button(base: CGFloat, rect: CGRect) -> some View {
        HStack(spacing: base * 0.024) {
            Image(systemName: "play.fill")
                .font(.system(size: base * 0.042, weight: .bold))
            Text("播放演示视频")
                .font(.system(size: base * 0.044, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(isHighlighted ? Color.black : Color.white)
        .frame(width: rect.width, height: rect.height)
        .background(
            RoundedRectangle(cornerRadius: rect.height * 0.34, style: .continuous)
                .fill(
                    isHighlighted
                        ? AnyShapeStyle(Color.orange)
                        : AnyShapeStyle(Color.white.opacity(0.1))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: rect.height * 0.34, style: .continuous)
                .strokeBorder(Color.orange.opacity(isHighlighted ? 0 : 0.7), lineWidth: max(1.5, base * 0.006))
        )
        .scaleEffect(isHighlighted ? 1.03 : 1)
        .shadow(color: .orange.opacity(isHighlighted ? 0.5 : 0), radius: base * 0.04)
        .animation(.easeOut(duration: 0.16), value: isHighlighted)
        .position(x: rect.midX, y: rect.midY)
    }

    private func footer(base: CGFloat, rect: CGRect) -> some View {
        VStack(spacing: base * 0.012) {
            Text(isHighlighted ? "轻点手机屏幕确认" : "单指在手机手势面上移动光标，移到按钮上")
                .font(.system(size: base * 0.032, weight: .medium))
                .foregroundStyle(isHighlighted ? Color.orange : Color.white.opacity(0.55))

            if let errorText {
                Text(errorText)
                    .font(.system(size: base * 0.028, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            } else {
                Text(statusText)
                    .font(.system(size: base * 0.026, weight: .regular))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: viewport.width * 0.8)
        .position(x: viewport.width / 2, y: rect.maxY + base * 0.1)
    }
}
