import CoreMotion
import Foundation
import Observation
import QuartzCore

/// 激光空鼠：用手机姿态驱动眼镜屏上的激光指针。
///
/// ## 为什么需要它
/// 外接屏的 role 是 `windowExternalDisplayNonInteractive`，系统不向它投递任何触摸，
/// 所以"在眼镜屏上操作"只有两条路：
/// - 把手机屏当触控板（`RemoteControlPad`，已实现）；
/// - 把手机当空鼠 —— 抬手转动手腕移动指针，用扳机确认。本类就是这条。
///
/// 两者不冲突：谁在动谁就接管光标，`RemoteControl.pointerSource` 记录当前归属，
/// 外接屏据此换渲染样式（触控板画环形光标，空鼠画激光）。
///
/// ## 姿态 → 指针的映射
/// 参考系固定为 Z 轴垂直（`MotionReferenceFrame`），于是 `CMAttitude` 的
/// Tait-Bryan 角正好对得上"指向"这件事 —— `CMAttitude.h` 的定义：
/// `yaw` 绕 z 轴（= 垂直轴，水平面内的指向），`pitch` 绕 x 轴（= 俯仰）。
/// 所以：
///
/// ```
/// x = 0.5 - yawΔ / sweep      // 指向右 → yaw 减小 → x 增大
/// y = 0.5 - pitchΔ / sweep    // 指向下 → pitch 减小 → y 增大（屏幕 y 向下）
/// ```
///
/// **符号依赖持握姿态**：默认假设「手机大致平持、顶端朝向眼镜屏」。
/// 换成竖持当激光笔用，水平方向可能反直觉 —— 所以留了 `invertHorizontal` /
/// `invertVertical`，真机上试一下就顺手纠正，不必改代码。
/// 这两个开关的默认值**未在真机验证过**（本机无陀螺仪数据，见 `warmup`）。
///
/// ## 相对姿态而非绝对
/// `CMAttitude.multiplyByInverseOfAttitude(_:)`（SDK 原文："gives the attitude change
/// from the specified attitude"）拿到相对归零基准的旋转量。必须走相对：
/// `ZVertical` 参考系的 X 轴方向本身是**任意**的，绝对角度没有物理意义；
/// 而且陀螺仪积分出的 yaw 会缓慢漂移，只能靠反复归零消除。
@MainActor
@Observable
final class AirMouse {

    static let shared = AirMouse()

    // MARK: - 可调参数

    /// 光标走完全屏所需的偏航/俯仰角（度）。越小越灵敏。
    static let degreesForFullSweep: Double = 34

    /// 平滑时间常数（秒）。低通滤波的 α 由它推出，与采样率无关。
    /// 太小会抖，太大会"粘手"。
    static let smoothingTimeConstant: Double = 0.055

    /// 请求的采样间隔（60 Hz）。
    static let updateInterval: TimeInterval = 1.0 / 60.0

    /// 预热报告最多多久刷新一次 UI。姿态是 60 Hz，但报告全是文本，
    /// 按 60 Hz 重刷表单纯属浪费。
    private static let reportPublishInterval: TimeInterval = 0.25

    // MARK: - 可观察状态

    /// 与 `warmup.phase` 同步的当前相位。
    private(set) var state: MotionWarmupReport.Phase = .idle

    /// 陀螺仪的可用性与预热耗时读数。
    private(set) var warmup = MotionWarmupReport()

    private(set) var isRunning = false

    /// 参考系。改动在**下次启动**生效（运行中切换需要重启数据流）。
    var referenceFrame: MotionReferenceFrame = .arbitraryCorrectedZVertical

    /// 灵敏度倍率，`1.0` 为基准。放大即减小满屏行程角。
    var sensitivity: Double = 1.0

    /// 水平 / 垂直方向反转。默认值未在真机验证，试了反了就打开。
    var invertHorizontal = false
    var invertVertical = false

    /// 扳机按下次数。
    private(set) var triggerCount = 0

    // MARK: - 静态能力（不需要启动就能问）

    /// 设备是否有陀螺仪。
    var isGyroAvailable: Bool { motionManager.isGyroAvailable }

    /// 设备是否支持 deviceMotion 融合。
    var isDeviceMotionAvailable: Bool { motionManager.isDeviceMotionAvailable }

    /// 本机支持的参考系。
    var supportedReferenceFrames: [MotionReferenceFrame] { Self.supportedFrames() }

    /// 当前选中的参考系是否被本机支持。
    var isSelectedFrameSupported: Bool { supportedReferenceFrames.contains(referenceFrame) }

    // MARK: - 内部

    private let motionManager = CMMotionManager()
    private let recorder = MotionWarmupRecorder()

