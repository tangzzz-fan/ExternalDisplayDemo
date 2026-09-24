import Foundation
import SwiftUI

/// 手机端的遥控板 —— 外接屏唯一的输入来源。
///
/// 外接屏的 role 是 `windowExternalDisplayNonInteractive`，系统不向它投递任何触摸
/// （真机 `window.isUserInteractionEnabled = false`，模拟器 mock 里
/// `PassthroughWindow.hitTest` 恒返回 `nil`）。所以「在外接屏上滑动」只能在
/// 这里采集，再经 `RemoteControl` 单向送到外接屏的渲染视图。
///
/// 采集到的手势（全部由 `GesturePad` 承担，本类只负责接线）：
/// - 单指拖动 → 滚动，手指落点同时映射为外接屏上的光标
/// - 单指轻点 → 点击确认
/// - 双指捏合 → 缩放（模拟器需按住 Option 拖拽）
///
/// 另配绝对定位控件（滑杆 / 按钮）作为兜底：模拟器里捏合手势不好操作，
/// 且真机上也常有"精确调到某个值"的需求。
/// **不要把它放进 `Form` / `ScrollView`**：采集面的 `DragGesture` 会与外层滚动视图的
/// 竖向 pan 手势竞争，而 SwiftUI 没有能压过祖先 ScrollView 的公开 API
/// （`highPriorityGesture` 只影响当前视图与其子视图）。
/// 统一由 `RemoteControlDock` 经 `.safeAreaInset` 挂在滚动区域之外。
struct RemoteControlPad: View {

    private let remote = RemoteControl.shared

    /// 捏合进行中。
    @State private var isMagnifying = false
    /// `MagnifyGesture` 给的也是累计倍率，需要缓存上一次的值算增量。
    @State private var lastMagnification: CGFloat = 1

    var body: some View {
        VStack(spacing: 14) {
            trackpad
            zoomSlider
            pullSlider
            buttons
        }
        .padding(.vertical, 4)
    }

    // MARK: - 触控板

    private var trackpad: some View {
        GesturePad(
            hints: [
                GesturePadHint(text: "单指拖动 → 滚动外接屏"),
                GesturePadHint(text: "顶部继续下拉 → 露出星海背景墙"),
                GesturePadHint(text: "轻点 → 点击确认"),
                GesturePadHint(text: "双指捏合 → 缩放（模拟器按住 Option）", isSecondary: true)
            ],
            // 捏合中禁掉滚动，否则一次捏合会顺带把画面滑走
            isScrollEnabled: !isMagnifying,
            isBusy: isMagnifying,
            onTap: { remote.tap() }
        )
        .simultaneousGesture(magnifyGesture)
    }

    // MARK: - 手势

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                isMagnifying = true
                let delta = value.magnification / max(lastMagnification, 0.01)
                lastMagnification = value.magnification
                remote.zoom(by: delta)
            }
            .onEnded { _ in
                lastMagnification = 1
                isMagnifying = false
            }
    }

    // MARK: - 绝对定位控件

    private var zoomSlider: some View {
        HStack(spacing: 12) {
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { remote.zoom },
                    set: { remote.setZoom($0) }
                ),
                in: RemoteControl.zoomRange
            )
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
    }

    /// 下拉滑杆 —— 背景墙的露出比例。
    ///
    /// 存在的理由和缩放滑杆一样：模拟器里手势不好做，真机上也有"精确调到某个
    /// 露出比例"的需求。它同时是验证下拉几何最省事的入口：拖到底就是
    /// 「内容顶边落在屏幕中线」那个几何承诺。
    private var pullSlider: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.bottomhalf.inset.filled")
                .foregroundStyle(remote.pull > 0 ? Color.cyan : Color.secondary)

            Slider(
                value: Binding(
                    get: { remote.pull },
                    set: { remote.pull(to: $0) }
                ),
                in: 0...1
            )

            Text("\(Int(remote.pull * 100))%")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(remote.pull > 0 ? Color.cyan : Color.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .font(.footnote)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button("回到顶部") { remote.scrollToTop() }
            Button("轻点") { remote.tap() }
            Button("复位") { remote.reset() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    Form {
        Section("遥控外接屏") {
            RemoteControlPad()
        }
    }
}
