import CoreMotion
import Foundation
import QuartzCore

// MARK: - 参考系

/// 陀螺仪参考系。
///
/// `CMAttitudeReferenceFrame` 是 `NS_OPTIONS`（OptionSet），不能直接喂给 `Picker`，
/// 这里包一层可遍历的枚举。三个候选的物理含义来自 SDK 头文件 `CMAttitude.h`：
///
/// > `XArbitraryZVertical` — Z 轴垂直、X 轴指向水平面内任意方向。
/// > `XArbitraryCorrectedZVertical` — 同上，但**当磁力计可用且已校准时**，
/// > 用磁力计修正 yaw 的累积误差。
/// > `XMagneticNorthZVertical` — Z 轴垂直、X 轴指向磁北；
/// > **使用该参考系可能需要移动设备来校准磁力计**。
enum MotionReferenceFrame: String, CaseIterable, Identifiable {

    /// 陀螺仪 + 加速度计融合。不碰磁力计 —— 启动即有数据，代价是 yaw 缓慢漂移。
    case arbitraryZVertical
    /// 同上，磁力计可用且已校准时参与修正 yaw 漂移。默认选它。
    case arbitraryCorrectedZVertical
    /// x 轴指向磁北。最"绝对"，但预热最久（要先校准磁力计）。
    case magneticNorthZVertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arbitraryZVertical: "陀螺仪（Z 垂直）"
        case .arbitraryCorrectedZVertical: "陀螺仪 + 磁修正"
        case .magneticNorthZVertical: "磁北（Z 垂直）"
        }
    }

    var detail: String {
        switch self {
        case .arbitraryZVertical: "启动最快，yaw 会缓慢漂移"
        case .arbitraryCorrectedZVertical: "等磁力计校准后修正漂移"
        case .magneticNorthZVertical: "需晃动设备校准磁力计，预热最久"
        }
    }

    var cmFrame: CMAttitudeReferenceFrame {
        switch self {
        case .arbitraryZVertical: .xArbitraryZVertical
        case .arbitraryCorrectedZVertical: .xArbitraryCorrectedZVertical
        case .magneticNorthZVertical: .xMagneticNorthZVertical
        }
    }

    /// 该参考系是否依赖磁力计。
    ///
    /// 决定「参考系锁定」这一里程碑对它是否有意义：
    /// 纯陀螺仪参考系没有可锁定的东西，该项恒为「不适用」。
    var usesMagnetometer: Bool {
        switch self {
        case .arbitraryZVertical: false
        case .arbitraryCorrectedZVertical, .magneticNorthZVertical: true
        }
    }
}

// MARK: - 报告

/// 一次空鼠会话里陀螺仪的可用性与预热耗时。
///
/// ## iOS 不暴露「陀螺仪就绪」信号
/// CoreMotion 没有 `isGyroReady` 之类的 API。`isGyroAvailable` /
/// `isDeviceMotionAvailable` 只回答「这台设备有没有这个硬件」，不回答
/// 「现在数据能不能用」。所以下面两个里程碑是用**可观测代理**定义的：
///
/// | 里程碑 | 判据 | 含义 |
/// | --- | --- | --- |
/// | 首个样本 | 第一次收到 `CMDeviceMotion` 回调 | 数据通路真的通了 |
/// | **可用** | 连续 20 个采样间隔都落在 ±50% 请求间隔内 | 数据流已稳定供给，指针可以开始跟随 |
/// | 参考系锁定 | `magneticField.accuracy` ≥ `.medium` | 磁力计校准完成，yaw 不再漂移（仅磁力计参考系有） |
///
/// 之所以把「可用」定义在**采样节奏**而不是「姿态抖动」上：抖动里混着用户的手抖，
/// 用它当门限会把「人没拿稳」误判成「传感器没好」。抖动只作为质量指标展示。
/// 同理，「参考系锁定」不参与「可用」判定 —— 磁力计可能永远校准不到 `.medium`
/// （金属桌面、磁干扰环境），那不该导致空鼠不可用，只该提示会漂移。
struct MotionWarmupReport: Equatable {

    enum Phase: Equatable {
        case idle
        /// 静态能力不足（无硬件 / 参考系不支持），携带原因文案。
        case unavailable(String)
        /// 已开始收数据，尚未判定为可用。
        case warming
        /// 数据流已稳定，空鼠可工作。
        case tracking
        /// 超过 `startTimeout` 没收到任何样本 —— 模拟器上就是这种情况。
        case noSamples
        case stopped
    }

    /// 相对 `startDeviceMotionUpdates` 调用时刻的耗时（秒）。
    struct Milestones: Equatable {
        var firstSample: TimeInterval?
        /// 「可用」时刻。
        var usable: TimeInterval?
        /// 磁力计校准完成时刻（仅磁力计参考系）。
        var referenceLocked: TimeInterval?
    }

