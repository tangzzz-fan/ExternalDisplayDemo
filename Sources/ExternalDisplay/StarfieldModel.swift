import CoreGraphics
import Foundation

/// 一颗星在 3D 空间中的**静态**参数。
///
/// 全部与时间无关 —— 闪烁靠 `twinklePhase` / `twinkleSpeed` 现算，不存状态。
/// 这样整份星表只需生成一次，每帧只做投影与绘制。
struct Star: Equatable, Sendable {

    /// 归一化分布坐标，`-1...1`。投影时按视口半宽 / 半高铺开。
    let x: CGFloat
    let y: CGFloat

    /// 深度。`0.6` 最近，`1.4` 最远。相机推进会把有效深度压小。
    let z: CGFloat

    /// 基准半径（点）。实际半径 = 它 × 尺寸透视系数。
    let baseRadius: CGFloat

    /// 亮度。
    let brightness: CGFloat

    /// 闪烁的相位与角频率。每颗星都不同。
    let twinklePhase: CGFloat
    let twinkleSpeed: CGFloat

    /// `0` = 冷白，`1` = 暖白。三次幂分布，所以暖色只是零星点缀。
    let warmth: CGFloat

    /// 绘制路径的归属。**在生成时定下来**，不按投影后的半径逐帧判断。
    ///
    /// 逐帧判断会让同一颗星在相机推进时来回切换路径，视觉上闪一下；
    /// 更重要的是，那样"多少颗星走昂贵路径"就成了随相机位置浮动的未知量，
    /// 帧预算没法做。定死在生成期之后，它就是一个可断言的常量。
    let role: StarRole
}

/// 星点的绘制路径。
enum StarRole: Sendable {

    /// 暗点：一个 1~2pt 的方块。占绝大多数，**决定整体帧预算**。
    case speck

    /// 亮星：光晕 + 圆点本体 + 可选十字光芒。
    case bright
}

/// 相机状态。每帧由 `pull` 与手机端倾斜量推出来。
struct StarfieldCamera: Equatable, Sendable {

    /// 相机推进量，`0` = 最远，`1` = 最近。
    var dolly: CGFloat = 0

    /// 视差倾斜，归一化 `-1...1`。
    var tiltX: CGFloat = 0
    var tiltY: CGFloat = 0
}

/// 一颗星投影到屏幕上的结果。
struct ProjectedStar: Equatable, Sendable {

    let position: CGPoint
    let radius: CGFloat
    let opacity: Double
}

/// 把 3D 星点投影到 2D 视口。
///
/// ## 为什么是「压缩过的透视」而不是完整透视除法
/// 教科书式的透视除法 `scale = focal / depth` 会把深度差放大成巨大的尺度差：
/// 本例里 `depth` 从 0.34 到 1.14，`scale` 就从 2.65 跨到 0.79 —— 近处的星被推到
/// 画面外，远处的星全挤在中心，整片星海变成一个**隧道**，而不是穹顶。
///
/// 但完全不做透视（纯分层平移）又只剩平移视差，近处的星不会变大、远处的不变淡，
/// 脑子立刻判定这是张平面图。
///
/// 所以这里把两个用途**分别压缩**：
/// - 位置位移用 `rawScale^0.35`（0.82...1.35）—— 够看出纵深，又不会把星甩出画面；
/// - 尺寸用 `rawScale^0.60`（0.76...1.79）—— 尺寸差异比位置差异更明显，
///   因为"远小近大"是大脑判断深度最强的单一线索。
///
/// 两者共用同一个 `rawScale`，所以仍然严格单调、物理自洽，只是把动态范围收窄到
/// 「穹顶」而不是「隧道」的量级。
///
/// ## 相机推进为什么刻意很小
/// 劳斯莱斯的星空顶是「一片静止的穹顶 + 极缓慢的视角变化」，不是穿梭飞行。
/// `dollyDepth` 只取 `0.26` —— 推太深会变成星际穿越，那种急速拉丝的观感和
/// "星空顶"是两回事。
struct StarfieldProjector {

    let viewport: CGSize

    /// 焦距（世界 z 单位）。`depth == focal` 时基准透视系数为 1。
    private let focal: CGFloat = 0.9

