import CoreGraphics
import Foundation

/// 指针 → 瀑布流 item 的命中判定。
///
/// ## 为什么判定必须在这侧算
/// 外接屏的 role 是 `windowExternalDisplayNonInteractive`，它收不到任何触摸；
/// 光标位置只能由手机端经 `RemoteControl` 送过来。而**几何只有外接屏知道**
/// （视口尺寸、hero 高度、滚动位移都在渲染这侧），手机端无从判断"指针落在哪张卡上"。
/// 所以命中只能在这里算 —— 而这里就是那个纯函数层：只吃几何，不认识 SwiftUI，
/// 于是它可以在没有视图、没有模拟器的情况下单独跑断言。
///
/// ## 两个平移量，来源完全不同
/// 判定要把**视口坐标**上的点换算到 `placements` 所在的「列排布区」坐标系：
///
/// - `fieldOrigin`：列排布区左上角在**内容容器**里的位置。横向来自左右留白，
///   纵向来自「竖向内边距 + hero 高 + 间距」。它只在**视口尺寸变化**时才需要重算。
/// - `contentOffset`：内容容器随滚动 / 过卷 / 横向推开产生的整体位移，**每帧都在变**。
///
/// 后者刻意做成 `item(at:)` 的参数而不是烘进 `fieldOrigin`：混在一起之后，
/// "内容动了"和"布局变了"这两件事在调用点上就分不开了，而它们的更新频率差了两个数量级。
///
/// 横纵两个分量**必须合成一个值传进来**，而不是留两个参数：横向推开之后，
/// 少喂一个分量不会报错、也不会在纵向滚动时露馅 —— 它只在横向一动时才显形，
/// 表现为"指针点到的永远是隔壁那张卡"。一个 `CGSize` 至少让调用点上的
/// "这次位移带了几维"一眼可见。
struct WaterfallFocus: Equatable, Sendable {

    /// 列排布区左上角，在内容容器坐标系里。
    let fieldOrigin: CGPoint

    /// 各项在列排布区里的落位，顺序即 `items` 的传入顺序。
    let placements: [WaterfallPlacement]

    /// 命中判定：返回视口上这一点落在哪张卡片上，都落不上则 `nil`。
    ///
    /// - Parameter contentOffset: 内容容器当前的位移
    ///   （`ScrollMetrics.contentOffset(scroll:pull:)` 与 `LateralMetrics.offset(for:)` 之和）。
    ///   下拉为正、滚动为负、横向推开为正则右移。
    ///
    /// 用 `CGRect.contains` 而不是自己比四条边：它是**半开**区间 ——
    /// 含 `minX` / `minY`，不含 `maxX` / `maxY`。相邻两张卡之间那条边界因此
    /// 只会归属其中一张，既不会同时命中两个，也不会两边都落空。
    ///
    /// 卡片之间不可能重叠（列内靠累计高度、列间靠列宽 + 列间距），
    /// 所以最多命中一个，遍历顺序不影响结果 —— 但顺序仍然是确定的
    /// （`placements` 按传入顺序排列），这一点对逐状态截图对比是必要的。
    ///
    /// 指针落在 hero 区、列间距、卡片间隙或画面外时一律返回 `nil`：
    /// 那几处本来就没有可聚焦的东西，"没有焦点"比"聚焦到最近的卡片"更符合直觉。
    func item(at point: CGPoint, contentOffset: CGSize = .zero) -> Int? {
        let local = CGPoint(
            x: point.x - fieldOrigin.x - contentOffset.width,
            y: point.y - fieldOrigin.y - contentOffset.height
        )
        for placement in placements where placement.frame.contains(local) {
            return placement.id
        }
        return nil
    }
}
