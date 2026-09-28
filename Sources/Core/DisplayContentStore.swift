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

    /// 幕墙的内容筛选档。
    ///
    /// ## 为什么归这里，而不是 `RemoteControl`
    /// `RemoteControl` 管"怎么看"（滚动 / 缩放 / 光标），本类管"显示什么"
    /// （图案、标题、动画）。筛选改的是**内容集合**，属于后者。
    ///
    /// 这个归属还有一条可观测的后果：切筛选**不碰任何视口状态**，
    /// 于是 `RemoteControl.position` 在筛选前后原样不动 ——
    /// 关掉筛选回到原样、滚动位置不跳，就是靠这一条成立的。
    var filter: PanoramaFilter = .all

    /// 全景详情页用哪一套纹理：程序化网格，还是 `Scripts/fetch-panorama-assets.sh`
    /// 取回的真实素材。
    ///
    /// ## 为什么它从"启动期常量"升成了内容状态
    /// 原先它是 `MockPanoramaAsset.source` —— 只有命令行能改的一个常量。
    /// 素材条（票 `07`）要求**点哪条看哪条**，而默认档是网格：不把它升成可写的
    /// 状态，用户点了一条缩略图是真照片的素材、进去看到的却是网格，
    /// 两张东西对不上，最自然的解读是"点错了素材"。升上来之后，
    /// 「点素材条 ⇒ 看真实素材」才是一行成立的行为。
    ///
    /// 它归这里而不归 `RemoteControl`：那个管"怎么看"（滚动 / 缩放 / 光标），
    /// 本类管"显示什么"。一次点击改的是**画什么纹理**，与 `filter` 同一个归属 ——
    /// 于是它也顺带保证了"改它不碰任何视口状态"。
    ///
    /// 初值由入口从 `-panoramaAsset` 写入（缺省 `.grid`）。截图判读路径
    /// （`pano=` / `detail=`）**不碰**它，所以「网格是几何主判据」那条纪律不受影响。
    var panoramaSource: PanoramaAssetSource = .grid

    /// 动画纹理的**冻结相位**（`0..<1`）；`nil` = 跟着显示刷新逐帧推进。
    ///
    /// ## 为什么需要一个"冻结"的口子
    /// 动画帧源（票 `05`）默认挂在 `TimelineView(.animation)` 上 —— 它取的是
    /// 挂钟时间，两次启动落在不同的相位 ⇒ **截图基线不可复现**。
    /// 而这一档要证的恰恰是"两张不同时刻的截图，几何线在同一处"，
    /// 没有可复现的相位就退化成"看着像"。
    ///
    /// 所以：给了值就静止在那个相位（截图路径走这条），
    /// 不给就是真动画（人看的那条）。这与 `isAnimated` 是**两个正交的开关** ——
    /// 那个管"整块屏要不要动"，这个管"动到哪一帧停住"。
    ///
    /// 超过 `[0, 1)` 的值由绘制侧折回，这里不做夹取 ——
    /// 折的是环上的相位，夹取会让 0.98 与 0.02 变成两个相邻的极端。
    var panoramaPhase: Double?

    private init() {}
}
