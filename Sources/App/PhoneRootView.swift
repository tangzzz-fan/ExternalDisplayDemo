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

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()

            GesturePad(
                hints: [
                    GesturePadHint(text: "单指移动 → 移动光标"),
                    GesturePadHint(text: "双指上下 → 滚动 / 下拉 / 上拉"),
                    GesturePadHint(text: "轻点 → 点击确认"),
                    GesturePadHint(text: "双指捏合 → 缩放（模拟器按住 Option）", isSecondary: true)
                ],
                scrollGesture: .twoFinger,
                onTap: { remote.tap() }
            )
            .padding(12)
        }
        .background(Color(.systemGroupedBackground))
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

                Text(detailText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

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

    /// 连接了就报分辨率，没连接就报最近一条事件 —— 一行里总有点可读的东西。
    private var detailText: String {
        if let attachment = monitor.attachments.first {
            return "\(attachment.resolution) · \(remote.lastEvent)"
        }
        return remote.lastEvent
    }
}

#Preview {
    PhoneRootView()
}
