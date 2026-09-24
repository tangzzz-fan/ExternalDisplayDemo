import Foundation

/// 把一串连续的轻点翻译成「单点」或「双击」。
///
/// ## 为什么单独抽成一个类型
/// 双击天然是一个**跨会话**的判定：第一次轻点与第二次轻点分属两次
/// 「按下 → 抬起」，中间隔着一次完整的状态机复位。`PadGesture` 每次会话
/// 结束都会 `reset()` 清空自己的全部状态，时间戳留在那里会被一起清掉；
/// 而留在视图里又完全无法断言 —— `simctl` 没有触摸注入 API，
/// 本项目里"能脚本化验证"是硬指标。
///
/// 所以它是一个独立的纯值类型：**只吃时间**，不认识 UIKit / SwiftUI / 触控面。
///
/// ## 为什么判定点在 `RemoteControl`，而不是手势层
/// 「确认」这个动作在本工程里有**三条**入口，它们最终都汇聚到
/// `RemoteControl.tap()`：
///
/// - 触控板 / 空鼠栏的轻点（`PadGesture` → `.tap`）；
/// - 空鼠的「扳机」按钮（`AirMouse.trigger()`）；
/// - 触控板面板上的「轻点」兜底按钮。
///
/// 判定若放在手势层，后两条路就永远双击不起来 —— 而空鼠用户快速按两下扳机
/// 恰恰是最自然的"放大"手势。放在汇聚点上，三条路自动获得同一种行为。
struct TapSequence {

    /// 两次轻点被算作双击的最长间隔（秒）。
    ///
    /// `0.32` 与 `UITouch.tapCount` 的判定窗口同量级。再长会把
    /// "点一下、停一下、再点一下"误判成双击；再短则双击难以触发 ——
    /// 尤其在举起手机瞄准（空鼠姿态）时，手指不那么稳。
    static let doubleTapMaxInterval: TimeInterval = 0.32

    /// 一次轻点的判定结果。
    enum Result: Equatable {

        /// 独立的一次轻点，或一个双击序列的第一击。
        case single

        /// 与上一次轻点构成了双击。**本次不再计为 `single`。**
        case double
    }

    /// 上一次轻点的时间；`nil` 表示当前没有待配对的点击。
    private var pendingTapTime: Date?

    init() {}

    /// 登记一次轻点。
    ///
    /// 双击成立时会把待配对状态**清空**，因此连击三下得到的是
    /// 「单点、双击」而不是「单点、双击、双击」—— 否则一次三连击会连续
    /// 切换两次查看模式，等于什么都没做。
    mutating func registerTap(at time: Date) -> Result {
        if let pending = pendingTapTime {
            let interval = time.timeIntervalSince(pending)
            // 上界之外还要挡住负间隔：时间源被调整（系统校时、时区变更）时
            // `time` 可能早于上一次记录，那时它不该被当成一次"极短的双击"。
            if interval >= 0, interval <= Self.doubleTapMaxInterval {
                pendingTapTime = nil
                return .double
            }
        }

        pendingTapTime = time
        return .single
    }
}
