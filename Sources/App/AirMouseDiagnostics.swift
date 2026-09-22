import SwiftUI

/// 表单里的空鼠仪表盘 —— 陀螺仪的预热与可用时间读数。
///
/// ## 「可用」是怎么定义的
/// CoreMotion **没有** `isGyroReady` 之类的接口：`isDeviceMotionAvailable`
/// 只回答"这台设备有没有这个硬件"，不回答"现在数据能不能用"。所以这里的里程碑
/// 全部是可观测代理指标（定义与理由见 `MotionWarmupReport`）：
///
/// - **首个样本** = 第一次收到 `CMDeviceMotion` 回调 —— 数据通路真的通了。
/// - **可用时间** = 连续 20 个采样间隔都落在 ±50% 请求间隔内 —— 数据流稳定供给，
///   指针可以开始跟随。这是空鼠"能用"的时刻。
/// - **参考系锁定** = `magneticField.accuracy` 达到 `.medium` 及以上 ——
///   磁力计校准完成，yaw 不再漂移。它**不参与**可用判定：磁干扰环境（金属桌面）
///   可能永远锁不上，那该提示"会漂移"，不该让空鼠不可用。
///
/// 抖动只作质量展示，也**不参与**判定 —— 抖动里混着用户的手抖，
/// 拿它当门限会把"人没拿稳"误判成"传感器没好"。
struct AirMouseDiagnostics: View {

    @Bindable private var airMouse = AirMouse.shared

    var body: some View {
        warmupSection
        streamSection
        directionSection
    }

    // MARK: - 预热与可用时间

    private var warmupSection: some View {
        Section("空鼠 · 预热与可用时间") {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(airMouse.state.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(airMouse.warmup.frame.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let reason = airMouse.state.reason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if airMouse.warmup.isSynthetic {
                Text("当前是 `-mockAirMouse` 合成数据源：只驱动激光指针，下面的预热指标全部无真实读数。要让这些数字有意义，必须在有陀螺仪的真机上跑。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            metric("首个样本", duration(airMouse.warmup.milestones.firstSample), emphasis: false)
            metric("可用时间", duration(airMouse.warmup.milestones.usable), emphasis: true)
            metric("参考系锁定", referenceLockText, emphasis: false)
            metric("磁场校准", airMouse.warmup.magneticAccuracy.title, emphasis: false)

            metric(
                "静态能力",
                "陀螺仪 \(check(airMouse.isGyroAvailable)) · deviceMotion \(check(airMouse.isDeviceMotionAvailable))",
                emphasis: false
            )
            metric("支持的参考系", supportedFramesText, emphasis: false)

            Text("可用时间 = 连续 \(MotionWarmupRecorder.steadyStreakRequired) 个采样间隔稳定；iOS 不暴露陀螺仪「就绪」信号，这是可观测代理指标。测量期间尽量保持静止。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 数据流质量

    private var streamSection: some View {
        Section("空鼠 · 数据流") {
            metric("实测频率", measuredHzText, emphasis: false)
            metric("请求间隔", intervalText(airMouse.warmup.stream.requestedInterval), emphasis: false)
            metric("最大间隔", intervalText(airMouse.warmup.stream.maxGap), emphasis: false)
            metric("掉帧次数", "\(airMouse.warmup.stream.gapCount)", emphasis: false)
            metric("样本总数", "\(airMouse.warmup.stream.sampleCount)", emphasis: false)
            metric("样本年龄", sampleAgeText, emphasis: false)
            metric("抖动峰峰值", jitterText, emphasis: false)
        }
    }

    // MARK: - 方向

    private var directionSection: some View {
        Section("空鼠 · 方向") {
            Toggle("水平反转", isOn: $airMouse.invertHorizontal)
            Toggle("垂直反转", isOn: $airMouse.invertVertical)

            Text("默认按「手机大致平持、顶端朝向眼镜屏」推导，该假设**未在真机验证**。真机上试一下，反了就打开对应开关。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 行

    private func metric(_ label: String, _ value: String, emphasis: Bool) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(emphasis ? .subheadline.monospacedDigit().weight(.semibold) : .subheadline.monospacedDigit())
                .foregroundStyle(emphasis ? Color.accentColor : Color.secondary)
        }
    }

    // MARK: - 文案

    private var statusColor: Color {
        if airMouse.state.isFailure { return .red }
        switch airMouse.state {
        case .tracking: return .green
        case .warming: return .orange
        default: return Color.secondary.opacity(0.4)
        }
    }

    /// 磁力计参考系才有「锁定」可言；纯陀螺仪参考系没有可锁定的东西。
    private var referenceLockText: String {
        guard airMouse.warmup.frame.usesMagnetometer else { return "不适用（纯陀螺仪）" }
        if let locked = airMouse.warmup.milestones.referenceLocked {
            return duration(locked)
        }
        return airMouse.warmup.stream.sampleCount > 0 ? "未锁定" : "—"
    }

    /// 静态能力是不需要启动就能问出来的，所以这一行任何时候都有意义，
    /// 顺带把"当前选中的参考系是否被支持"一起标出来。
    private var supportedFramesText: String {
        let names = airMouse.supportedReferenceFrames.map(\.title)
        guard !names.isEmpty else { return "无" }
        let suffix = airMouse.isSelectedFrameSupported ? "" : "（当前参考系不支持）"
        return names.joined(separator: "、") + suffix
    }

    private var measuredHzText: String {
        let hz = airMouse.warmup.stream.measuredHz
        guard hz > 0 else { return "—" }
        let requested = airMouse.warmup.stream.requestedInterval
        let requestedHz = requested > 0 ? 1 / requested : 0
        return String(format: "%.1f Hz（请求 %.0f）", hz, requestedHz)
    }

    private var sampleAgeText: String {
        if airMouse.warmup.stream.timebaseMatches == false { return "时间基准不一致" }
        guard let age = airMouse.warmup.stream.sampleAge else { return "—" }
        return intervalText(age)
    }

    private var jitterText: String {
        guard airMouse.warmup.stream.sampleCount > 1 else { return "—" }
        let suffix = airMouse.warmup.stream.isStill ? "静止" : "运动中"
        return String(format: "%.2f° · %@", airMouse.warmup.stream.jitterDegrees, suffix)
    }

    private func check(_ value: Bool) -> String { value ? "✓" : "✗" }

    private func duration(_ value: TimeInterval?) -> String {
        guard let value else { return "—" }
        return value < 1
            ? String(format: "%.0f ms", value * 1000)
            : String(format: "%.2f s", value)
    }

    private func intervalText(_ value: TimeInterval) -> String {
        guard value > 0 else { return "—" }
        return String(format: "%.1f ms", value * 1000)
    }
}

#Preview {
    Form {
        AirMouseDiagnostics()
    }
}