    /// 数据流的实测质量。
    struct Stream: Equatable {
        var sampleCount = 0
        var requestedInterval: TimeInterval = 0
        var measuredHz: Double = 0
        var maxGap: TimeInterval = 0
        /// 间隔超过 1.5× 请求间隔的次数（掉帧 / 供给抖动）。
        var gapCount = 0
        /// 最近样本年龄：`now - motion.timestamp`。
        var sampleAge: TimeInterval?
        /// 样本时间戳与本地单调时钟是否同基准。`nil` = 还没有样本可判。
        /// 不同基准时 `sampleAge` 无意义，置 `nil` 而不是显示垃圾数。
        var timebaseMatches: Bool?
        /// 最近窗口内 yaw/pitch 的峰峰值（度）。静止时趋近 0，反映传感器噪声 + 手抖。
        var jitterDegrees: Double = 0
        /// 是否处于静止（抖动低于阈值）。仅作展示，不参与「可用」判定。
        var isStill = false
    }

    var phase: Phase = .idle
    var frame: MotionReferenceFrame = .arbitraryCorrectedZVertical

    /// 数据来自 `-mockAirMouse` 的合成源而非真实陀螺仪。
    ///
    /// 为真时所有里程碑与数据流指标都**没有意义**，UI 必须明说，
    /// 不能让空着的读数和"还没预热好"混为一谈。
    var isSynthetic = false

    var milestones = Milestones()
    var stream = Stream()
    var magneticAccuracy: MagneticAccuracy = .uncalibrated

    /// 超过这个时长没收到第一个样本就判 `noSamples`。
    static let startTimeout: TimeInterval = 1.5
}

extension MotionWarmupReport.Phase {

    /// 短语状态，UI 直接显示。
    var title: String {
        switch self {
        case .idle: "未启动"
        case .unavailable: "不可用"
        case .warming: "预热中"
        case .tracking: "可用"
        case .noSamples: "无数据"
        case .stopped: "已停止"
        }
    }

    /// `unavailable` 携带的原因文案。
    var reason: String? {
        if case .unavailable(let text) = self { return text }
        return nil
    }

    /// 是否属于"跑不起来"一类 —— UI 用警示色强调。
    var isFailure: Bool {
        switch self {
        case .unavailable, .noSamples: true
        default: false
        }
    }
}

/// `CMMagneticFieldCalibrationAccuracy` 的可显示包装。
///
/// 直接用 C 枚举也能读，但 `Picker` / `Text` 需要 `CaseIterable` 与文案，
/// 且原始类型是 `Int32`，包一层省掉到处写 `rawValue` 比较。
enum MagneticAccuracy: Int, CaseIterable, Identifiable, Equatable {
    case uncalibrated = -1
    case low = 0
    case medium = 1
    case high = 2

    var id: Int { rawValue }

    init(_ value: CMMagneticFieldCalibrationAccuracy) {
        self = MagneticAccuracy(rawValue: Int(value.rawValue)) ?? .uncalibrated
    }

    var title: String {
        switch self {
        case .uncalibrated: "未校准"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        }
    }

    /// ≥ `.medium` 视为参考系已锁定。
    var isLocked: Bool { self == .medium || self == .high }
}

// MARK: - 记录器

/// 陀螺仪预热与可用时间的度量。
///
/// 只做度量，不做控制 —— 数据来自 `AirMouse` 的采样回调，报告被 UI 直接读。
@MainActor
final class MotionWarmupRecorder {

    /// 判定「数据流已稳定」所需的连续正常间隔数。
    static let steadyStreakRequired = 20
    /// 采样间隔容差：落在 `(1 ± 0.5) × 请求间隔` 内视为正常。
    static let intervalTolerance = 0.5
    /// 抖动统计的滑动窗口长度（样本数）。
    static let jitterWindow = 24
    /// 静止判据：窗口内 yaw/pitch 峰峰值低于此值（度）。
    static let stillnessThresholdDegrees = 1.2

    private(set) var report = MotionWarmupReport()

    private var startUptime: CFTimeInterval?
    private var firstSampleUptime: CFTimeInterval?
    private var lastSampleUptime: CFTimeInterval?
    private var steadyStreak = 0

    /// 累计偏航 / 俯仰（度）。用累计值而不是瞬时值，避免 ±180° 换界把抖动算爆。
    private var accumulatedYaw: Double = 0
    private var accumulatedPitch: Double = 0
    private var anchorYaw: Double?
    private var anchorPitch: Double?
    private var yawWindow: [Double] = []
    private var pitchWindow: [Double] = []

    // MARK: - 生命周期

