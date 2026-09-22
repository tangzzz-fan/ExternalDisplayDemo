import Foundation
import SwiftUI

/// 底部常驻的遥控台 —— 遥控板的宿主与折叠外壳。
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
/// 默认收起，只留一条读数栏；展开才铺开触控板。
struct RemoteControlDock: View {

    private let remote = RemoteControl.shared

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            summary

            if isExpanded {
                Divider()
                RemoteControlPad()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
        .background(.bar)
    }

    // MARK: - 读数栏（同时是展开/收起按钮）

    private var summary: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("遥控外接屏")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("滚动 \(Int(remote.scroll * 100))% · 缩放 \(String(format: "%.2f", remote.zoom))× · \(remote.lastEvent)")
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
}

#Preview {
    VStack(spacing: 0) {
        Spacer()
        RemoteControlDock()
    }
}
