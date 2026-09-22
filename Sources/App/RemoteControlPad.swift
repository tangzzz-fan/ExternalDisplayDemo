import Foundation
import SwiftUI

/// 手机端的遥控板 —— 外接屏唯一的输入来源。
///
/// 外接屏的 role 是 `windowExternalDisplayNonInteractive`，系统不向它投递任何触摸
/// （真机 `window.isUserInteractionEnabled = false`，模拟器 mock 里
/// `PassthroughWindow.hitTest` 恒返回 `nil`）。所以「在外接屏上滑动」只能在
/// 这里采集，再经 `RemoteControl` 单向送到外接屏的渲染视图。
///
/// 采集到的手势：
/// - 单指拖动 → 滚动，手指落点同时映射为外接屏上的光标
/// - 双指捏合 → 缩放（模拟器需按住 Option 拖拽）
///
/// 另配绝对定位控件（滑杆 / 按钮）作为兜底：模拟器里捏合手势不好操作，
/// 且真机上也常有"精确调到某个值"的需求。
/// **不要把它放进 `Form` / `ScrollView`**：触控板的 `DragGesture` 会与外层滚动视图的
/// 竖向 pan 手势竞争，而 SwiftUI 没有能压过祖先 ScrollView 的公开 API
/// （`highPriorityGesture` 只影响当前视图与其子视图）。
/// 统一由 `RemoteControlDock` 经 `.safeAreaInset` 挂在滚动区域之外。
struct RemoteControlPad: View {

    private let remote = RemoteControl.shared

    @State private var isDragging = false
    /// 上一次的累计位移，用来算逐帧增量。`DragGesture` 给的是累计值，
    /// 直接拿它当增量会让滚动速度随拖拽时长不断放大。
    @State private var lastTranslation: CGSize = .zero
    /// 同上，`MagnifyGesture` 给的也是累计倍率。
    @State private var lastMagnification: CGFloat = 1
    @State private var isMagnifying = false

    var body: some View {
        VStack(spacing: 14) {
            trackpad
            zoomSlider
            buttons
        }
        .padding(.vertical, 4)
    }

    // MARK: - 触控板

    private var trackpad: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))

                if !isDragging && !isMagnifying {
                    VStack(spacing: 4) {
                        Text("单指拖动 → 滚动外接屏")
                        Text("双指捏合 → 缩放（模拟器按住 Option）")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .frame(width: size.width, height: size.height)
                }

                scrollIndicator(size: size)

                // 手指落点 = 外接屏上的光标
                if let pointer = remote.pointer {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 20, height: 20)
                        .position(x: pointer.x * size.width, y: pointer.y * size.height)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .gesture(dragGesture(size: size))
            .simultaneousGesture(magnifyGesture)
        }
        .frame(height: 168)
    }

    /// 右侧的滚动位置指示条，和外接屏上的进度一一对应。
    private func scrollIndicator(size: CGSize) -> some View {
        let trackWidth: CGFloat = 4
        let knobHeight: CGFloat = 30
        let travel = max(0, size.height - knobHeight - 16)

        return Capsule()
            .fill(Color.orange.opacity(0.75))
            .frame(width: trackWidth, height: knobHeight)
            .offset(x: size.width - trackWidth - 10, y: 8 + travel * remote.scroll)
            .allowsHitTesting(false)
    }

    // MARK: - 手势

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                isDragging = true

                remote.movePointer(
                    to: CGPoint(
                        x: value.location.x / size.width,
                        y: value.location.y / size.height
                    )
                )

                // 捏合进行中就不滚动，否则一次捏合会顺带把画面滑走。
                guard !isMagnifying else {
                    lastTranslation = value.translation
                    return
                }

                let delta = CGSize(
                    width: value.translation.width - lastTranslation.width,
                    height: value.translation.height - lastTranslation.height
                )
                lastTranslation = value.translation
                remote.scroll(by: delta.height / size.height)
            }
            .onEnded { _ in
                lastTranslation = .zero
                isDragging = false
            }
    }

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
