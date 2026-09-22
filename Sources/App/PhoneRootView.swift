import SwiftUI

/// 手机端主界面：只做两件事 —— 显示外接屏连接状态、决定推送到外接屏的内容。
struct PhoneRootView: View {

    private let monitor = ExternalDisplayMonitor.shared
    @Bindable private var store = DisplayContentStore.shared
    @Bindable private var mock = MockExternalDisplay.shared

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                contentSection
                if MockExternalDisplay.isEnabled {
                    debugSection
                }
                hintSection
            }
            .navigationTitle("External Display")
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section("连接状态") {
            HStack(spacing: 12) {
                Circle()
                    .fill(monitor.isConnected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                Text(monitor.statusText)
                    .font(.body.weight(.medium))
            }

            ForEach(monitor.attachments) { attachment in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(attachment.resolution)
                            .font(.subheadline.monospacedDigit())
                        Spacer()
                        Text(attachment.source == .mock ? "模拟" : "物理")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                (attachment.source == .mock ? Color.orange : Color.blue).opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(attachment.source == .mock ? Color.orange : Color.blue)
                    }
                    Text("session id: \(attachment.id)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 2)
            }

            if !monitor.isConnected {
                Text("插入 USB-C / Lightning 转 HDMI 适配器，或把 iPad 接入台前调度外接屏后，此处会自动刷新。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var contentSection: some View {
        Section("推送到外接屏") {
            Picker("图案", selection: $store.pattern) {
                ForEach(DisplayContentStore.Pattern.allCases) { pattern in
                    Text(pattern.title).tag(pattern)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Toggle("帧驱动动画", isOn: $store.isAnimated)

            HStack {
                Text("标题")
                Spacer()
                TextField("caption", text: $store.caption)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var debugSection: some View {
        Section("调试") {
            Toggle("显示模拟外接屏", isOn: $mock.isVisible)
            Text("模拟器不支持外接显示器，这里用 `-mockExternalDisplay` 起了一个 16:9 的替身窗口，挂的是外接屏那份视图。收起后即可正常操作上面的表单。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var hintSection: some View {
        Section {
            Text("外接屏上的内容是同一进程内的另一个 UIScene，共享内存，无需任何跨进程通道。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    PhoneRootView()
}
