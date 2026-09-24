import CoreGraphics
import Foundation

/// 外接屏内容的滚动几何。
///
/// 手机端只传归一化进度，实际位移在这里按画面尺寸换算 —— 这样同一份
/// 手机端状态在 1080p / 4K / 模拟器 letterbox 小窗口上都成立。
///
/// ## 三个位移，一条纵轴 + 一条横轴
/// - `scrollOffset`：内容在瀑布流里的正常滚动（`scroll` 0...1），方向**向上**；
/// - `pullOffset`：顶部继续下拉让出的空间（`pull` 0...1），方向**向下**；
/// - `bottomOffset`：滚到底后继续上拉让出的空间（`bottomPull` 0...1），方向**向上**。
///
/// 前两个相加才是正常状态下内容容器最终的 y 偏移。第三个是后加的：
/// 它和 `pullOffset` 是同一件事的两端 —— 一端把内容推下去、一端把内容拽上来，
/// 露出的都是星海。
///
/// 横向位移不在这里，它由 `LateralMetrics` 负责 —— 理由见那个类型。
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

    /// 上拉到底时内容能上移的距离。
    ///
    /// 与下拉**对称**取同一个比例。这不是偷懒 —— 两条边是同一个动作的两端，
    /// 露出的是同一片星海，行程不一致的话"往上拽比往下拽费劲"会变成
    /// 一个说不清来由的手感差异。
    var maxBottomDistance: CGFloat { viewport.height * Self.pullDistanceRatio }

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

    /// 浮起时的四角圆角半径。
    ///
    /// `pull = 0` 时必须是 0，否则静止状态下画面顶部会莫名其妙缺两个角。
    func cornerRadius(base: CGFloat) -> CGFloat { base * 0.03 }
}

/// 幕墙"离开原位"的程度：三条位移轴里最大的那一条。
///
/// ## 为什么需要一个跨轴的量
/// 浮板的表现（投影、圆角强度、星海的相机推进）不由某一条轴单独决定，
/// 而由"这块板被推开了多少"决定 —— 横推露出的左侧星海与下拉露出的上半屏，
/// 是同一块板浮起来的两面，投影不该有两种算法。
///
/// 三条轴的取值范围与符号各不相同（`pull` / `bottomPull` 是 `0...1`，
/// `lateral` 是 `-1...1`），这里统一夹到 `0...1` 再取最大。
/// 夹一次而不是取绝对值的最大值：负的 `lateral` 表示往另一个方向推，
/// "推开了多少"仍然是非负量。
func wallExposure(pull: CGFloat, bottomPull: CGFloat, lateral: CGFloat) -> CGFloat {
    let top = min(max(pull, 0), 1)
    let bottom = min(max(bottomPull, 0), 1)
    let horizontal = abs(min(max(lateral, -1), 1))
    return max(top, max(bottom, horizontal))
}

/// 浮板的四角圆角。
///
/// ## 为什么不能只做"顶边圆角"
/// 顶边圆角是原设计：内容容器只在下拉时浮起，另外三条边永远贴着屏幕边缘、
/// 或者伸到屏幕外，圆角根本看不见，于是当年用一个 `TopRoundedRect` 就够了。
///
/// 幕墙能被四向推开之后这条前提没了：横推露出左（右）侧星海时，
/// 那一条**竖边**整条都在屏内，角要不要圆、圆多少，就成了看得见的观感差异。
/// 四条边各算各的，才叫"一块浮板"。
struct WallRadii: Equatable, Sendable {

    var topLeading: CGFloat
    var topTrailing: CGFloat
    var bottomLeading: CGFloat
    var bottomTrailing: CGFloat

    /// 由"哪几侧被推开了"推出四角。
    ///
    /// 每条边的暴露量：上边看 `pull`、下边看 `bottomPull`、左右两边看 `lateral` 的符号。
    /// 一个角同时属于两条边，取两者的**较大值** —— 取小的那个会让"顶边掀起来了
    /// 但左角还没圆"这种半吊子状态出现，而它既不像浮板也不像铺满，最难看。
    ///
    /// - Parameters:
    ///   - pull: 顶部下拉进度 `0...1`
    ///   - bottomPull: 底部上拉进度 `0...1`
    ///   - lateral: 横向推程 `-1...1`，正数 = 幕墙右移（露左侧星海）
    ///   - radius: 满暴露时的圆角半径
    static func forExposure(
        pull: CGFloat,
        bottomPull: CGFloat,
        lateral: CGFloat,
        radius: CGFloat
    ) -> WallRadii {
        let top = min(max(pull, 0), 1)
        let bottom = min(max(bottomPull, 0), 1)
        let horizontal = min(max(lateral, -1), 1)
        let left = max(top, max(0, horizontal))
        let right = max(top, max(0, -horizontal))

        return WallRadii(
            topLeading: radius * left,
            topTrailing: radius * right,
            bottomLeading: radius * max(bottom, max(0, horizontal)),
            bottomTrailing: radius * max(bottom, max(0, -horizontal))
        )
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
