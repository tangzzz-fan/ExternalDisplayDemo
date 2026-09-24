import CoreGraphics
import Foundation

/// 卡片配色。
///
/// 存 HSB 分量而不是 `Color`：这一层是纯 `CoreGraphics` 的，不认识 SwiftUI 的
/// `Color`；而且纯数值才能在没有 UI、没有模拟器的情况下跑断言。
struct WaterfallTone: Equatable, Sendable {

    /// `0...1`，对应色轮。
    let hue: CGFloat

    /// 饱和度与明度。都压在暗调区间 —— 卡片上要放白字，
    /// 亮色底会让文字直接糊掉。
    let saturation: CGFloat
    let brightness: CGFloat
}

/// 瀑布流里的一项。
///
/// 高度用**权重**而不是绝对点数表达：外接屏可能是 1080p / 4K / 模拟器的
/// letterbox 小窗口，绝对点数在其中之一上必然溢出或过疏。权重乘上
/// `WaterfallMetrics.unitHeight`（由画面短边推出）之后，同一份数据在哪块屏上都成立。
struct WaterfallItem: Identifiable, Equatable, Sendable {

    let id: Int

    /// 高度权重，`1.0` 对应 `WaterfallMetrics.unitHeight`。
    let heightWeight: CGFloat

    /// 卡片配色。
    let tone: WaterfallTone

    /// 圆角倍率，`1.0` 为基准。
    ///
    /// 全屏几百张卡共用一个圆角会显出"批量生成"的味道；浮动 ±45% 之后，
    /// 相邻卡片的轮廓线不再连成一条，观感立刻从"网格"变成"手摆的"。
    let cornerScale: CGFloat

    /// 封面主渐变的方向角（弧度）。
    ///
    /// 固定成 45°（左上 → 右下）时，整片瀑布流像被同一盏灯照亮，
    /// 越往下看越平。每张卡各带一个方向之后，高光才散得开。
    let gradientAngle: CGFloat

    /// 封面高光的中心，归一化到卡片内的 `0...1`。
    ///
    /// **必须**与 `gradientAngle` 同侧（生成时就按起点抖动出来）：
    /// 光源和高光各指一个方向的话，卡片会看起来像被两盏灯从相反方向打光，
    /// 比不打光更假。
    let highlight: CGPoint

    /// 底栏文案的档位。
    ///
    /// 存下标而不是字符串 —— 这一层是纯 `CoreGraphics` 的，不该认识文案；
    /// 而且字符串一旦进了这里，"换个说法"就要改布局层。
    let captionIndex: Int

    /// 是否为精选卡：描边更亮、高光更强。
    ///
    /// 一成左右的卡片"跳出来"能打断整片均匀的色块节奏，
    /// 让眼睛有落点 —— 全是同等强度的卡片时，视线会直接滑出画面。
    let isFeatured: Bool
}

/// 瀑布流的几何常量。
///
/// 只依赖 `base`（画面短边）与 `viewport`，不碰任何 UI 框架 ——
/// 于是整份布局可以在没有视图、没有模拟器的情况下单独跑断言。
struct WaterfallMetrics: Equatable, Sendable {

    let base: CGFloat
    let viewport: CGSize
    let columns: Int

    /// 权重 `1.0` 对应的卡片高度。
    let unitHeight: CGFloat

    init(base: CGFloat, viewport: CGSize, columns: Int) {
        self.base = base
        self.viewport = viewport
        self.columns = max(1, columns)
        self.unitHeight = base * 0.20
    }

    /// 竖向节奏：内容块的上下内边距，以及 hero 与瀑布流之间的间距。
    ///
    /// **只用于竖向**。横向由 `horizontalInset` 负责 —— 早先这一个值同时
    /// 兼任左右内边距，横向需求一变竖向就被迫跟着变。
    var inset: CGFloat { base * 0.07 }

