import CoreGraphics
import Foundation
import QuartzCore

/// 模拟器 / 无陀螺仪硬件时的**视角**替身。
///
/// 与 `MockAirMouseSource` 是同一动机的两条岔路：那个驱动激光指针，这个驱动全景视角。
/// 两者都由 `AirMouse` 统一起停，且**互斥** —— 一份物理姿态不可能同时喂两个量
/// （spec §4.3-3 那条行为变更）。
///
/// ## 它发的是"原始姿态读数"，不是角度
/// 这是个刻意的选择。如果直接发 `PanoramaLook`，`RemoteControl.advanceLook` 里那两条
/// 最容易错的逻辑 —— **跨 ±180° 折最短弧**、**环绕而非夹取** —— 就被绕过去了，
/// 而 mock 的全部价值恰恰是让它们能被真跑一遍。所以这里只产生一条
/// "随时间变化、且**会回绕**"的 yaw/pitch 度数流，与 `CMAttitude` 给出的东西同形。
///
/// ⚠️ **roll 不能省**（票 `08`）：横向在这条链上有两个来源（yaw 与 roll），
/// 合成源不发 roll 的话，那条映射在模拟器上永远不被执行 ——
/// "模拟器全绿、真机左右不灵"可以同时成立，而这正是票 `08` 之前的状态。
///
/// 只在 `-mockLook` 启动参数存在时生效，不参与真机链路。
/// 与 `MockAirMouseSource` 一样**不伪造任何度量读数**。
@MainActor
final class MockLookSource {

    static let shared = MockLookSource()

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-mockLook")
    }

    private var task: Task<Void, Never>?

    private init() {}

    /// 以 60 Hz 输出一条往返的原始姿态流。
    ///
    /// - **yaw**：三角波，在 `−200° ~ +200°` 之间来回，周期 12 秒。
    ///   刻意超出 `±180°` —— 于是每次往返都会跨过回绕点，
    ///   "折最短弧"那一步必然被执行到（而它正是真机快速转头时才暴露的那条路径）。
    /// - **pitch**：慢正弦，`±55°`。落在 `maxPitch ≈ 64.6°` 之内，
    ///   好让渲染侧的夹取那一步也有机会被看到，而不是一直贴着边界。
    /// - **roll**：慢正弦，`±60°`，周期约 20 秒（与 yaw 的 12 秒错开，
    ///   于是"两轴同时给"这种组合每隔一段时间必然出现一次）。
    func start(emit: @escaping @MainActor (AttitudeReading) -> Void) {
        stop()
        task = Task {
            let started = CACurrentMediaTime()
            while !Task.isCancelled {
                let t = CACurrentMediaTime() - started

                let phase = (t / 12).truncatingRemainder(dividingBy: 1)
                let ramp = phase < 0.5 ? phase * 2 : (1 - phase) * 2
                let rawYaw = MockLookSource.folded(-200 + 400 * ramp)
                let rawPitch = 55 * sin(t * 0.42)
                let rawRoll = 60 * sin(t * 0.31)

                emit(AttitudeReading(yaw: rawYaw, pitch: rawPitch, roll: rawRoll))
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// 折到 `(−180, 180]` —— 与 `CMAttitude` 的 Tait-Bryan 角同区间。
    ///
    /// 这个"折叠"是 mock 的**关键**：不折的话原始读数一路单调增，
    /// `shortestArc` 每次算出来的都是一个普通的小差值，回绕那条分支永远不会走到。
    static func folded(_ degrees: CGFloat) -> CGFloat {
        let remainder = degrees.truncatingRemainder(dividingBy: 360)
        if remainder > 180 { return remainder - 360 }
        if remainder <= -180 { return remainder + 360 }
        return remainder
    }
}
