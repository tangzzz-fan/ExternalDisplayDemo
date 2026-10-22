import SwiftUI

/// 手机端主界面：一条状态栏 + 一整块手势面。
///
/// 这块面是外接屏**唯一**的输入来源 —— 外接屏的 role 是非交互的，
/// 系统不向它投递任何触摸，所以一切操作都从这里采集，经 `RemoteControl` 单向送过去。
///
/// 手势面刻意**不放在任何滚动容器里**（没有 `Form`、没有 `ScrollView`）：
/// `TouchSurface` 是 UIKit 触摸层，祖先的 pan 识别器一旦认可就会给它发
/// `touchesCancelled`，表现是拖动中途突然停住 —— 而 SwiftUI 没有能压过
/// 祖先滚动视图的公开 API。整屏只放这一块面，归属没有任何歧义。
struct PhoneRootView: View {

    private let monitor = ExternalDisplayMonitor.shared
    private let remote = RemoteControl.shared
    @Bindable private var mock = MockExternalDisplay.shared
    @Bindable private var flow = DemoFlow.shared

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 14) {
                    GesturePad(
                        hints: [],
                        scrollGesture: .twoFinger,
                        onTap: {
                            remote.tap()
                            flow.activate(at: remote.pointer)
                        }
                    )
                    .aspectRatio(padAspect, contentMode: .fit)
                    .frame(maxWidth: 320)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 1)
                    )

                    hintList
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 26)
            }
        }
        .background(Color(.systemGroupedBackground))
        .fullScreenCover(isPresented: $flow.isPagePresented) {
            CaptureScreenView(flow: flow)
                .interactiveDismissDisabled()
        }
        .onAppear {
            if remote.pointer == nil {
                remote.movePointer(to: GlassesLauncherLayout.standard.buttonCenter)
            }
        }
    }

    private var padAspect: CGFloat {
        guard let size = monitor.attachments.first?.pixelSize, size.width > 0, size.height > 0 else {
            return 16.0 / 9.0
        }
        return size.width / size.height
    }

    private var hintList: some View {
        VStack(spacing: 6) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                Text(hint.text)
                    .font(.footnote)
                    .foregroundStyle(hint.isSecondary ? Color.secondary.opacity(0.6) : Color.secondary)
            }
        }
        .multilineTextAlignment(.center)
    }

    private var hints: [GesturePadHint] {
        [
            GesturePadHint(text: "单指在触摸板内移动 → 移动光标"),
            GesturePadHint(text: "轻点 → 点击光标下的按钮"),
            GesturePadHint(text: "双指上下 → 滚动背景图案"),
            GesturePadHint(text: "双指捏合 → 缩放（模拟器按住 Option）", isSecondary: true)
        ]
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(monitor.isConnected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(monitor.isConnected ? "外接屏已连接" : "未检测到外接屏")
                    .font(.subheadline.weight(.medium))

                if let attachment = monitor.attachments.first {
                    Text(attachment.resolution)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(flow.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if flow.phase == .playback {
                Button("重新录制") { flow.restart() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }

            if MockExternalDisplay.isEnabled {
                Button {
                    mock.isVisible.toggle()
                } label: {
                    Image(systemName: mock.isVisible ? "rectangle.inset.filled" : "rectangle.dashed")
                        .font(.title3)
                        .foregroundStyle(mock.isVisible ? Color.orange : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

#Preview {
    PhoneRootView()
}