    /// 归零基准姿态。
    private var origin: CMAttitude?
    /// 最近一次姿态的副本。`CMDeviceMotion.attitude` 是复用对象，必须 copy 后再持有。
    private var lastAttitude: CMAttitude?

    /// 平滑后的归一化落点。
    private var smoothed = CGPoint(x: 0.5, y: 0.5)

    private var sampleTimeout: Task<Void, Never>?
    private var lastReportPublish: CFTimeInterval = 0
    private var lastPublishedPhase: MotionWarmupReport.Phase = .idle

    private init() {}

    // MARK: - 启动 / 停止

    func start() {
        guard !isRunning else { return }

        // 模拟器替身：只驱动光标，不伪造任何度量读数。
        if MockAirMouseSource.isEnabled {
            startSyntheticSession()
            return
        }

        let frame = referenceFrame
        let availableFrames = supportedReferenceFrames

        recorder.begin(frame: frame, requestedInterval: Self.updateInterval)

        // 静态能力这道门先过：不通过就直接给结论，不必等预热。
        guard isDeviceMotionAvailable else {
            recorder.markUnavailable("设备不支持 deviceMotion。模拟器没有陀螺仪数据，需要在真机上跑。")
            syncFromRecorder(force: true)
            return
        }
        guard isGyroAvailable else {
            recorder.markUnavailable("设备没有陀螺仪。")
            syncFromRecorder(force: true)
            return
        }
        guard availableFrames.contains(frame) else {
            let names = availableFrames.map(\.title).joined(separator: "、")
            recorder.markUnavailable("本机不支持参考系「\(frame.title)」。可用：\(names.isEmpty ? "无" : names)")
            syncFromRecorder(force: true)
            return
        }

        motionManager.deviceMotionUpdateInterval = Self.updateInterval
        // 磁力计参考系下打开系统自带的"请晃动设备校准"提示。
        // 这是 Apple 提供的校准入口，能实打实缩短参考系预热时间。
        motionManager.showsDeviceMovementDisplay = frame.usesMagnetometer

        origin = nil
        lastAttitude = nil
        smoothed = CGPoint(x: 0.5, y: 0.5)
        isRunning = true

        motionManager.startDeviceMotionUpdates(using: frame.cmFrame, to: .main) { [weak self] data, error in
            // 队列是 .main，主线程保证成立；用 assumeIsolated 避免为每个样本
            // 生成一个 Task（60 Hz 下会造成不必要的调度与乱序）。
            MainActor.assumeIsolated {
                self?.handle(data, error: error)
            }
        }

        scheduleSampleTimeout()
        syncFromRecorder(force: true)
    }

    func stop() {
        sampleTimeout?.cancel()
        sampleTimeout = nil
        motionManager.stopDeviceMotionUpdates()
        motionManager.showsDeviceMovementDisplay = false
        MockAirMouseSource.shared.stop()

        isRunning = false
        origin = nil
        lastAttitude = nil
        RemoteControl.shared.clearPointer()

        if warmup.isSynthetic {
            // 合成源压根没经过 recorder，自己收尾；
            // 走 syncFromRecorder 会被那份空报告盖掉来源标记。
            warmup.phase = .stopped
            state = .stopped
            lastPublishedPhase = .stopped
            lastReportPublish = CACurrentMediaTime()
            return
        }

        recorder.markStopped()
        syncFromRecorder(force: true)
    }