    /// 启动前调用：`startUptime` 就是「请求开始」的时刻，之后所有里程碑都以它为原点。
    ///
    /// 静态能力（有没有陀螺仪、支持哪些参考系）**不在这里** ——
    /// 那些不需要启动就能问出来，属于 `AirMouse` 的实时查询，不属于「测出来的报告」。
    func begin(frame: MotionReferenceFrame, requestedInterval: TimeInterval) {
        report = MotionWarmupReport()
        report.frame = frame
        report.stream.requestedInterval = requestedInterval
        report.phase = .warming

        startUptime = CACurrentMediaTime()
        firstSampleUptime = nil
        lastSampleUptime = nil
        steadyStreak = 0
        accumulatedYaw = 0
        accumulatedPitch = 0
        anchorYaw = nil
        anchorPitch = nil
        yawWindow.removeAll()
        pitchWindow.removeAll()
    }

    /// 静态能力检查就没过 —— 直接把原因写进报告，不进 warming。
    func markUnavailable(_ reason: String) {
        report.phase = .unavailable(reason)
        startUptime = nil
    }

    /// 收到一个样本。
    func ingest(_ motion: CMDeviceMotion) {
        let now = CACurrentMediaTime()
        report.stream.sampleCount += 1
        report.magneticAccuracy = MagneticAccuracy(motion.magneticField.accuracy)

        // 首个样本：数据通路确认通了
        if firstSampleUptime == nil {
            firstSampleUptime = now
            if let start = startUptime {
                report.milestones.firstSample = now - start
            }
        }

        // 采样节奏：首个样本之后才有间隔可言
        if let last = lastSampleUptime {
            let interval = now - last
            report.stream.maxGap = max(report.stream.maxGap, interval)

            let requested = report.stream.requestedInterval
            let tolerated = requested * Self.intervalTolerance
            if abs(interval - requested) <= tolerated {
                steadyStreak += 1
                if steadyStreak == Self.steadyStreakRequired, report.milestones.usable == nil {
                    // 「可用」= 连续 N 个间隔稳定在容差内
                    report.milestones.usable = now - (startUptime ?? now)
                }
            } else {
                if interval > requested * 1.5 { report.stream.gapCount += 1 }
                steadyStreak = 0
            }

            if let first = firstSampleUptime {
                let elapsed = now - first
                if elapsed > 0 {
                    report.stream.measuredHz = Double(report.stream.sampleCount - 1) / elapsed
                }
            }
        }
        lastSampleUptime = now

        // 样本年龄：验证 motion.timestamp 与本地单调时钟是否同基准。
        // 不同基准时宁可显示「—」，也不要把无意义的数摆到界面上。
        if report.stream.timebaseMatches == nil {
            let age = now - motion.timestamp
            report.stream.timebaseMatches = (age >= 0 && age < 2)
        }
        if report.stream.timebaseMatches == true {
            report.stream.sampleAge = max(0, now - motion.timestamp)
        }

        // 参考系锁定
        if report.frame.usesMagnetometer,
           report.milestones.referenceLocked == nil,
           report.magneticAccuracy.isLocked,
           let start = startUptime {
            report.milestones.referenceLocked = now - start
        }

        updateJitter(with: motion.attitude)

        // 状态推进：usable 一到就进 tracking
        if report.milestones.usable != nil, report.phase == .warming {
            report.phase = .tracking
        }
    }

    /// 超时未收到任何样本（模拟器没有陀螺仪数据时就是这样）。
    func markNoSamples() {
        guard report.stream.sampleCount == 0, report.phase == .warming else { return }
        report.phase = .noSamples
    }

    func markStopped() {
        // 保留报告内容供回看，只把相位改掉。
        if case .unavailable = report.phase { return }
        report.phase = .stopped
        startUptime = nil
    }

    // MARK: - 抖动

    private func updateJitter(with attitude: CMAttitude) {
        let yaw = attitude.yaw * 180 / .pi
        let pitch = attitude.pitch * 180 / .pi

        // 累计角度：只加最短弧差，避免换界跳变
        if let anchor = anchorYaw {
            accumulatedYaw += Self.shortestDelta(from: anchor, to: yaw)
        }
        if let anchor = anchorPitch {
            accumulatedPitch += Self.shortestDelta(from: anchor, to: pitch)
        }
        anchorYaw = yaw
        anchorPitch = pitch

        yawWindow.append(accumulatedYaw)
        pitchWindow.append(accumulatedPitch)
        if yawWindow.count > Self.jitterWindow {
            yawWindow.removeFirst()
            pitchWindow.removeFirst()
        }

        guard yawWindow.count >= 2 else { return }
        let yawSpan = (yawWindow.max() ?? 0) - (yawWindow.min() ?? 0)
        let pitchSpan = (pitchWindow.max() ?? 0) - (pitchWindow.min() ?? 0)
        report.stream.jitterDegrees = max(yawSpan, pitchSpan)
        report.stream.isStill = report.stream.jitterDegrees < Self.stillnessThresholdDegrees
    }

    /// 两角之间的最短弧差，落在 `(-180, 180]`。
    private static func shortestDelta(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta <= -180 { delta += 360 }
        return delta
    }
}
