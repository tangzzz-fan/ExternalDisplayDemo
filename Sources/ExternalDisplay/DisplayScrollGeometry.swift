import CoreGraphics
import Foundation

/// 外接屏内容的滚动几何。
///
/// 手机端只传归一化进度，实际位移在这里按画面尺寸换算 —— 这样同一份
/// 手机端状态在 1080p / 4K / 模拟器 letterbox 小窗口上都成立。
///
/// ## 三个位移，一条纵轴
/// - `scrollOffset`：正常滚动（`scroll` 0...1），方向**向上**；
/// - `pullOffset`：顶部继续下拉让出的空间（`pull` 0...1），方向**向下**；
/// - `bottomOffset`：滚到底后继续上拉让出的空间（`bottomPull` 0...1），方向**向上**。
///
/// 三者相加才是内容容器最终的 y 偏移。后两个是同一件事的两端 ——
/// 一端把内容推下去、一端把内容拽上来，露出的都是底层。
///
/// ## 为什么内容高度是外部传进来的
/// 可滚动距离取决于内容多高，而"内容多高"是渲染侧的事（本工程里是
/// `ExternalDisplayRootView.contentHeightRatio`）。这里不自己推，只负责换算。
struct ScrollMetrics: Equatable, Sendable {

    let viewport: CGSize

    /// 内容总高（不含上下内边距）。
    let contentHeight: CGFloat

    /// 内容四周的内边距。
    let inset: CGFloat

    /// 滚到底时内容需要上移的距离。
    ///
    /// 可能为 0：内容比视口还短时没有任何可滚动空间，
    /// 此时 `scroll` 全程都不产生位移（但 `pull` 仍然有效）。
    var maxOffset: CGFloat { max(0, contentHeight + inset * 2 - viewport.height) }

    /// 下拉到底时内容能下移的距离，占视口高度的比例。
    ///
    /// 取**一半**：`pull = 1` 时内容顶边正好落在屏幕中线，上半屏完整露出底层。
    static let pullDistanceRatio: CGFloat = 0.5

    /// 下拉到底时内容能下移的距离。
    var maxPullDistance: CGFloat { viewport.height * Self.pullDistanceRatio }

    /// 上拉到底时内容能上移的距离。
    ///
    /// 与下拉**对称**取同一个比例。这不是偷懒 —— 两条边是同一个动作的两端，
    /// 露出的是同一层底，行程不一致的话"往上拽比往下拽费劲"会变成
    /// 一个说不清来由的手感差异。
    var maxBottomDistance: CGFloat { viewport.height * Self.pullDistanceRatio }

    func scrollOffset(for scroll: CGFloat) -> CGFloat {
        maxOffset * min(max(scroll, 0), 1)
    }

    func pullOffset(for pull: CGFloat) -> CGFloat {
        maxPullDistance * min(max(pull, 0), 1)
    }

    func bottomOffset(for bottomPull: CGFloat) -> CGFloat {
        maxBottomDistance * min(max(bottomPull, 0), 1)
    }

    /// 内容容器最终的 y 偏移。
    ///
    /// 正常滚动是**负**的（内容上移），下拉是**正**的（内容下移），上拉又是负的。
    ///
    /// 三段**不会互相污染**：`scroll` 与 `pull` 分别取自同一个标量的正负两段，
    /// 不可能同时非零；`bottomPull` 只在 `scroll` 已经顶到 1 之后才出现，
    /// 此时它与 `scrollOffset` 相加的净效果正是"滚到底之后再往上拽多少"。
    /// 若把这三段拆成三个可独立写的存储属性，阻尼吃掉的那部分行程
    /// 会在回拉时变成凭空多出来的滚动，手指一松内容就跳。
    func contentOffset(scroll: CGFloat, pull: CGFloat, bottomPull: CGFloat = 0) -> CGFloat {
        pullOffset(for: pull) - scrollOffset(for: scroll) - bottomOffset(for: bottomPull)
    }
}

/// 下拉的手感曲线。
///
/// 独立成一个纯函数而不是写在 `RemoteControl` 里：它是**唯一的**手感来源 ——
/// 手机端读数、外接屏位移、验证脚本的断言三处都取自这里，
/// 不会出现"改了模型没改渲染"。
enum PullCurve {

    /// 到达 `pull == 1` 所需的原始行程（归一化）。
    ///
    /// `0.9` 意味着「在采集面上往下拖 0.9 个板高」恰好把底层完整露出来。
    static let rawLimit: CGFloat = 0.9

    /// 阻尼指数。`1.0` 为线性，越大越"先松后紧"。
    static let exponent: CGFloat = 1.7

    /// 原始行程 → 下拉进度（`0...1`）。
    ///
    /// `1 - (1 - t)^e` 在 `t = 0` 处的导数是 `e`（≈ 1.7），所以起手轻快；
    /// 越接近 1 导数越小，末段发沉 —— 这正是 iOS 弹性滚动的观感，
    /// 也是「拉到中线就基本拉不动了」这个手感提示的来源。
    ///
    /// 曲线在 `t = 1` 处**恰好取到 1**，不是渐近逼近 —— 这一点很重要：
    /// 若用 `1 - 1/(t·k + 1)` 那类渐近式，`pull` 永远到不了 1，
    /// 「内容顶边落在屏幕中线」这个几何承诺就永远差一截。
    static func progress(raw: CGFloat) -> CGFloat {
        guard raw > 0 else { return 0 }
        let t = min(raw / rawLimit, 1)
        return 1 - CGFloat(pow(Double(1 - t), Double(exponent)))
    }

    /// 下拉进度 → 原始行程。`progress(raw:)` 的反函数。
    ///
    /// 供调试用的状态预置使用 —— 它想给的是"露出多少"，
    /// 而唯一权威标量是原始行程，必须在这里换算，不能让调用方自己凑。
    static func rawValue(forProgress progress: CGFloat) -> CGFloat {
        let p = min(max(progress, 0), 1)
        guard p > 0 else { return 0 }
        return rawLimit * (1 - CGFloat(pow(Double(1 - p), 1 / Double(exponent))))
    }
}
