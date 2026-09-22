import Foundation
import Observation

/// 手机端与外接屏共享的内容状态。
///
/// 手机屏与外接屏跑在**同一个进程**里，只是分属不同的 `UIScene`，
/// 所以这里用单例 + `@Observable` 就够了：手机端改属性，外接屏的
/// SwiftUI 视图自动重绘，不需要跨进程/跨 scene 的额外通道。
///
/// 真实项目里若外接屏要渲染视频帧，把这里换成「生产者 → 状态 → 消费者」
/// 的模型即可，接入层（scene + window）完全不用改。
@MainActor
@Observable
final class DisplayContentStore {

    static let shared = DisplayContentStore()

    /// 外接屏上铺底的可视化图案，用来肉眼确认渲染链路真的在跑。
    enum Pattern: String, CaseIterable, Identifiable {
        case gradient
        case grid
        case colorBars

        var id: String { rawValue }

        var title: String {
            switch self {
            case .gradient: "动态渐变"
            case .grid: "网格 + 扫描线"
            case .colorBars: "彩条"
            }
        }
    }

    var pattern: Pattern = .gradient
    /// 关闭后 TimelineView 暂停，外接屏画面静止 —— 用于确认帧驱动是否来自本应用。
    var isAnimated: Bool = true
    var caption: String = "External Display Demo"

    private init() {}
}
