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
/// - 单指移动 → 移动外接屏上的光标，**不**产生任何位移
/// - 双指上下滑动 → 滚动；顶到头继续拽是下拉、底到头继续拽是上拉
/// - 双指左右滑动 → 横向推开幕墙，让出那一侧露出星海
/// - 单指轻点 → 点击确认
/// - 双指捏合 → 缩放（模拟器需按住 Option 拖拽）
///
/// ## 同一根手指在哪一页上改的是不同的量
/// 上面两条"双指"的描述是**幕墙页**的行为。进了详情页之后：
/// 照片页改的是照片的平移；**全景页改的是视角**（左右 → yaw、上下 → pitch，
/// 上下只对 equirect 生效）。也就是说全景页里转视角有**两条路** ——
/// 手机屏上双指拖动，和直接转手机（空鼠那条链）。分流点不在手势层，
/// 而在 `RemoteControl.scroll(by:)` / `lateral(by:)` 里按当前页决定去向。
///
/// 这条以前只在 `RemoteControlPad` 的 hints 里漏掉，于是"转视角得拿着手机转"
/// 成了看起来唯一的路（票 `07` 的文案修正）。
///
/// ## ⚠️ 全景页里拖动的方向**与幕墙页相反**（票 `09`）
/// 幕墙页是"推板、露出那一侧的星海"，全景页是"转身、看向那一侧"——
/// 同一根手指往右滑，幕墙右移，全景页里却是视线右移。
/// 判据是**你在这个页面上想干什么**：幕墙上你想挪动内容，全景页里你想转动视线。
/// 更要紧的是页**内**必须同向：全景页的另一个输入源（转手机）就是"转身"，
/// 拖动若还按"抓图"走，两条路会给出相反的结果。
///
/// 单指与双指各占一样，是为了让"我要移光标"和"我要推画面"两种意图
/// 不靠位移方向去猜 —— 猜错一次就是一次误操作，而手指数量是明确的。
/// 触控板上的横向也因此必须走**双指**：单指已经被光标占满了。
///
/// 另配绝对定位控件（滑杆 / 按钮）作为兜底：模拟器里捏合手势不好操作，
/// 且真机上也常有"精确调到某个值"的需求。
/// **不要把它放进 `Form` / `ScrollView`**：采集面会与外层滚动视图的
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
            PanoramaFOVPicker()
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
                GesturePadHint(text: "单指移动 → 移动光标"),
                GesturePadHint(text: "双指上下 → 滚动 / 顶部下拉；全景页 → 抬头低头"),
                GesturePadHint(text: "双指左右 → 推开幕墙；全景页 → 转身（右滑 = 看右边）"),
                GesturePadHint(text: "轻点 → 打开照片；详情页双击 → 铺满"),
                GesturePadHint(text: "全景页：拖动与转手机同向；双击 = 返回幕墙"),
                GesturePadHint(text: "双指捏合 → 缩放（模拟器按住 Option）", isSecondary: true)
            ],
            scrollGesture: .twoFinger,
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
            // 详情页里出现。全景页尤其需要它：那一页里姿态喂视角、光标恒为 `nil`，
            // 而外接屏的返回按钮靠指针命中 —— 不放这个按钮，空鼠模式下就没有出口
            // （票 `08` 的第二个真机反馈。P4 拍板"两者物理互斥"的代价，见 spec §4.3-3）。
            if remote.detailItemID != nil {
                Button("返回") { remote.closeDetail() }
            }
            // 只在全景页出现。它的语义是"把**累积**的视角拉回正前方"，
            // 在别的页上根本不成立 —— 摆在幕墙/照片页里只会是个按了没反应的按钮。
            //
            // 之所以要有它：视角是逐帧累积的（见 `PanoramaLook`），漂移会攒；
            // 而空鼠那一栏的「归零」在全景页里归的也是视角，但触控板模式下够不到它。
            // 遥控台是手机端唯一常驻的操作面，这个"纠偏键"必须随手可及。
            if remote.isPanoramaDetail {
                Button("视角归零") { remote.recenterLook() }
            }
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
