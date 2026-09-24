import CoreGraphics
import Foundation

/// 照片在详情页里的查看模式。
///
/// 只依赖 `CoreGraphics` / `Foundation` 即可表达 —— 文案留在视图层，
/// 与 `WaterfallItem.captionIndex` 存下标而不存字符串是同一条规矩。
enum PhotoViewMode: String, CaseIterable, Sendable {

    /// 整图：照片**完整**可见，不足的那一侧留黑。
    case fit

    /// 铺满：照片填满视口，超出的部分裁掉，可拖拽查看。
    case fill

    /// 双击之后切到哪一种。
    var toggled: PhotoViewMode { self == .fit ? .fill : .fit }
}

/// 详情页的几何：由视口、照片宽高比与查看模式推出照片的尺寸、位置与可平移范围。
///
/// ## 为什么不用"高度 fit / 宽度 fit"这套说法
/// 需求最初的描述是"默认高度 fit，双击 width fit"。对**横屏宽幅的外接屏**
/// 加上**横构图照片**，这两个说法与 `min` / `max` 缩放恰好重合 —— 所以它
/// 在最初那个例子里完全成立。
///
/// 但换一张竖构图照片（相册里的常态），"宽度适配"会把它拉成一根竖条：
/// 以 16:9 视口、3:4 照片为例，宽度贴边之后高度是视口的 **2.37 倍**，
/// 用户能看到只剩中间一小段 —— 那不是"放大"，是失控。
///
/// 所以口径定成两个**与照片形状无关**的模式：
///
/// | 模式 | 缩放 | 含义 | 横构图时的表现 |
/// | --- | --- | --- | --- |
/// | `fit` | `min` | 完整可见，不足一侧留黑 | 高度贴边（= 需求说的 height fit） |
/// | `fill` | `max` | 消除黑边，超出裁掉 | 宽度贴边（= 需求说的 width fit） |
///
/// 竖构图照片在 `fill` 下同样只是"铺满 + 可拖"，不会被拉到荒腔走板。
///
/// ## 为什么这些量必须在渲染侧算
/// 手机端只知道手指走了多少，**不知道外接屏多大**（1080p / 4K / 模拟器
/// letterbox 窗口尺寸差异巨大）。所以手机端送的是归一化**行程进度**，
/// 像素行程在这里算 —— 与 `ScrollMetrics` / `LateralMetrics` 同一条规矩。
struct PhotoDetailGeometry: Equatable, Sendable {

    let viewport: CGSize

    /// 照片宽 / 高。接真实相册数据源后由图片本身给出。
    let aspectRatio: CGFloat

    let mode: PhotoViewMode

    init(viewport: CGSize, aspectRatio: CGFloat, mode: PhotoViewMode) {
        self.viewport = viewport
        // 损坏的宽高比（0 / 负数 / NaN）会一路算出 NaN 尺寸，
        // 表现为"整块画面凭空消失"，而且看起来像渲染 bug，查错方向容易跑偏。
        // 夹到 1:8 ~ 8:1 是一道护栏：真实照片不可能越界。
        self.aspectRatio = min(max(aspectRatio, 0.125), 8)
        self.mode = mode
    }

    /// 照片的绘制尺寸。
    ///
    /// 四组分支的判据只有两个：模式取 `min` 还是 `max`，
    /// 以及照片比视口更"宽"还是更"高"。当 `aspectRatio == 视口宽高比` 时，
    /// 四组结果**完全相同** —— 那种照片两种模式没有区别，也就没有黑边可消。
    var photoSize: CGSize {
        let width = viewport.width
        let height = viewport.height
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return .zero }

        // 照片比视口"更宽"：宽度先触边，宽度是限制项。
        let isWider = aspectRatio >= width / height

        switch (mode, isWider) {
        case (.fit, true):   return CGSize(width: width, height: width / aspectRatio)
        case (.fit, false):  return CGSize(width: height * aspectRatio, height: height)
        case (.fill, true):  return CGSize(width: height * aspectRatio, height: height)
        case (.fill, false): return CGSize(width: width, height: width / aspectRatio)
        }
    }

    /// 照片居中放置时，左上角相对视口原点的位置。
    ///
    /// 可能为负 —— `fill` 模式下照片比视口大，上沿与左沿本来就在视口之外。
    var centeredOrigin: CGPoint {
        let size = photoSize
        return CGPoint(
            x: (viewport.width - size.width) / 2,
            y: (viewport.height - size.height) / 2
        )
    }

    /// 可平移量（像素，非负）：照片超出视口那部分的一半。
    ///
    /// 取一半是因为"居中位置"到两端各有一半行程：照片高 117.6、视口高 84 时，
    /// 上下一共多出 33.6，从居中可以各走 16.8。
    ///
    /// 某方向没有超出时它就是 `0` —— 那个方向**不可拖**，
    /// 而不是"可拖但画面不变"。这个区别在 `clamped(_:)` 里被用上了。
    var panLimit: CGSize {
        let size = photoSize
        return CGSize(
            width: max(0, (size.width - viewport.width) / 2),
            height: max(0, (size.height - viewport.height) / 2)
        )
    }

    /// 把归一化的行程进度换算成像素位移。
    ///
    /// 进度取 `-1...1`：`0` = 居中，`±1` = 两端极限。手机端只能送这个量。
    func offset(for pan: CGSize) -> CGSize {
        let limit = panLimit
        return CGSize(
            width: clamp(pan.width, -1, 1) * limit.width,
            height: clamp(pan.height, -1, 1) * limit.height
        )
    }

    /// 把行程进度夹回**真正可达**的范围。
    ///
    /// ## 为什么这个方法必须存在
    /// 手机端只能做保守夹取 —— 它不知道照片的实际行程（那需要视口尺寸与
    /// 照片宽高比，两者都在渲染侧）。若某方向的行程为 `0`（`fit` 模式两个
    /// 方向都是 `0`），而手机端已经把它累积到了 `1`，用户反向拖动时就要先
    /// 把这 `1` 消化掉画面才会动 —— 表现得像**卡住**。
    ///
    /// 所以渲染侧每帧夹一次并把结果回写：手机端的值因此始终落在可达范围内，
    /// 反向拖动立刻生效。这与"过卷被阻尼吃掉的那部分不该在回拉时变成
    /// 凭空多出来的滚动"是同一个道理（见 `RemoteControl` 的 `position`）。
    func clamped(_ pan: CGSize) -> CGSize {
        let limit = panLimit
        return CGSize(
            width: limit.width > 0 ? clamp(pan.width, -1, 1) : 0,
            height: limit.height > 0 ? clamp(pan.height, -1, 1) : 0
        )
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, lower), upper)
    }
}