    /// 星点分布半径，直接取视口半宽 / 半高 ——
    /// 用 `min(w, h)` 会让横屏宽幅的左右两侧空掉一大片。
    private let halfWidth: CGFloat
    private let halfHeight: CGFloat

    /// 分布填充系数。略小于 1，让最外圈有一点星被裁出画面：
    /// 严丝合缝地铺满会在边缘形成一条肉眼可见的"星星截止线"。
    private let fill: CGFloat = 0.94

    /// 相机推进把深度压掉多少。
    private let dollyDepth: CGFloat = 0.26

    /// 视差的最大横移量，占分布半径的比例。
    private let tiltGain: CGFloat = 0.10

    /// 位置位移的透视压缩指数。
    private let positionExponent: CGFloat = 0.35

    /// 尺寸的透视压缩指数。
    private let sizeExponent: CGFloat = 0.60

    /// 视点的高度比例。略高于几何中心 —— 从下方仰视穹顶比正中平视更像"星空顶"。
    private let centerYRatio: CGFloat = 0.44

    init(viewport: CGSize) {
        self.viewport = viewport
        self.halfWidth = viewport.width / 2
        self.halfHeight = viewport.height / 2
    }

    func project(_ star: Star, camera: StarfieldCamera) -> ProjectedStar? {
        let depth = star.z - camera.dolly * dollyDepth

        // 相机已经穿过它（或贴到眼前）：剔除。
        // 不剔除的话会除以接近 0 的数，得到一颗占满整屏的白色巨物。
        guard depth > 0.12 else { return nil }

        let rawScale = focal / depth
        let positionScale = compressed(rawScale, exponent: positionExponent)
        let sizeScale = compressed(rawScale, exponent: sizeExponent)

        let center = CGPoint(x: halfWidth, y: viewport.height * centerYRatio)

        // 视差：相机横移，而近处的星位移更大 —— 这一点由 positionScale 自动完成，
        // 不需要按深度再写一遍分层逻辑。
        let offsetX = camera.tiltX * halfWidth * fill * tiltGain
        let offsetY = camera.tiltY * halfHeight * fill * tiltGain

        return ProjectedStar(
            position: CGPoint(
                x: center.x + (star.x * halfWidth * fill - offsetX) * positionScale,
                y: center.y + (star.y * halfHeight * fill - offsetY) * positionScale
            ),
            radius: star.baseRadius * sizeScale,
            opacity: perceivedOpacity(star.brightness * depthFalloff(depth))
        )
    }

    private func compressed(_ value: CGFloat, exponent: CGFloat) -> CGFloat {
        CGFloat(pow(Double(value), Double(exponent)))
    }

    /// 感知提亮。
    ///
    /// 亮度、深度衰减、闪烁三个系数相乘之后，中位数会掉到 0.5 附近 ——
    /// 在近黑底上那就是一片灰点，不像星星。
    ///
    /// 取 `0.72` 次幂把中间调抬起来，同时保住暗端的层次（`0` 仍然是 `0`）。
    /// 这不是"调好看"的玄学：亮底暗前景与暗底亮前景本来就需要不同的 gamma，
    /// 线性叠加出来的中间调在感知上是偏暗的。
    private func perceivedOpacity(_ combined: CGFloat) -> Double {
        guard combined > 0 else { return 0 }
        return pow(Double(combined), 0.72)
    }

    /// 远处的星更淡。
    ///
    /// 没有这层，远处的星会和近处的一样实，纵深立刻塌掉 ——
    /// 因为"远"在二维投影上唯一的线索就是尺寸，而尺寸差异在密集星海里很容易被忽略。
    ///
    /// 衰减下限只到 0.60：再暗下去远处的星就整片消失了，星海会显得比实际稀疏。
    private func depthFalloff(_ depth: CGFloat) -> CGFloat {
        let normalized = min(max((depth - 0.3) / 1.1, 0), 1)
        return 1 - normalized * 0.40
    }
}

/// 星表的生成与闪烁计算。全是纯函数，不持有状态。
enum StarfieldModel {

    /// 星点数量。
    ///
    /// 600 是在模拟器 letterbox（362×204 点）上肉眼确认"够密"之后定下的值。
    /// 走昂贵路径的只有 `role == .bright` 的那一小撮（约 12%），
    /// 其余全走合并 Path 的批量填充，所以这个数量在 4K 上也不构成压力。
    static let defaultCount = 600

