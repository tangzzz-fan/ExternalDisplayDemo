import CoreGraphics
import Foundation

/// 外接屏内容的滚动几何。
///
/// 手机端只传归一化进度，实际位移在这里按画面尺寸换算 —— 这样同一份
/// 手机端状态在 1080p / 4K / 模拟器 letterbox 小窗口上都成立。
///
/// ## 两个独立的位移
/// - `scrollOffset`：内容在瀑布流里的正常滚动（`scroll` 0...1），方向**向上**；
/// - `pullOffset`：顶部继续下拉让出的空间（`pull` 0...1），方向**向下**。
///
/// 后者就是"背景墙"露出来的高度。两者相加才是内容容器最终的 y 偏移。
///
/// ## 为什么内容高度是外部传进来的
/// 瀑布流的列高是**布局算完之后**才知道的（贪心分列的结果），
/// 不像等高列表可以用 `行数 × 行高` 直接推。所以这里不自己推内容高度，
/// 而是由调用方把 `WaterfallLayout.contentHeight` 喂进来。
/// 顺序不能反 —— 先布局，再算可滚动距离。
struct ScrollMetrics: Equatable, Sendable {

    let viewport: CGSize

    /// 内容总高（不含上下内边距），由 `WaterfallLayout` 算出。
    let contentHeight: CGFloat

    /// 内容四周的内边距，与瀑布流的 `WaterfallMetrics.inset` 同源。
    let inset: CGFloat

    /// 滚到底时内容需要上移的距离。
    ///
    /// 可能为 0：内容比视口还短时没有任何可滚动空间，
    /// 此时 `scroll` 全程都不产生位移（但 `pull` 仍然有效）。
    var maxOffset: CGFloat { max(0, contentHeight + inset * 2 - viewport.height) }

    /// 下拉到底时内容能下移的距离，占视口高度的比例。
    ///
    /// 取**一半**：`pull = 1` 时内容顶边正好落在屏幕中线，上半屏完整露出背景墙。
    /// 想改露出比例只动这一个常量 —— 它同时也是
    /// `maxLeadingElementHeight(viewport:inset:)` 的推导起点。
    static let pullDistanceRatio: CGFloat = 0.5

    /// 下拉到底时内容能下移的距离。
    var maxPullDistance: CGFloat { viewport.height * Self.pullDistanceRatio }

    /// 内容**顶部第一个元素**（本项目里是 hero 区）能有多高，
    /// 才能在 `pull = 1` 时完整落在可见区内而不被屏幕下沿切掉。
    ///
    /// 推导：`pull = 1` 时内容顶边落在屏幕中线，可见的内容高度只剩半个视口；
    /// 而该元素上方还有 `inset` 的内边距。所以
    ///
    /// ```
    /// inset + elementHeight <= 视口高 × pullDistanceRatio
    /// ```
    ///
    /// 做成函数而不是写一条注释：违反它的表现是"下拉到底之后标题少了一半"，
    /// 看起来像渲染 bug，查错方向很容易跑偏。让布局直接受它约束更可靠。
    static func maxLeadingElementHeight(viewport: CGSize, inset: CGFloat) -> CGFloat {
        viewport.height * pullDistanceRatio - inset
    }

    func scrollOffset(for scroll: CGFloat) -> CGFloat {
        maxOffset * min(max(scroll, 0), 1)
    }

    func pullOffset(for pull: CGFloat) -> CGFloat {
        maxPullDistance * min(max(pull, 0), 1)
    }

    /// 内容容器最终的 y 偏移。
    ///
    /// 正常滚动是**负**的（内容上移），下拉是**正**的（内容下移）。
    /// 两者不会同时非零：`RemoteControl` 里 `scroll` 与 `pull` 分别取自
    /// 同一个标量的正负两段，所以这里相加不会互相污染。
    func contentOffset(scroll: CGFloat, pull: CGFloat) -> CGFloat {
        pullOffset(for: pull) - scrollOffset(for: scroll)
    }

    /// 下拉时内容容器顶边的圆角半径。
    ///
    /// 下拉过程中容器会从"铺满视口"逐渐变成"浮在星海之上的一张卡片"，
    /// 圆角是这个转变的视觉信号。`pull = 0` 时必须是 0，
    /// 否则静止状态下画面顶部会莫名其妙缺两个角。
    func cornerRadius(for pull: CGFloat, base: CGFloat) -> CGFloat {
        base * 0.03 * min(max(pull, 0), 1)
    }
}

/// 下拉的手感曲线。
///
/// 独立成一个纯函数而不是写在 `RemoteControl` 里：它是**唯一的**手感来源 ——
/// 手机端读数、外接屏位移、验证脚本的断言三处都取自这里，
/// 不会出现"改了模型没改渲染"或"测试测的是另一条曲线"。
enum PullCurve {

    /// 到达 `pull == 1` 所需的原始行程（归一化）。
    ///
    /// `0.9` 意味着「在触控板上往下拖 0.9 个板高」恰好把背景墙完整露出来。
    /// 触控板高 168pt，实际就是约 150pt 的行程。
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
    /// 供滑杆、按钮、以及调试用的状态预置使用 —— 它们想给的是"露出多少"，
    /// 而唯一权威标量是原始行程，必须在这里换算，不能让调用方自己凑。
    static func rawValue(forProgress progress: CGFloat) -> CGFloat {
        let p = min(max(progress, 0), 1)
        guard p > 0 else { return 0 }
        return rawLimit * (1 - CGFloat(pow(Double(1 - p), 1 / Double(exponent))))
    }
}
