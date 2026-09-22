import CoreGraphics
import Foundation
import QuartzCore

/// 模拟器 / 无陀螺仪硬件时的激光指针替身。
///
/// 模拟器没有陀螺仪数据（`isDeviceMotionAvailable == false`），如果不做替身，
/// 激光指针在本地**完全无法验证** —— 既调不了光斑大小、拖尾长度这些纯视觉参数，
/// 也看不到空鼠接管光标后的实际观感。这与 `MockExternalDisplay` 的动机一致。
///
/// 这层只在 `-mockAirMouse` 启动参数存在时生效，不参与真机链路。
///
/// ## 它不伪造度量数据
/// 只驱动光标位置。陀螺仪预热 / 可用时间那套指标**一个都不编** ——
/// `CMDeviceMotion` 没有公开构造器，合成不出样本，所以 mock 模式下预热读数全部留空，
/// 由 `MotionWarmupReport.isSynthetic` 在 UI 上明说"无真实读数"。
/// 度量这件事一旦掺进假数据，就没有任何参考价值了。
@MainActor
final class MockAirMouseSource {

    static let shared = MockAirMouseSource()

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-mockAirMouse")
    }

    private var task: Task<Void, Never>?

    private init() {}

    /// 以 60 Hz 输出一条李萨如轨迹，铺满屏幕中段。
    ///
    /// `emit` 标 `@MainActor`：调用方是主线程上的 `Task`，
    /// 而它要写的是主线程隔离的 `RemoteControl`。
    func start(emit: @escaping @MainActor (CGPoint) -> Void) {
        stop()
        task = Task {
            let started = CACurrentMediaTime()
            while !Task.isCancelled {
                let t = CACurrentMediaTime() - started
                // 两个不成整数比的频率，轨迹不会很快重复，看起来"像人手的动作"
                let x = 0.5 + 0.36 * sin(t * 0.90)
                let y = 0.5 + 0.33 * sin(t * 1.37 + 1.1)
                emit(CGPoint(x: x, y: y))
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
