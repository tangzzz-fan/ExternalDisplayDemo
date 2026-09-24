import SwiftUI

/// 底部遥控台里的空鼠控制。
///
/// 只放"手上要够得着"的东西：启动/停止、归零、扳机、灵敏度、参考系。
/// 预热与可用时间的完整读数在 `AirMouseDiagnostics`（表单里），
/// 这里只留一行摘要 —— 遥控台是操作面，不是仪表盘。
///
/// ## 为什么这里也要一块手势面
/// 空鼠的交互是「抬手瞄准 + 确认」，而确认原本只有一个「扳机」按钮。
/// 但空鼠工作时手机是被**举起来**的，手指去够底部那个按钮既别扭、又会带歪姿态 ——
/// 瞄准的那只手没法稳定地去点一个具体控件。
/// 所以确认必须能落在手边的任意位置：整块面板都是轻点目标（`GesturePad`）。
/// 顺带把"上下拖动滚动"也放进来，这样空鼠跑着的时候不必切回触控板那一栏。
///
/// ## 为什么归零是一个常规按钮
/// 陀螺仪积分出的 yaw 会漂移，而且 `ZVertical` 参考系的水平零点**本来就是任意的**，
/// 所以"当前指向 = 屏幕中心"这件事必须能随时重新声明。
/// 真机遥控器都把它做成一个键，不是异常恢复手段。
struct AirMousePad: View {

    @Bindable private var airMouse = AirMouse.shared
    private let remote = RemoteControl.shared

    var body: some View {
        VStack(spacing: 14) {
            statusRow
            actionRow
            gesturePad
            sensitivityRow
            frameRow
        }
        .padding(.vertical, 4)
    }

    // MARK: - 状态

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text("空鼠 · \(airMouse.state.title)")
                    .font(.footnote.weight(.semibold))

                Text(summary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(airMouse.isRunning ? "停止" : "启动") {
                airMouse.toggle()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(airMouse.isRunning ? Color.red : Color.accentColor)
        }
    }

    private var statusColor: Color {
        if airMouse.state.isFailure { return .red }
        switch airMouse.state {
        case .tracking: return .green
        case .warming: return .orange
        default: return Color.secondary.opacity(0.4)
        }
    }

    /// 一行摘要：可用时间优先，其次是失败原因。
    private var summary: String {
        if let reason = airMouse.state.reason { return reason }
        if airMouse.warmup.isSynthetic {
            return "模拟数据源 · 无真实陀螺仪读数（-mockAirMouse）"
        }
        if let usable = airMouse.warmup.milestones.usable {
            return String(format: "可用时间 %.2f s · 扳机 %d 次", usable, airMouse.triggerCount)
        }
        if airMouse.isRunning {
            let count = airMouse.warmup.stream.sampleCount
            return "已收 \(count) 个样本 · \(airMouse.warmup.frame.title)"
        }
        return "抬手转动手机移动激光，轻点面板或扳机确认"
    }

    // MARK: - 操作

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                airMouse.recenter()
            } label: {
                Label("归零", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!airMouse.isRunning)

            Button {
                airMouse.trigger()
            } label: {
                Label("扳机", systemImage: "hand.tap.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!airMouse.isRunning)
        }
    }

    // MARK: - 手势面

    /// 空鼠开着时的单指手势面。
    ///
    /// 落点**不**映射光标：这一栏的光标归陀螺仪管，手指再插一脚会让激光乱跳。
    /// 所以这块面板只做两件事 —— 轻点确认、拖动推画面。
    ///
    /// 位移认**单指**（`.oneFinger`），与触摸板相反：手机举在手上的时候，
    /// 腾出第二根手指去滑面板既别扭又会带歪姿态，单指是这里唯一顺手的做法。
    /// 代价是纵向与横向都由这一根手指承担，于是必须靠**主轴锁定**分流
    /// （见 `PadGesture`）—— 手指横着走就推幕墙、竖着走就滚动，不会一起动。
    private var gesturePad: some View {
        GesturePad(
            hints: [
                GesturePadHint(text: "轻点面板 → 点击确认（等同扳机）"),
                GesturePadHint(text: "单指上下 → 滚动 / 顶部下拉 / 底部上拉"),
                GesturePadHint(text: "单指左右 → 推开幕墙，露出星海"),
                GesturePadHint(text: "抬手转动手机 → 移动激光", isSecondary: true)
            ],
            height: 120,
            mapsPointer: false,
            scrollGesture: .oneFinger,
            onTap: { confirm() }
        )
    }

    /// 轻点确认。
    ///
    /// 空鼠开着时走 `trigger()` —— 它会计一次扳机次数，手机端的读数栏与诊断页都能看到，
    /// 与按「扳机」按钮是同一条路径。没开时退化成一次普通轻点，
    /// 免得这块面板在空鼠没启动时变成哑巴。
    private func confirm() {
        if airMouse.isRunning {
            airMouse.trigger()
        } else {
            remote.tap()
        }
    }

    // MARK: - 灵敏度与参考系

    private var sensitivityRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "hare")
                .foregroundStyle(.secondary)
            Slider(value: $airMouse.sensitivity, in: 0.3...3)
            Image(systemName: "tortoise")
                .foregroundStyle(.secondary)
            Text(String(format: "%.2f×", airMouse.sensitivity))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .font(.footnote)
    }

    private var frameRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 刻意列**全部**参考系而不是只列本机支持的那些：模拟器上
            // `availableAttitudeReferenceFrames()` 返回空集，只列支持的会让这个
            // Picker 变成空列表 —— 选中的值不在候选里，`Picker` 直接渲染成空白。
            // 列全量并把不支持标出来，既不会空，也顺带把能力边界讲清楚了。
            Picker("参考系", selection: $airMouse.referenceFrame) {
                ForEach(MotionReferenceFrame.allCases) { frame in
                    Text(frameLabel(frame)).tag(frame)
                }
            }
            .pickerStyle(.menu)

            Text(airMouse.referenceFrame.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if airMouse.isRunning {
                Text("改动在下次启动生效（运行中切换需要重启数据流）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func frameLabel(_ frame: MotionReferenceFrame) -> String {
        let supported = airMouse.supportedReferenceFrames.contains(frame)
        return supported ? frame.title : "\(frame.title)（本机不支持）"
    }
}

#Preview {
    VStack(spacing: 0) {
        Spacer()
        AirMousePad().padding(.horizontal, 16)
    }
}
