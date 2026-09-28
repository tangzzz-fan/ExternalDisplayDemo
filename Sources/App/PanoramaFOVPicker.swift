import SwiftUI

/// 全景页的视场档位选择器 —— 手机端唯一改视场的地方。
///
/// ## 为什么放在手机端
/// 视场是**播放器参数**，不是眼镜端能做的交互。spacewalker（VITURE 官方 app）
/// 也是这个分工："Control playback and adjust brightness, volume, and **FOV on
/// your phone**"。外接屏那一侧只有非交互的 role，它连触摸都收不到
/// （见 `RemoteControlPad` 的文档），本来也放不了控件。
///
/// ## 为什么触控板与空鼠两栏都要挂
/// 全景页里主力输入是空鼠那一栏（转手机），而触控板那一栏是模拟器上唯一能手动
/// 动视角的路。只在其中一栏放，另一栏就够不到 —— 而"够不到"在演示时
/// 与"没有这个功能"是同一种表现。两栏挂的是**同一个视图、同一份状态**
/// （`RemoteControl.panoramaFOV`），所以不存在两边不一致的问题。
///
/// ## 只在 equirect 页出现
/// 柱面（A 类）走 `PhotoDetailGeometry(.fill)`，没有视场这个概念。
/// 在那一页摆一个按了没反应的控件，只会让人以为它是坏的。
///
/// ## 为什么是分段控件而不是滑杆
/// 档位只有三个且有序，"我这一窗是 60 还是 90"是**选择**不是**调参**。
/// 分段控件顺带把"另外两档存在"这件事显示出来，滑杆显示不出来。
struct PanoramaFOVPicker: View {

    private let remote = RemoteControl.shared

    var body: some View {
        if remote.detailProjection == .equirect {
            HStack(spacing: 12) {
                Image(systemName: "arrow.left.and.right.square")
                    .foregroundStyle(.secondary)

                Picker(
                    "视场",
                    selection: Binding(
                        get: { remote.panoramaFOV },
                        set: { remote.setPanoramaFOV($0) }
                    )
                ) {
                    ForEach(EquirectProjection.fovStops, id: \.self) { stop in
                        Text("\(Int(stop))°").tag(stop)
                    }
                }
                .pickerStyle(.segmented)
            }
            .font(.footnote)
        }
    }
}

#Preview {
    Form {
        Section("全景页 · 视场") {
            PanoramaFOVPicker()
        }
    }
}
