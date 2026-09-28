import CoreGraphics
import Foundation

/// 全景素材条的槽位几何与命中判定。
///
/// ## 它为什么是纯函数
/// 与 `WaterfallFocus` 完全同一条理由：外接屏收不到触摸，指针落点由手机端送过来，
/// 而**几何只有渲染侧知道**（视口尺寸、hero 高度、滚动位移）。所以"这一点压在哪一条上"
/// 只能在这侧算 —— 那就把它放在没有任何 UI 框架依赖的地方，好让它可以脱离视图、
/// 脱离模拟器单独跑断言。
///
/// ## 槽位怎么分
/// 横向与瀑布流共用**同一套留白**：5 个槽位等分列排布区的宽度
/// （`columnFieldWidth`），折成 `n × slotWidth + (n − 1) × spacing = fieldWidth`。
/// 于是素材条的左右端与瀑布流的最外两列严格对齐 —— 它们看起来是同一块板上
/// 的两个区，而不是两个各自居中的东西。
///
/// 纵向不在这里：条子多高、顶边落在哪，由 `WallContentStack` 决定
/// （它是整条竖栈的唯一来源），这里只接收结果 `originY`。
///
/// ## 坐标约定
/// - `slotFrame(at:)` 相对**条子视图自身**的左上角 —— 视图直接照它落位，
///   于是"画在哪"与"点到哪"用的是同一组矩形，不存在两份几何互相漂开的空间。
/// - `index(at:contentOffset:)` 吃**视口坐标**上的指针，内部先减掉内容位移与 `originY`。
///   纵向减在函数里、横向的留白已经烘进 `slotFrame`，两者不重复扣。
struct PanoramaStripGeometry: Equatable, Sendable {

    /// 槽位高度的比例（相对画面短边）。
    ///
    /// 0.17 是"比 hero 明显小一档、又容得下一行短名"的量级：
    /// 1080p 上是 184pt，模拟器 letterbox（200pt 短边）上是 34pt。
    /// 比它更矮时，letterbox 那一档的短名会被压到读不出来。
    static let heightRatio: CGFloat = 0.17

    /// 槽位间距的比例。与 `WaterfallMetrics.columnSpacing` / `itemSpacing` 同源
    /// （都是 `base × 0.022`）—— 幕墙上的缝是同一套节奏，条子不该自带另一种。
    static let spacingRatio: CGFloat = 0.022

    static func stripHeight(base: CGFloat) -> CGFloat { base * heightRatio }

    /// 条子所在视口的尺寸。归一化落点要拿它去除。
    let viewport: CGSize

    /// 画面短边。字号、圆角、环宽都按它等比缩放，与其余视图同一套口径 ——
    /// 从视口现算（而不是再传一个进来）是为了让"条子的短边"只有一种定义。
    let base: CGFloat

    /// 列排布区宽度（= 视口宽 − 两侧留白）。
    let fieldWidth: CGFloat

    /// 条子顶边在**内容容器**坐标里的 y。由 `WallContentStack.stripOriginY` 给。
    let originY: CGFloat

    /// 槽位个数（本票恒为素材件数 5）。
    let count: Int

    /// 单个槽位的宽度。等分排布区、扣掉槽间空隙。
    let slotWidth: CGFloat

    let spacing: CGFloat

    let height: CGFloat

    /// 池子为空（`count == 0`）时 `slotWidth` 取 0 而不是负数 ——
    /// 负宽度的 `frame` 会让整条视图画不出来，而"没有素材"是本票要显式支持的
    /// 一种状态（素材没下载时清单照样有 5 条，但万一清单为空也不该崩）。
    init(viewport: CGSize, fieldWidth: CGFloat, base: CGFloat, count: Int, originY: CGFloat) {
        let n = max(0, count)
        let spacing = base * Self.spacingRatio
        let field = max(0, fieldWidth)

        self.viewport = viewport
        self.base = base
        self.fieldWidth = field
        self.originY = originY
        self.count = n
        self.spacing = spacing
        self.height = Self.stripHeight(base: base)
        self.slotWidth = n > 0 ? max(0, (field - spacing * CGFloat(n - 1)) / CGFloat(n)) : 0
    }

