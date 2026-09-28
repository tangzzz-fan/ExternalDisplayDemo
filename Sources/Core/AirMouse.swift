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

    /// 最近一帧的**姿态读数**（度），供外接屏全景页页脚读数用。
    ///
    /// 它是纯展示量：视角由 `RemoteControl.panoramaLook` 持有，本属性不参与任何运算。
    ///
    /// 存在的理由是"手感对不对"这件事必须在眼镜屏上可判读。真机反馈"左右几乎没反应"
    /// 时有两种可能，而它们的修法完全不同：
    /// - **姿态压根没读到**（三个数都不动）⇒ 传感器 / 参考系问题；
    /// - **读到了但没接上映射**（只有 roll 在动）⇒ 映射缺一支（票 `08` 的实际情形）。
    /// 页脚把三个数直接摆出来，一眼就能分开这两件事。
    private(set) var latestReading: AttitudeReading?

    private(set) var isRunning = false

    /// 合成源的「启动参数名 + 它驱动什么」（`nil` = 不是合成源）。
    ///
    /// 两条合成路的动机相同（模拟器没有陀螺仪）、去向不同：
    /// `-mockAirMouse` 喂激光指针，`-mockLook` 喂全景视角。
    /// UI 必须说清是哪一条 —— 写死一个参数名的话，跑着 `-mockLook`
    /// 却显示「当前是 `-mockAirMouse`」会让人以为参数压根没生效。
    var syntheticSourceNote: (name: String, target: String)? {
        guard warmup.isSynthetic else { return nil }
        return MockLookSource.isEnabled
            ? (name: "-mockLook", target: "全景视角")
            : (name: "-mockAirMouse", target: "激光指针")
    }

    /// 参考系。改动在**下次启动**生效（运行中切换需要重启数据流）。
    var referenceFrame: MotionReferenceFrame = .arbitraryCorrectedZVertical

    /// 灵敏度倍率，`1.0` 为基准。放大即减小满屏行程角。
    var sensitivity: Double = 1.0

    /// 水平 / 垂直方向反转。默认值未在真机验证，试了反了就打开。
    ///
    /// **两条链都受它管**：激光指针（`updatePointer`）与全景视角（`updateLook`）。
    /// 两者的方向出自**同一个推导出来的假设**（"手机大致平持、顶端朝向眼镜屏"），
    /// 所以真机上反了必然是同一个原因 —— 拆成两个开关只会让人不知道该翻哪一个。
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

    /// 上一帧的**姿态读数**（三个分量），供折最短弧算增量用。
    ///
    /// **视角是累积量**（见 `PanoramaLook`），所以必须记住上一帧；
    /// 而 `CMAttitude` 的 Tait-Bryan 角会回绕到 ±180°，直接取差值会在跨零点时
    /// 瞬移半圈。折最短弧那一步收在 `PanoramaLook.shortestArc`（只有一份实现）。
    ///
    /// 存整条读数而不是只存 yaw：横向有**两个来源**（yaw 与 roll，见票 `08`），
    /// 两者都要算增量。只存一个的话，第二个来源要么被漏掉、要么得另开一份状态。
    private var lastLookReading: AttitudeReading?

    /// 上一帧是否在全景页。
    ///
    /// 用于在**切页的那一帧**清掉 `lastLookReading`：换了页（或从指针切到视角）之后，
    /// 上一帧那个 yaw 与新的基准不再是同一个参照，拿着它算增量会让画面瞬移一段 ——
    /// 症状是"刚进全景页，画面自己转了一下"。
    private var wasPanoramaDetail = false

    /// 平滑后的归一化落点。
    private var smoothed = CGPoint(x: 0.5, y: 0.5)

    private var sampleTimeout: Task<Void, Never>?
    private var lastReportPublish: CFTimeInterval = 0
    private var lastPublishedPhase: MotionWarmupReport.Phase = .idle

    private init() {}

    // MARK: - 启动 / 停止

    func start() {
        guard !isRunning else { return }

        // 模拟器替身有两条岔路：一条喂激光指针，一条喂全景视角。
        // 与真机一样，两者**互斥** —— 同一份姿态不可能既是指针又是视角。
        if MockLookSource.isEnabled {
            startSyntheticLookSession()
            return
        }

        // 只驱动光标，不伪造任何度量读数。
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
        MockLookSource.shared.stop()

        isRunning = false
        origin = nil
        lastAttitude = nil
        lastLookReading = nil
        latestReading = nil
        wasPanoramaDetail = false
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

    /// `-mockLook`：跳过 CoreMotion，用合成姿态流驱动**全景视角**。
    ///
    /// 与 `-mockAirMouse` 同一动机（模拟器没有陀螺仪），但它刻意走
    /// **完整的读数 → 视角那条路** —— `MockLookSource` 合成的是"原始姿态读数"，
    /// 而不是一个现成的角度。于是「跨 ±180° 不跳」「转满一圈仍自洽」
    /// 这两条最容易错的在这里能被真跑一遍，而不是被绕过。
    ///
    /// 它走的是与真机**同一个** `applyLook(reading:)`，包括符号映射
    /// （`LookInput.reading`）—— 所以合成源里"左右倾"也能转横向，
    /// 那条曾经缺掉的映射在模拟器上同样被执行（票 `08`）。
    private func startSyntheticLookSession() {
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
        lastLookReading = nil

        MockLookSource.shared.start { [weak self] reading in
            self?.applyLook(reading: reading)
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
        // 归零的语义在两条路上都是"回到正前方"，照做即可。
        if warmup.isSynthetic {
            // `-mockLook` 那条路上要归的是视角，不是指针。
            if RemoteControl.shared.isPanoramaDetail {
                lastLookReading = nil
                RemoteControl.shared.recenterLook()
                return
            }
            smoothed = CGPoint(x: 0.5, y: 0.5)
            RemoteControl.shared.movePointer(to: smoothed, source: .airMouse)
            RemoteControl.shared.noteAirMouseEvent("已归零（模拟源）")
            return
        }

        guard let current = lastAttitude?.copy() as? CMAttitude else { return }
        origin = current

        // 全景页里归零的是**视角**：基准换了，`look` 也得回正前方，
        // 否则画面会停在原处、而"正前方"已经换了定义。
        // `lastLookReading` 必须一起清 —— 新的相对基准从 0 开始，
        // 留着旧值会让下一帧算出一个"从旧朝向转过来"的假增量。
        if RemoteControl.shared.isPanoramaDetail {
            lastLookReading = nil
            RemoteControl.shared.recenterLook()
            return
        }

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

        // 一份物理姿态不可能同时干两件事（spec §4.3-3）：全景页里它喂**视角**、
        // 激光让位；其余页面反过来。判据只有 `RemoteControl` 那一个，
        // 与"画哪一页"同源 —— 所以"画的是全景、动的却是指针"不可能发生。
        let isPanorama = RemoteControl.shared.isPanoramaDetail
        if isPanorama != wasPanoramaDetail {
            wasPanoramaDetail = isPanorama
            lastLookReading = nil
        }

        if isPanorama {
            updateLook(with: data.attitude)
        } else {
            updatePointer(with: data.attitude)
        }
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

    // MARK: - 姿态 → 视角

    /// 姿态 → 全景视角。
    ///
    /// 与 `updatePointer` **互斥**（同一份姿态不可能喂两个量），但两者的性质不同：
    /// 指针要的是"现在指向哪"（一帧绝对映射就够），视角要的是"**总共**转过多少"
    /// （必须逐帧累积，见 `PanoramaLook`）—— 所以这里不能照抄 `updatePointer` 那套。
    ///
    /// 用 `multiply(byInverseOf: origin)` 的相对量、而不是原始读数：
    /// 两者对**增量**是等价的，但相对量天然不带"拿起手机时的握持角度"这个偏移，
    /// 于是 `recenter()` 的语义（把当前朝向定为正前方）对视角同样成立。
    ///
    /// 符号：三支的推导收在 `LookInput.reading`（那是本链唯一靠推导而非靠试的地方，
    /// 也必须是唯一一份实现）。这里只负责把 `CMAttitude` 的相对量喂进去。
    /// ⚠️ 那套推导**未在真机验证过**（模拟器没有陀螺仪）—— 真机上手若发现左右/上下反了，
    /// 打开 `invertHorizontal` / `invertVertical` 即可，不必改代码；
    /// 两个开关同时管 yaw 与 roll（横向是一个概念，见 `LookInput.reading`）。
    private func updateLook(with attitude: CMAttitude) {
        guard let origin else {
            self.origin = attitude.copy() as? CMAttitude
            lastLookReading = nil
            return
        }
        guard let relative = attitude.copy() as? CMAttitude else { return }
        relative.multiply(byInverseOf: origin)

        applyLook(
            reading: LookInput.reading(
                fromRelativeYaw: relative.yaw,
                pitch: relative.pitch,
                roll: relative.roll,
                invertHorizontal: invertHorizontal,
                invertVertical: invertVertical
            )
        )
    }

    /// 一帧姿态读数 → 视角。真机（`updateLook`）与合成源（`-mockLook`）共用这一处。
    ///
    /// 收成一个入口是为了让**首帧基准**与**累积**各只有一份实现：
    /// 少了它，合成源那条路得自己写一遍 `lastLookReading ?? raw`，
    /// 于是"进页面第一帧不许据此算出假增量"这条规矩就有了两份，迟早只改一处。
    private func applyLook(reading: AttitudeReading) {
        latestReading = reading
        RemoteControl.shared.advanceLook(from: lastLookReading ?? reading, to: reading)
        lastLookReading = reading
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