    /// 内容区左右留白：列排布区离屏幕左右边缘各多少点。
    ///
    /// 与 `inset` 同源（`base × 0.07`）—— 于是瀑布流与 hero 的左右边正好对齐，
    /// 四个方向的留白也是同一个量级。
    ///
    /// 用 `base` 的比例而不是写死点数：本项目所有排版都按画面短边等比缩放，
    /// 写死 100pt 在 4K 上几乎看不见、在 letterbox 小窗口上会把整列吃掉。
    ///
    /// 早先这里是**负向**的（`horizontalBleed`：内容向两侧各溢出约 100pt，
    /// 最外两列被屏幕边缘切开）。改成正向后内容整体收进屏内，每一列都完整。
    var horizontalInset: CGFloat { base * 0.07 }

    var columnSpacing: CGFloat { base * 0.022 }
    var itemSpacing: CGFloat { base * 0.022 }

    /// 列排布区宽度 = 视口宽 − 两侧留白。
    ///
    /// 注意它**小于**视口宽 —— 每列都完整落在屏内，没有任何一列被边缘切掉。
    /// 下限 `0` 只是护栏：视口窄到装不下两侧留白时，列宽会退化成 0，
    /// 那比让这个值变成负数（负宽度的 `frame`）更容易看出问题出在哪。
    var columnFieldWidth: CGFloat { max(0, viewport.width - horizontalInset * 2) }

    /// 列宽。排布区被 `columns` 等分（扣掉列间距）。
    var columnWidth: CGFloat {
        let usable = columnFieldWidth - columnSpacing * CGFloat(columns - 1)
        return max(0, usable / CGFloat(columns))
    }

    /// 权重换算成实际高度。
    ///
    /// 下限只是**护栏**：正常权重都 ≥ 0.55，这条永远不生效，但能兜住外部
    /// 传入的异常数据 —— 高度趋近 0 的卡片会变成一条缝，既看不见又占着列位，
    /// 比直接裁掉更难看。
    func height(for item: WaterfallItem) -> CGFloat {
        max(unitHeight * 0.50, unitHeight * item.heightWeight)
    }

    /// 列数按宽高比选。
    ///
    /// 横屏宽幅（16:9 及以上）用 4 列更饱满；letterbox 小窗口退到 3 列，
    /// 否则列宽会窄到放不下卡片里的文字。
    static func columnCount(for viewport: CGSize) -> Int {
        guard viewport.height > 0 else { return 3 }
        return viewport.width / viewport.height > 1.6 ? 4 : 3
    }

    /// 幕墙这一版**显式指定**的列数。
    ///
    /// ## 为什么不走上面那个自适应函数
    /// 自适应按宽高比在 3 / 4 列之间挑，判据是"列宽要放得下卡片文字"。
    /// 幕墙这一版的需求方向变了：要的是**缝够密** —— 列越多、竖缝越多，
    /// 星海透过来的地方就越多，幕墙的玻璃感主要来自这些缝。
    ///
    /// 代价是明确的：模拟器替身窗口（355×200 点）上列宽被压到 50pt 上下，
    /// 底栏文案要靠 `minimumScaleFactor` 缩到 0.65 倍才放得下；
    /// 1080p（1920×1080 点）上是 265pt，没有问题。
    ///
    /// ## 为什么定义在这里，而不是写在视图里
    /// 验收脚本要按**同一套几何**断言（列宽、落位、按钮与卡片的位置关系）。
    /// 列数写死两遍，脚本测的就是另一套列宽 —— 这种"测了个别的配置"
    /// 在本项目里已经踩过一次，所以宁可多一个公开常量。
    static let wallColumns = 6
}

/// 瀑布流里一项的落位。
///
/// 坐标系是**列排布区**的左上角，不是视口、也不是屏幕 —— 排布区与屏幕之间还隔着
/// 左右留白，把它留在这一层之外，落位就只跟布局本身有关。
struct WaterfallPlacement: Equatable, Sendable {

    let id: Int

    /// 落在第几列（从 0 起）。
    let column: Int

    /// 该卡片在列排布区里的矩形。
    let frame: CGRect
}

