import CoreGraphics
import Foundation

/// 幕墙内容列的**竖栈**：从上到下每个块落在哪、内容总高多少。
///
/// ## 为什么必须收敛成一份
/// 内容列是一条 `VStack(spacing: inset)`，块与块之间不用同一个间距就会
/// 出现"某两块贴着、另两块隔着一条缝"这种一眼可辨的错。
/// 而在票 `07` 之前，这条式子在本项目里**有三份**：
///
/// - 渲染侧 `ExternalDisplayRootView.DisplayPlan`（真正决定画在哪）；
/// - `verify` §1（"内容是否高于视口"的可滚动判据）；
/// - `verify` §10c（"上拉到底时卡片会滑到返回按钮底下"这条优先关系的判据）。
///
/// 三份各自都对，但它们描述的是**同一件事**。往中间插一个新块（本票的素材条）
/// 时，只改渲染侧那一份是最自然也最危险的改法 —— 断言那两份会继续算旧式子，
/// 于是变成"测的是另一个布局"，而它在截图上完全看不出来：两个布局都能滚、
/// 卡片也照样会滑到按钮底下，只是滑到的那一刻差了几十点。
///
/// 所以这里把式子收成**一份**，三处都从它取。改一个块的高度，三处同时跟着变。
///
/// ## 坐标与口径
/// 所有量都在**内容容器**坐标系里（容器左上角为原点），也就是 `.offset(offset)`
/// 作用的那一层。块的顺序是：
///
/// ```
/// inset │ hero │ inset │ 条子 │ inset │ 瀑布流（列排布区 y = 0）…
/// ```
///
/// `contentHeight` 刻意与 `ScrollMetrics.contentHeight` **同口径**：
/// 含块与块之间的间距，**不含**内容列自己的上下内边距 ——
/// 后者由 `ScrollMetrics` 在算 `maxOffset` 时补上（`contentHeight + inset * 2`）。
/// 两处若各含一次 padding，可滚动距离就会凭空多出一个内边距，
/// 表现为"滚到底还差一点点才见底"，而它小到截图上看不出来。
struct WallContentStack: Equatable, Sendable {

    /// 块间与上下内边距共用的那个间距（= `WaterfallMetrics.inset`）。
    let inset: CGFloat

    /// hero 区高度，已含 `maxLeadingElementHeight` 的压低。
    let heroHeight: CGFloat

    /// 全景素材条高度。
    let stripHeight: CGFloat

    /// 瀑布流内容高度（= 最高那列的高度）。
    let waterfallHeight: CGFloat

    /// hero 区高度的**理想**占比。
    ///
    /// 它只是个愿望：真正的 hero 高还要被 `ScrollMetrics.maxLeadingElementHeight`
    /// 压低 —— 后者是下拉几何反推出的硬上限（`pull = 1` 时可见的内容高度
    /// 只剩半个视口，hero 再高就会被屏幕下沿切掉标题）。
    ///
    /// 理想值 0.56 在模拟器 letterbox 小窗口（355×200 点）上算出来是 112pt，
    /// 而上限只有 86pt —— 也就是说那个场景下**上限才是生效的那个**。
    static let heroHeightRatio: CGFloat = 0.56

    /// hero 区的实际高度。
    ///
    /// 抽成静态函数而不是写成两行 `min(...)`：下拉判据（`verify` §3b）要按
    /// **同一个式子**反推"上限生效之后 hero 还剩多少"，两处各写一遍的话，
    /// 断言测的是另一个高度，而它错了只会表现为"下拉到底标题少了一截"。
    static func heroHeight(for viewport: CGSize, inset: CGFloat) -> CGFloat {
        min(
            viewport.height * heroHeightRatio,
            ScrollMetrics.maxLeadingElementHeight(viewport: viewport, inset: inset)
        )
    }

    /// 按视口与瀑布流几何算出整条竖栈。
    ///
    /// 条子高度取自 `PanoramaStripGeometry.stripHeight(base:)` 而**不是**在这里
    /// 再写一个比例：条子自身多高是它的几何，竖栈只负责把它算进总高。
    /// 分成两处写的话，"条子变高了"会变成"条子压住了瀑布流顶部一截"。
    init(viewport: CGSize, metrics: WaterfallMetrics, waterfallHeight: CGFloat) {
        let base = min(viewport.width, viewport.height)
        self.inset = metrics.inset
        self.heroHeight = Self.heroHeight(for: viewport, inset: metrics.inset)
        self.stripHeight = PanoramaStripGeometry.stripHeight(base: base)
        self.waterfallHeight = waterfallHeight
    }

    /// hero 区顶边（内容列的第一个块，紧跟在顶部内边距之后）。
    var heroOriginY: CGFloat { inset }

    /// 素材条顶边。
    var stripOriginY: CGFloat { inset * 2 + heroHeight }

    /// 列排布区顶边 —— 也就是瀑布流第一行卡片的顶边。
    ///
    /// 这条是命中判定的输入（`WaterfallFocus.fieldOrigin.y`），
    /// 与渲染侧的 `VStack` 结构互为镜像：改了块的顺序或间距，这里跟着变，
    /// 不然指针会点中"上一行"的位置。
    var fieldOriginY: CGFloat { stripOriginY + stripHeight + inset }

    /// 内容列自身的高度（含块间间距，不含上下内边距）。见类型文档。
    var contentHeight: CGFloat {
        heroHeight + inset + stripHeight + inset + waterfallHeight
    }
}