    /// 亮星的亮度阈值。约 12.5%（600 颗里约 75 颗）会超过它。
    ///
    /// 这个比例不是拍的：亮星每颗要画一层径向渐变光晕，75 颗对应每帧
    /// 约 10 万像素的渐变填充，相对 4K 的 830 万像素可以忽略；
    /// 再往上调（比如把阈值降到 0.85，占比翻倍）就开始看得见掉帧。
    private static let brightThreshold: CGFloat = 0.90

    /// 带十字光芒的亮度阈值。只有最亮的那几颗有，实测约 3%。
    private static let spikeThreshold: CGFloat = 0.96

    /// 生成星表。固定种子 → 同一组星在每次启动、每台设备上都完全一致。
    static func makeStars(count: Int = defaultCount, seed: UInt64 = 20_260_924) -> [Star] {
        guard count > 0 else { return [] }
        var generator = SeededGenerator(seed: seed)
        var stars: [Star] = []
        stars.reserveCapacity(count)

        for _ in 0..<count {
            // 亮度走**幂律**：多数偏暗，少数很亮。
            //
            // 指数取 1.7 而不是更陡的值 —— 指数一大，中位数亮度会掉到三四成，
            // 再乘上深度衰减与闪烁系数，绝大多数星只剩两成不透明度，
            // 在近黑的底上等于看不见，"星星海"会退化成"几颗孤星"。
            // 分布要偏，但不能偏到把大部分星直接抹掉。
            let brightnessRoll = pow(CGFloat.random(in: 0...1, using: &generator), 1.7)
            let brightness = 0.50 + brightnessRoll * 0.50

            // 尺寸与亮度**正相关**。
            //
            // 除了物理上说得通（亮星过曝扩散，看起来更大），它还能挡掉一种
            // 很难看的组合：半径 4pt 却只有三成不透明度的灰斑 ——
            // 那看起来像污渍，不像星。
            let sizeJitter = pow(CGFloat.random(in: 0...1, using: &generator), 2.0)
            let baseRadius = 0.55 + brightnessRoll * 1.25 + sizeJitter * 1.05

            stars.append(
                Star(
                    x: CGFloat.random(in: -1...1, using: &generator),
                    y: CGFloat.random(in: -1...1, using: &generator),
                    z: 0.6 + CGFloat.random(in: 0...1, using: &generator) * 0.8,
                    baseRadius: baseRadius,
                    brightness: brightness,
                    twinklePhase: CGFloat.random(in: 0...(2 * .pi), using: &generator),
                    twinkleSpeed: 0.5 + CGFloat.random(in: 0...1, using: &generator) * 1.6,
                    // 三次幂：暖色只是零星点缀。全冷会像 LED 灯带，全暖会像旧照片。
                    warmth: pow(CGFloat.random(in: 0...1, using: &generator), 3),
                    role: brightness > brightThreshold ? .bright : .speck
                )
            )
        }

        return stars
    }

    /// 这颗星是否带十字光芒。
    ///
    /// 与 `role` 分开：亮星都走光晕路径，但只有最亮的那几颗配得上光芒。
    /// 光芒线长是半径的 5 倍多，给太多星画会让整片星海长满"刺"。
    static func hasSpikes(_ star: Star) -> Bool {
        star.role == .bright && star.brightness > spikeThreshold
    }

    /// 单颗星的闪烁系数，落在 `0.82...1`。
    ///
    /// 每颗星的相位与频率都不同 —— **同步呼吸是"假"的第一来源**，
    /// 真实的星空不会整片一起眨眼。下限取 0.82 而不是 0：
    /// 闪到全灭会让星海看起来在抖，而不是在闪；
    /// 而且闪烁是乘在已经偏暗的亮度上的第三个衰减系数，幅度大了整片会一起变灰。
    static func twinkle(for star: Star, at time: Double) -> Double {
        let phase = Double(star.twinklePhase) + time * Double(star.twinkleSpeed)
        let wave = sin(phase) * 0.5 + 0.5
        return 0.82 + wave * 0.18
    }
}