/// 瀑布流的列分配结果。
struct WaterfallLayout: Equatable, Sendable {

    /// 每列装着的项，顺序即渲染顺序。
    let columns: [[WaterfallItem]]

    /// 每列的累计高度（含列内间距），下标与 `columns` 对齐。
    let columnHeights: [CGFloat]

    /// item id → 实际高度。渲染侧按 id 取，避免重算。
    let heights: [Int: CGFloat]

    /// 每项的落位，顺序即 `items` 的传入顺序。
    ///
    /// 与 `heights` 有冗余（frame 的高度就是 `heights[id]`），但两者服务的对象不同：
    /// `heights` 给渲染侧的 `VStack` 定高，`placements` 给命中判定定位。
    /// 渲染不需要坐标，命中不需要按列分组 —— 硬合成一种是两边都别扭。
    let placements: [WaterfallPlacement]

    /// 最高那列的高度，即瀑布流的内容高度。
    var contentHeight: CGFloat { columnHeights.max() ?? 0 }

    /// 贪心分列：每一项都放进当前**最矮**的列。
    ///
    /// 这是瀑布流的标准做法，也是唯一能保证"视觉上错落、且总高接近最优"的
    /// 线性算法。复杂度 `O(n·k)`，n 是项数、k 是列数（3 或 4），实质是常数。
    ///
    /// **平手时取下标小的列**，保证同一份输入永远得到同一份输出。
    /// 布局抖动会让逐状态截图对比完全失去意义 —— 而截图是本项目唯一可行的验证手段。
    static func make(items: [WaterfallItem], metrics: WaterfallMetrics) -> WaterfallLayout {
        var columns = Array(repeating: [WaterfallItem](), count: metrics.columns)
        var columnHeights = Array(repeating: CGFloat.zero, count: metrics.columns)
        var heights: [Int: CGFloat] = [:]
        heights.reserveCapacity(items.count)
        var placements: [WaterfallPlacement] = []
        placements.reserveCapacity(items.count)

        /// 列在排布区里的横向起点。列宽与间距都由 `metrics` 决定，
        /// 所以这一列一旦定下就不会再变 —— 可以在循环外先算好。
        let columnStride = metrics.columnWidth + metrics.columnSpacing

        for item in items {
            let height = metrics.height(for: item)
            heights[item.id] = height

            var target = 0
            for index in 1..<columnHeights.count where columnHeights[index] < columnHeights[target] {
                target = index
            }

            // 列内已有内容才加间距：否则每列顶部会凭空多出一条缝，
            // 而且这条缝的高度会随列内项数变化，列首无法对齐。
            if !columns[target].isEmpty {
                columnHeights[target] += metrics.itemSpacing
            }
            columns[target].append(item)
            columnHeights[target] += height

            // 累计高度此刻**已经含**这一项，减掉才是它的顶边。
            // 顺序不能反：先取顶边再累加，间距那一步就白算了。
            placements.append(
                WaterfallPlacement(
                    id: item.id,
                    column: target,
                    frame: CGRect(
                        x: CGFloat(target) * columnStride,
                        y: columnHeights[target] - height,
                        width: metrics.columnWidth,
                        height: height
                    )
                )
            )
        }

        return WaterfallLayout(
            columns: columns,
            columnHeights: columnHeights,
            heights: heights,
            placements: placements
        )
    }
}

// MARK: - 确定性随机

/// 确定性伪随机源（SplitMix64）。
///
/// 星点与卡片高度都必须**可复现**：逐状态截图对比是本项目唯一可行的验证手段，
/// 而 `SystemRandomNumberGenerator` 每次进程启动都不一样，会让两次截图无法对比。
struct SeededGenerator: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - 演示数据

extension WaterfallItem {

    /// 底栏文案的档位总数。文案本身在视图层 —— 这一层不认识字符串。
    static let captionCount = 6

