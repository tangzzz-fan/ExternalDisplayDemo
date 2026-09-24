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

    var inset: CGFloat { base * 0.07 }
    var columnSpacing: CGFloat { base * 0.022 }
    var itemSpacing: CGFloat { base * 0.022 }

    /// 列宽。已扣除左右内边距与列间距。
    var columnWidth: CGFloat {
        let usable = viewport.width - inset * 2 - columnSpacing * CGFloat(columns - 1)
        return max(0, usable / CGFloat(columns))
    }

    /// 权重换算成实际高度。
    ///
    /// 下限兜住极小权重 —— 高度趋近 0 的卡片在瀑布流里会变成一条缝，
    /// 既看不见又占着一个列位，比直接裁掉更难看。
    func height(for item: WaterfallItem) -> CGFloat {
        max(unitHeight * 0.72, unitHeight * item.heightWeight)
    }

    /// 列数按宽高比选。
    ///
    /// 横屏宽幅（16:9 及以上）用 4 列更饱满；letterbox 小窗口退到 3 列，
    /// 否则列宽会窄到放不下卡片里的文字。
    static func columnCount(for viewport: CGSize) -> Int {
        guard viewport.height > 0 else { return 3 }
        return viewport.width / viewport.height > 1.6 ? 4 : 3
    }
}

/// 瀑布流的列分配结果。
struct WaterfallLayout: Equatable, Sendable {

    /// 每列装着的项，顺序即渲染顺序。
    let columns: [[WaterfallItem]]

    /// 每列的累计高度（含列内间距），下标与 `columns` 对齐。
    let columnHeights: [CGFloat]

    /// item id → 实际高度。渲染侧按 id 取，避免重算。
    let heights: [Int: CGFloat]

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
        }

        return WaterfallLayout(columns: columns, columnHeights: columnHeights, heights: heights)
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

    /// 演示用的卡片。
    ///
    /// 高度权重落在 `0.75...1.9`：全部取 `1.0` 就退化成等高网格，看不出瀑布流的
    /// 错落；范围再大则会出现"一列全是长条、一列全是方块"的失衡。
    ///
    /// 配色走**锚点 + 抖动**而不是纯随机色相。纯随机会均匀地洒满整个色轮，
    /// 于是必然抽到荧光绿、屎黄、脏紫这些在暗底上很难看的区间；
    /// 锚点是一组挑过的色相，抖动只负责让相邻卡片不至于一模一样。
    static func demoItems(count: Int, seed: UInt64 = 20_260_924) -> [WaterfallItem] {
        guard count > 0 else { return [] }
        var generator = SeededGenerator(seed: seed)

        return (1...count).map { index in
            WaterfallItem(
                id: index,
                heightWeight: 0.75 + CGFloat.random(in: 0...1, using: &generator) * 1.15,
                tone: WaterfallTone.random(using: &generator)
            )
        }
    }
}

extension WaterfallTone {

    /// 挑过的色相锚点：靛蓝 → 青 → 蓝绿 → 深青 → 紫罗兰 → 品红 → 玫瑰 → 琥珀 → 铜。
    ///
    /// 刻意绕开 `0.12...0.35`（黄绿区间）—— 那一段在低明度下会变成橄榄绿和土黄，
    /// 放在黑色背景上显得很脏。
    private static let hueAnchors: [CGFloat] = [
        0.55, 0.62, 0.72, 0.80, 0.88, 0.93, 0.97, 0.05, 0.09
    ]

    /// 暗调区间。饱和度给足（避免灰扑扑），明度压低（保住白字可读性）。
    static func random<G: RandomNumberGenerator>(using generator: inout G) -> WaterfallTone {
        let anchor = hueAnchors.randomElement(using: &generator) ?? 0.6
        // 抖动 ±0.025：足以让同锚点的相邻卡片区分开，又不会跑到别的色相区
        let jitter = (CGFloat.random(in: 0...1, using: &generator) - 0.5) * 0.05

        return WaterfallTone(
            hue: (anchor + jitter + 1).truncatingRemainder(dividingBy: 1),
            saturation: 0.30 + CGFloat.random(in: 0...1, using: &generator) * 0.32,
            brightness: 0.22 + CGFloat.random(in: 0...1, using: &generator) * 0.20
        )
    }
}