    /// `-mockAirMouse`：跳过 CoreMotion，用合成轨迹驱动激光指针。
    ///
    /// 刻意不填任何里程碑：`CMDeviceMotion` 没有公开构造器，合成不出样本，
    /// 预热读数就只能是空的 —— 与其编一个像模像样的数字，不如让 UI 明说没有。
    private func startSyntheticSession() {
        var report = MotionWarmupReport()
        report.frame = referenceFrame
        report.isSynthetic = true
        report.phase = .tracking
        report.stream.requestedInterval = Self.updateInterval

        warmup = report
        state = .tracking
        lastPublishedPhase = .tracking
        lastReportPublish = CACurrentMediaTime()
        isRunning = true

        MockAirMouseSource.shared.start { point in
            RemoteControl.shared.movePointer(to: point, source: .airMouse)
        }
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    // MARK: - 归零 / 扳机

    /// 把当前指向重设为屏幕中心。
    ///
    /// 陀螺仪积分的 yaw 会漂移，且 `ZVertical` 参考系的水平零点本来就是任意的，
    /// 所以归零是常规操作而不是异常处理 —— 真机遥控器都把它做成一个按钮。
    func recenter() {
        guard isRunning else { return }

        // 合成源没有 `origin` 可重设（它压根不读姿态），但按钮不该是个哑巴 ——
        // 归零的语义在两条路上都是"把光标拉回屏幕中心"，照做即可。
        if warmup.isSynthetic {
            smoothed = CGPoint(x: 0.5, y: 0.5)
            RemoteControl.shared.movePointer(to: smoothed, source: .airMouse)
            RemoteControl.shared.noteAirMouseEvent("已归零（模拟源）")
            return
        }

        guard let current = lastAttitude?.copy() as? CMAttitude else { return }
        origin = current
        smoothed = CGPoint(x: 0.5, y: 0.5)
        RemoteControl.shared.movePointer(to: smoothed, source: .airMouse)
        RemoteControl.shared.noteAirMouseEvent("已归零")
    }

    /// 扳机：在光标当前位置触发一次轻点。
    func trigger() {
        guard isRunning else { return }
        triggerCount += 1
        RemoteControl.shared.tap()
    }

    // MARK: - 采样

    private func handle(_ data: CMDeviceMotion?, error: Error?) {
        if let error {
            // 只有"一个样本都没收到"才算启动失败；中途偶发错误不该掀掉整个会话。
            if recorder.report.stream.sampleCount == 0 {
                sampleTimeout?.cancel()
                sampleTimeout = nil
                motionManager.stopDeviceMotionUpdates()
                isRunning = false
                recorder.markUnavailable("CoreMotion 报错：\(error.localizedDescription)")
                syncFromRecorder(force: true)
            }
            return
        }
        guard let data else { return }

        sampleTimeout?.cancel()
        sampleTimeout = nil

        recorder.ingest(data)
        lastAttitude = data.attitude.copy() as? CMAttitude
        updatePointer(with: data.attitude)
        syncFromRecorder(force: false)
    }

    private func scheduleSampleTimeout() {
        sampleTimeout?.cancel()
        sampleTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MotionWarmupReport.startTimeout))
            guard !Task.isCancelled, let self else { return }
            self.recorder.markNoSamples()
            self.syncFromRecorder(force: true)
        }
    }

    // MARK: - 姿态 → 指针

    private func updatePointer(with attitude: CMAttitude) {
        // 归零基准：第一个样本即原点
        guard let origin else {
            self.origin = attitude.copy() as? CMAttitude
            RemoteControl.shared.movePointer(to: smoothed, source: .airMouse)
            return
        }
        guard let relative = attitude.copy() as? CMAttitude else { return }
        // Swift 名：multiply(byInverseOf:)，比 ObjC 的 multiplyByInverseOfAttitude: 短。
        relative.multiply(byInverseOf: origin)

        let sweep = Self.degreesForFullSweep / max(sensitivity, 0.05)
        let yawDegrees = relative.yaw * 180 / .pi
        let pitchDegrees = relative.pitch * 180 / .pi

        // 符号约定见类型文档。默认：指向右 → yaw 减小 → x 增大。
        let target = CGPoint(
            x: Self.clamp(0.5 - CGFloat(yawDegrees / sweep) * (invertHorizontal ? -1 : 1)),
            y: Self.clamp(0.5 - CGFloat(pitchDegrees / sweep) * (invertVertical ? -1 : 1))
        )

        // 与采样率无关的低通：α = 1 - e^(-dt/τ)
        let alpha = 1 - exp(-Self.updateInterval / Self.smoothingTimeConstant)
        smoothed.x += (target.x - smoothed.x) * alpha
        smoothed.y += (target.y - smoothed.y) * alpha

        RemoteControl.shared.movePointer(to: smoothed, source: .airMouse)
    }

    // MARK: - 报告同步

    /// 把 recorder 的报告搬到可观察属性上。
    ///
    /// - Parameter force: 里程碑 / 相位变化时必须立即刷，其余按 `reportPublishInterval` 节流。
    private func syncFromRecorder(force: Bool) {
        let phase = recorder.report.phase
        let phaseChanged = phase != lastPublishedPhase

        if phaseChanged || force {
            state = phase
            warmup = recorder.report
            lastPublishedPhase = phase
            lastReportPublish = CACurrentMediaTime()
            return
        }

        let now = CACurrentMediaTime()
        guard now - lastReportPublish >= Self.reportPublishInterval else { return }
        warmup = recorder.report
        lastReportPublish = now
    }

    // MARK: - Helpers

    /// 本机支持哪些参考系。`availableAttitudeReferenceFrames()` 是 iOS 5+ 的类方法。
    static func supportedFrames() -> [MotionReferenceFrame] {
        let mask = CMMotionManager.availableAttitudeReferenceFrames()
        return MotionReferenceFrame.allCases.filter { mask.contains($0.cmFrame) }
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}
