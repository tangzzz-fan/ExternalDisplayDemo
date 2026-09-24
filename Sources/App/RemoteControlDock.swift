import Foundation
import SwiftUI

/// 底部常驻的遥控台 —— 手机端输入方式的宿主与折叠外壳。
///
/// ## 为什么用 `.safeAreaInset` 而不是塞进 `Form`
/// 触控板的 `DragGesture` 与外层滚动视图的竖向 pan 手势会互相竞争。
/// 放进 `Form` 就变成「看运气」—— 拖动触控板时表单可能跟着一起滚，
/// 而 SwiftUI 没有能压过祖先 ScrollView 的公开 API（`highPriorityGesture`
/// 只影响当前视图与其子视图）。
///
/// 挂成 `safeAreaInset` 后它在滚动区域**之外**，手势归属没有歧义。
/// 顺带解决两件事：
/// - 不用先滚动到表单底部才能摸到遥控板；
/// - 模拟外接屏的替身窗口浮在 `.normal + 1` 层且垂直居中，
///   不会盖住贴在底部的遥控台，两者可以同时看见。
///
/// 默认收起，只留一条读数栏；展开才铺开具体控件。
struct RemoteControlDock: View {

    /// 手机端把操作送到眼镜屏的两种方式。二者共用 `RemoteControl` 的同一个落点，
    /// 只是采集源与光标外观不同。
    enum ControlMode: String, CaseIterable, Identifiable {
        /// 手机屏当触控板，单指移动光标、双指滚动。
        case trackpad
        /// 手机当空鼠，抬手转动手机移动激光指针。
        case airMouse

        var id: String { rawValue }

        var title: String {
            switch self {
            case .trackpad: "触控板"
            case .airMouse: "空鼠"
            }
        }
    }

    private let remote = RemoteControl.shared
    private let airMouse = AirMouse.shared

    @State private var isExpanded = false
    @State private var mode: ControlMode = .trackpad

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            summary

            if isExpanded {
                Divider()
                controls
            }
        }
        .background(.bar)
        .background { heightReporter }
        // `-dockState=expanded,airMouse`：把"展开 + 切到空鼠栏"这两下点击
        // 变成启动参数，好让空鼠栏也进入逐状态截图流程（`MockDockState` 里有说明）。
        .onAppear { applyMockState() }
    }

    /// 把自身高度上报给模拟外接屏替身窗口。
    ///
    /// 遥控台的高度随「收起 / 展开 / 当前在哪一栏」大幅变化（约 50 ~ 430pt），
    /// 而替身窗口浮在主窗口**之上**，会盖住遥控台顶部的控件 ——
    /// 空鼠栏比触控板栏多一块手势面，加完之后「触控板 / 空鼠」切换器就被盖住了。
    /// 所以预留量不能写死，得由这里实测上报。见 `MockExternalDisplay.reserveBottom`。
    private var heightReporter: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { report(height: proxy.size.height) }
                .onChange(of: proxy.size.height) { _, height in report(height: height) }
        }
    }

    private func report(height: CGFloat) {
        guard MockExternalDisplay.isEnabled else { return }
        MockExternalDisplay.shared.reserveBottom(height)
    }

    private func applyMockState() {
        guard let state = MockDockState.current else { return }
        if state.isExpanded { isExpanded = true }
        if let raw = state.modeRaw, let preset = ControlMode(rawValue: raw) {
            mode = preset
        }
    }

    // MARK: - 读数栏（同时是展开/收起按钮）

    private var summary: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("遥控外接屏")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        if airMouse.isRunning {
                            Text("空鼠")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.red)
                        }
                    }

                    Text(detailText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var detailText: String {
        var parts = [
            "滚动 \(Int(remote.scroll * 100))%",
            "缩放 \(String(format: "%.2f", remote.zoom))×"
        ]
        // 下拉是"隐藏"状态：没下拉时不占地方，一旦发生就必须能看见 ——
        // 否则背景墙露出后用户会以为画面出错了。
        if remote.pull > 0 {
            parts.append("下拉 \(Int(remote.pull * 100))%")
        }
        if airMouse.isRunning {
            var text = "空鼠\(airMouse.state.title)"
            if let usable = airMouse.warmup.milestones.usable {
                text += String(format: " %.2fs", usable)
            }
            parts.append(text)
        } else {
            parts.append(remote.lastEvent)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 展开区

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("输入方式", selection: $mode) {
                ForEach(ControlMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .trackpad:
                RemoteControlPad()
            case .airMouse:
                AirMousePad()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

#Preview {
    VStack(spacing: 0) {
        Spacer()
        RemoteControlDock()
    }
}