    /// 按视口与槽位个数算出条子几何。
    ///
    /// 生产路径与调试预置（`-remoteState strip=`）共用这一条：槽心的归一化落点
    /// 只有在与渲染侧**同一份几何**上推出来才落得准，各推一份必然差出小半条槽的宽度。
    /// `waterfallHeight` 传 0 是刻意的 —— 条子的顶边只取决于 hero 与内边距。
    static func make(viewport: CGSize, count: Int) -> PanoramaStripGeometry {
        let base = min(viewport.width, viewport.height)
        let metrics = WaterfallMetrics(base: base, viewport: viewport, columns: WaterfallMetrics.wallColumns)
        let stack = WallContentStack(viewport: viewport, metrics: metrics, waterfallHeight: 0)
        return PanoramaStripGeometry(
            viewport: viewport,
            fieldWidth: metrics.columnFieldWidth,
            base: base,
            count: count,
            originY: stack.stripOriginY
        )
    }

    /// 排布区左缘距视口左缘的距离。
    ///
    /// 与 `DisplayPlan` 里那条同一个取法：用「视口宽 − 排布区宽」而不是
    /// `horizontalInset` —— 视口窄到装不下两侧留白时 `columnFieldWidth` 会被
    /// `max(0, _)` 护栏夹住，那时两者不再相等，而槽位**实际**的位置由被夹住的那个值决定。
    var leftInset: CGFloat { (viewport.width - fieldWidth) / 2 }

    /// 第 `index` 个槽位，相对**条子视图自身**的左上角。
    ///
    /// 越界下标不打护栏也不崩，只返回一个画不出来的矩形 —— 视图侧用
    /// `assets.enumerated()` 驱动，下标天然在范围内；这里再加一层夹取
    /// 只会把"调用方算错了"这件事藏起来。
    func slotFrame(at index: Int) -> CGRect {
        CGRect(
            x: leftInset + CGFloat(index) * (slotWidth + spacing),
            y: 0,
            width: slotWidth,
            height: height
        )
    }

    /// 命中判定：视口上这一点压在第几条上，都压不上则 `nil`。
    ///
    /// - Parameter contentOffset: 内容容器当前的位移
    ///   （`ScrollMetrics.contentOffset(scroll:pull:)` 与 `LateralMetrics.offset(for:)` 之和）。
    ///   条子随内容一起滚、一起被推，所以命中必须吃它 —— 不吃的话滚动之后
    ///   指针指向的永远是"没滚之前那条"，而静止截图看不出来。
    ///
    /// 用 `CGRect.contains` 而不是自己比四条边：它是**半开**区间 ——
    /// 含 `minX` / `minY`，不含 `maxX` / `maxY`。相邻两条之间那条边界因此
    /// 只会归属其中一条，既不会同时命中两个，也不会两边都落空。
    ///
    /// 槽间缝隙、条子上下的空白、以及画面外一律 `nil`：那几处本来就没有可聚焦的
    /// 东西，而条子与瀑布流之间只隔一个 `inset`，落到"最近的一条"上会让人以为
    /// 点错了东西。
    func index(at point: CGPoint, contentOffset: CGSize = .zero) -> Int? {
        let local = CGPoint(
            x: point.x - contentOffset.width,
            y: point.y - originY - contentOffset.height
        )
        for index in 0..<count where slotFrame(at: index).contains(local) {
            return index
        }
        return nil
    }

    /// 槽心在**归一化视口坐标**里的落点。
    ///
    /// 调试预置用它把指针直接摆到某一条上（`-remoteState strip=2`）：
    /// `simctl` 没有触摸注入 API，没有它就只能手点，而手点出来的截图不可复现。
    ///
    /// 入参 `viewport` 只需给出**宽高比**即可 —— 本条几何里所有纵向量按 `base`
    /// 线性缩放、横向量按视口宽线性缩放，两个方向各除一次之后绝对点数被约掉。
    func normalizedSlotCenter(at index: Int) -> CGPoint {
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        let frame = slotFrame(at: index)
        return CGPoint(
            x: frame.midX / viewport.width,
            y: (originY + height / 2) / viewport.height
        )
    }
}