    /// 演示用的卡片。
    ///
    /// 高度权重主体落在 `0.55...1.90`，另有约 **22%** 的卡片被额外拉长
    /// `0...0.85`，即最高可到 `2.75`。
    ///
    /// 为什么不干脆均匀铺满一个大区间：那样长短卡五五开，看起来是"随机"而不是
    /// "错落"。错落要有节奏 —— 主体保持中等长度，少量长条插进去当视觉锚点。
    /// 反过来若全部取 `1.0`，就退化成等高网格，根本看不出瀑布流。
    ///
    /// 拉长比例为什么是 22% 而不是 17%：`> 1.90`（超出基础区间）的概率是
    /// `拉长概率 × 约 0.31`，17% 时只有 5% 左右 —— 36 张的演示集里期望值
    /// 不到两张，长尾实际上看不见，等于白写。22% 之后期望约 2.5 张，
    /// 每屏都必然能看到几根竖条。
    ///
    /// 配色走**锚点 + 抖动**而不是纯随机色相。纯随机会均匀地洒满整个色轮，
    /// 于是必然抽到荧光绿、屎黄、脏紫这些在暗底上很难看的区间；
    /// 锚点是一组挑过的色相，抖动只负责让相邻卡片不至于一模一样。
    static func demoItems(count: Int, seed: UInt64 = 20_260_924) -> [WaterfallItem] {
        guard count > 0 else { return [] }
        var generator = SeededGenerator(seed: seed)

        return (1...count).map { index in
            make(id: index, using: &generator)
        }
    }

    /// 抽一张卡。所有随机量都在这里，顺序固定 → 同种子必然同结果。
    private static func make<G: RandomNumberGenerator>(id: Int, using generator: inout G) -> WaterfallItem {
        // 长条：22% 的卡片额外加 0...0.85 的权重，把少数卡片拉到 2.75 上限。
        // 在这个量级上，最高的那些卡会从"横条"变成"竖条"（高度超过列宽），
        // 整片瀑布流的错落感主要就来自这几根。
        let stretch = roll(&generator) < 0.22 ? roll(&generator) * 0.85 : 0
        let angle = roll(&generator) * 2 * .pi
        let start = gradientStart(for: angle)

        return WaterfallItem(
            id: id,
            heightWeight: 0.55 + roll(&generator) * 1.35 + stretch,
            tone: WaterfallTone.random(using: &generator),
            cornerScale: 0.55 + roll(&generator) * 0.90,
            gradientAngle: angle,
            // 高光从渐变起点抖出来：两者同侧，光源才是自洽的
            highlight: CGPoint(
                x: clamp(start.x + (roll(&generator) - 0.5) * 0.22, 0.02, 0.98),
                y: clamp(start.y + (roll(&generator) - 0.5) * 0.22, 0.02, 0.98)
            ),
            captionIndex: min(captionCount - 1, Int(roll(&generator) * CGFloat(captionCount))),
            isFeatured: roll(&generator) < 0.14
        )
    }

    /// 主渐变的归一化起点 / 终点。
    ///
    /// 只存角度、由角度推出两个端点，而不是直接存两个点：角度是**单一**
    /// 自由度，推出来的端点必然自洽；存两个点则可能生成出长度不一的向量，
    /// 渐变斜率会跟着乱。
    static func gradientStart(for angle: CGFloat) -> CGPoint {
        CGPoint(x: 0.5 - cos(angle) * 0.5, y: 0.5 - sin(angle) * 0.5)
    }

    static func gradientEnd(for angle: CGFloat) -> CGPoint {
        CGPoint(x: 0.5 + cos(angle) * 0.5, y: 0.5 + sin(angle) * 0.5)
    }

    // MARK: - Helpers

    /// `0...1` 均匀取样。
    ///
    /// 写成静态函数而不是嵌套函数：嵌套函数捕获 `inout` 的生成器会触发
    /// 独占访问检查，每次调用都要写一遍 `CGFloat.random(in:using:)` 又太吵。
    private static func roll<G: RandomNumberGenerator>(_ generator: inout G) -> CGFloat {
        CGFloat.random(in: 0...1, using: &generator)
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}

extension WaterfallTone {

    /// 挑过的色相锚点：靛蓝 → 青 → 蓝绿 → 深青 → 紫罗兰 → 品红 → 玫瑰 → 琥珀 → 铜。
    ///
    /// 刻意绕开黄绿区间（见 `forbiddenLower` / `forbiddenUpper`）——
    /// 那一段在低明度下会变成橄榄绿和土黄，放在黑色背景上显得很脏。
    private static let hueAnchors: [CGFloat] = [
        0.55, 0.62, 0.72, 0.80, 0.88, 0.93, 0.97, 0.05, 0.09
    ]

    /// 色相禁区（左闭右开）：黄绿区间。
    ///
    /// 低明度下 `0.12...0.35` 会变成橄榄绿和土黄，在近黑底上像一块脏抹布。
    static let forbiddenLower: CGFloat = 0.12
    static let forbiddenUpper: CGFloat = 0.35

    /// 反射时至少让开边界这么远。
    ///
    /// 只有 `hue` 正好压在边界上时才会用到：那时反射距离是 0，结果还贴在
    /// 边界上，不满足"严格落在禁区外"这个不变量。生成的色相是连续量、
    /// 撞上边界的概率为 0 —— 但不变量是要被断言的东西，不能留测度零的例外。
    private static let boundaryClearance: CGFloat = 1e-9

    /// 把色相从禁区里**反射**出去。
    ///
    /// 只靠"锚点挑得够远"是不够的：锚点 `0.09` 加上满额抖动就是 `0.135`，
    /// 正好落进禁区 —— 这次把抖动从 ±0.025 放宽到 ±0.045 时就真的踩到了，
    /// 屏幕上冒出一张橄榄金色的卡。**放宽任何随机区间，都要回头检查
    /// 原有的"安全边界"是否仍然成立。**
    ///
    /// 用反射而不是截断：截断会让所有越界取样堆在边界上，
    /// 于是在 `0.12` 处出现一撮一模一样的颜色；反射保持随机量的幅度、
    /// 只换方向，分布不会塌缩成一个点。
    static func escapedHue(_ hue: CGFloat) -> CGFloat {
        guard hue >= forbiddenLower, hue < forbiddenUpper else { return hue }
        let toLower = hue - forbiddenLower
        let toUpper = forbiddenUpper - hue
        return toLower <= toUpper
            ? forbiddenLower - max(toLower, boundaryClearance)
            : forbiddenUpper + max(toUpper, boundaryClearance)
    }

    /// 暗调区间。饱和度给足（避免灰扑扑），明度压低（保住白字可读性）。
    ///
    /// 抖动放宽到 ±0.045：相邻锚点最近只差 0.05，再大就会让两组锚点的卡片
    /// 混成一片、锚点本身失去意义。越界的部分由 `escapedHue` 兜住。
    static func random<G: RandomNumberGenerator>(using generator: inout G) -> WaterfallTone {
        let anchor = hueAnchors.randomElement(using: &generator) ?? 0.6
        let jitter = (CGFloat.random(in: 0...1, using: &generator) - 0.5) * 0.09

        // 约一成卡片走"深色中性"：整屏都是饱和色块会像一本色卡册，
        // 掺一点近乎无彩的深灰蓝，彩色反而更跳。
        let isNeutral = CGFloat.random(in: 0...1, using: &generator) < 0.12

        return WaterfallTone(
            hue: escapedHue((anchor + jitter + 1).truncatingRemainder(dividingBy: 1)),
            saturation: isNeutral
                ? 0.06 + CGFloat.random(in: 0...1, using: &generator) * 0.10
                : 0.30 + CGFloat.random(in: 0...1, using: &generator) * 0.38,
            brightness: isNeutral
                ? 0.18 + CGFloat.random(in: 0...1, using: &generator) * 0.12
                : 0.20 + CGFloat.random(in: 0...1, using: &generator) * 0.24
        )
    }
}
