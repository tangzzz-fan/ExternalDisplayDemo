import SwiftUI

/// 背景墙：劳斯莱斯星空顶式的假 3D 星海。
///
/// ## 它在层次里的位置
/// 永远是最底下一层，且**自己不动** —— 内容容器下拉时让出上半屏，它才露出来。
/// 这样"露出多少"完全由内容的位移决定，星海不需要知道自己被露了多少，
/// 也就不存在两套动画互相对不上相位的问题。
///
/// ## 帧驱动
/// 用 `TimelineView(.animation)` + `Canvas`（内部即 `CADisplayLink`），
/// 与 `DisplayPatternCanvas` 同一套基建 —— 手机端关掉「帧驱动动画」后
/// 外接屏应当立刻静止，这一点同样适用于这里。
///
/// `paused` 挂在 `pull == 0` 上：**没露出来时完全不跑帧**。
/// 不这么做的话，静止在内容后面的星海会一直以 60 Hz 重绘 600 颗星，
/// 白白吃掉外接屏的渲染预算。
struct StarfieldBackdrop: View {

    /// 下拉进度，`0` = 完全被内容盖住，`1` = 上半屏完整露出。
    let pull: CGFloat

    /// 视差倾斜（归一化 `-1...1`），由手机端光标落点推出。
    let tilt: CGPoint

    /// 是否运行帧动画。关掉后星海静止，用于验证帧驱动确实来自本应用。
    let isAnimated: Bool

    private var isActive: Bool { pull > 0.002 && isAnimated }

    var body: some View {
        GeometryReader { geometry in
            let projector = StarfieldProjector(viewport: geometry.size)
            let camera = StarfieldCamera(dolly: pull, tiltX: tilt.x, tiltY: tilt.y)

            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive)) { timeline in
                Canvas { context, size in
                    draw(
                        in: &context,
                        size: size,
                        time: timeline.date.timeIntervalSinceReferenceDate,
                        projector: projector,
                        camera: camera
                    )
                }
            }
        }
        .opacity(fadeIn)
        .allowsHitTesting(false)
    }

    /// 下拉的前 30% 就把星海点亮到位，之后维持。
    ///
    /// 线性淡入会让"露出多少 = 多亮"，于是下拉过程中画面永远差一口气；
    /// 提前亮到位之后，后续下拉才纯粹是"揭开"的动作，观感利落得多。
    private var fadeIn: Double {
        let t = min(max(Double(pull) / 0.3, 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - 绘制

    private func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        projector: StarfieldProjector,
        camera: StarfieldCamera
    ) {
        guard size.width > 0, size.height > 0 else { return }

        drawDome(in: &context, size: size)

        let margin = min(size.width, size.height) * 0.08
        var specks = SpeckBuckets()

        for star in StarCatalog.stars {
            guard let projected = projector.project(star, camera: camera) else { continue }

            // 视口外剔除：相机推进时近处的星会被推到画面外很远，
            // 不剔除的话在 4K 屏上会白白构造一堆屏幕外的形状。
            guard projected.position.x > -margin, projected.position.x < size.width + margin,
                  projected.position.y > -margin, projected.position.y < size.height + margin
            else { continue }

            let opacity = projected.opacity * StarfieldModel.twinkle(for: star, at: time)
            guard opacity > 0.02 else { continue }

            switch star.role {
            case .speck:
                specks.append(star: star, projected: projected, opacity: opacity)
            case .bright:
                drawBrightStar(
                    in: &context,
                    star: star,
                    projected: projected,
                    color: Self.starColor(warmth: star.warmth),
                    opacity: opacity
                )
            }
        }

        // 暗点必须在循环**之后**统一填：它们要先按档位合并成几十条 Path，
        // 见 `SpeckBuckets`。
        specks.fill(into: &context)
    }

    /// 穹顶底色。
    ///
    /// 纯黑背景会让星点看起来贴在玻璃上 —— 这层"中心偏上稍亮的深蓝 → 边缘全黑"
    /// 的径向渐变才是"穹顶"这个空间感的来源。中心放在 `0.40` 高度而不是正中，
    /// 是为了让亮区落在星点最密的地方，同时避开内容容器盖住的下半屏。
    private func drawDome(in context: inout GraphicsContext, size: CGSize) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [
                    Color(red: 0.085, green: 0.105, blue: 0.175),
                    Color(red: 0.030, green: 0.040, blue: 0.080),
                    Color(red: 0.006, green: 0.008, blue: 0.020)
                ]),
                center: CGPoint(x: size.width * 0.5, y: size.height * 0.40),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.80
            )
        )
    }

    /// 亮星：光晕 + 本体 + （可选）十字光芒。
    private func drawBrightStar(
        in context: inout GraphicsContext,
        star: Star,
        projected: ProjectedStar,
        color: Color,
        opacity: Double
    ) {
        let radius = projected.radius
        let position = projected.position

        // 光晕：一层比本体大 2.4 倍的径向渐变。比"再画一个半透明圆"柔和得多，
        // 而且只有亮星才画，成本可控。
        context.fill(
            Path(ellipseIn: CGRect(
                x: position.x - radius * 2.4,
                y: position.y - radius * 2.4,
                width: radius * 4.8,
                height: radius * 4.8
            )),
            with: .radialGradient(
                Gradient(colors: [
                    color.opacity(opacity * 0.30),
                    color.opacity(opacity * 0.07),
                    color.opacity(0)
                ]),
                center: position,
                startRadius: 0,
                endRadius: radius * 2.4
            )
        )

        // 本体
        context.fill(
            Path(ellipseIn: CGRect(
                x: position.x - radius,
                y: position.y - radius,
                width: radius * 2,
                height: radius * 2
            )),
            with: .color(color.opacity(opacity))
        )

        // 十字光芒：只有最亮的那几颗有，且投影后必须够大才画 ——
        // 小尺寸下四个角会糊成一团，反而把星点弄脏。
        guard StarfieldModel.hasSpikes(star), radius > 1.2 else { return }
        drawSpikes(in: &context, at: position, radius: radius, color: color, opacity: opacity)
    }

    /// 四角星光芒。
    ///
    /// 用**一条闭合路径 + 一次径向渐变**画完四个方向，而不是四条各带线性渐变的描边。
    /// 后者要 4 次绘制，且接缝处会出现亮度断层（两端各有一个渐变起点）。
    /// 径向渐变的圆心正好落在星点中心，四个角天然由内向外衰减 —— 一次填充就够。
    private func drawSpikes(
        in context: inout GraphicsContext,
        at center: CGPoint,
        radius: CGFloat,
        color: Color,
        opacity: Double
    ) {
        let length = radius * 5.2
        let waist = max(0.6, radius * 0.22)

        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - length))
        // 控制点朝**内**偏，四段曲线才会向内凹，形成尖角而不是圆角矩形
        path.addQuadCurve(
            to: CGPoint(x: center.x + length, y: center.y),
            control: CGPoint(x: center.x + waist, y: center.y - waist)
        )
        path.addQuadCurve(
            to: CGPoint(x: center.x, y: center.y + length),
            control: CGPoint(x: center.x + waist, y: center.y + waist)
        )
        path.addQuadCurve(
            to: CGPoint(x: center.x - length, y: center.y),
            control: CGPoint(x: center.x - waist, y: center.y + waist)
        )
        path.addQuadCurve(
            to: CGPoint(x: center.x, y: center.y - length),
            control: CGPoint(x: center.x - waist, y: center.y - waist)
        )
        path.closeSubpath()

        context.fill(path, with: .radialGradient(
            Gradient(colors: [
                color.opacity(opacity * 0.85),
                color.opacity(opacity * 0.28),
                color.opacity(0)
            ]),
            center: center,
            startRadius: 0,
            endRadius: length
        ))
    }

    /// 星色：冷白为主，暖白零星点缀。
    static func starColor(warmth: CGFloat) -> Color {
        Color(
            red: 0.86 + Double(warmth) * 0.14,
            green: 0.91 + Double(warmth) * 0.05,
            blue: 1.00 - Double(warmth) * 0.12
        )
    }

    // MARK: - 暗点分批

    /// 暗点的分批累加器。
    ///
    /// ## 为什么必须分批
    /// 600 颗星里九成以上是暗点。逐颗 `fill` 就是每帧 550 次绘制调用 ——
    /// 而它们全是同一种东西：一个 1pt 左右的小圆。合并成几十条 Path 之后
    /// 每帧只剩几十次调用，这是这个视图里唯一真正影响帧预算的优化。
    /// （亮星只有三十来颗，逐颗画无所谓。）
    ///
    /// ## 为什么不是方块
    /// 曾经用 `fill` 小矩形代替圆，理由是"等价于点且更便宜"。实测不成立：
    /// 1.5pt 的方块在 3x 屏上是 4~5 个物理像素，放大后能明确看出是方的，
    /// 整片星海看起来像像素噪点而不是星星。合并成一条 Path 之后画圆的代价
    /// 已经可以忽略，没有任何理由再牺牲形状。
    ///
    /// ## 分档损失
    /// 尺寸 / 不透明度 / 色温各分几档，档位内取统一值。
    /// 在 1~2pt 的尺度上肉眼分辨不出档位之间的差异，
    /// 而档位数直接决定每帧的绘制调用数，所以档位取够用即可。
    private struct SpeckBuckets {

        private static let sizeTiers = 5
        private static let opacityTiers = 6
        private static let warmthTiers = 2

        private static let sizeStep: CGFloat = 0.6

        private var paths = [Path](repeating: Path(), count: sizeTiers * opacityTiers * warmthTiers)
        private var alphas = [Double](repeating: 0, count: sizeTiers * opacityTiers * warmthTiers)

        mutating func append(star: Star, projected: ProjectedStar, opacity: Double) {
            let sizeTier = min(Self.sizeTiers - 1, max(0, Int(projected.radius / Self.sizeStep)))
            let opacityTier = min(Self.opacityTiers - 1, max(0, Int(opacity * Double(Self.opacityTiers))))
            let warmthTier = star.warmth > 0.55 ? 1 : 0
            let index = (sizeTier * Self.opacityTiers + opacityTier) * Self.warmthTiers + warmthTier

            // 档位半径取该档的代表值，而不是每颗星各自的半径
            let radius = 0.40 + CGFloat(sizeTier) * 0.42
            paths[index].addEllipse(in: CGRect(
                x: projected.position.x - radius,
                y: projected.position.y - radius,
                width: radius * 2,
                height: radius * 2
            ))

            // 桶内取最大的那个不透明度：宁可整桶略亮，
            // 也不要让最暗的一颗把整桶拖灰（桶内本来就只有零点几档的差异）。
            alphas[index] = max(alphas[index], opacity)
        }

        func fill(into context: inout GraphicsContext) {
            for index in paths.indices where !paths[index].isEmpty {
                let warmth: CGFloat = index % Self.warmthTiers == 1 ? 1 : 0
                context.fill(
                    paths[index],
                    with: .color(StarfieldBackdrop.starColor(warmth: warmth).opacity(alphas[index]))
                )
            }
        }
    }
}

/// 星表。
///
/// 用 `static let` 而不是 `@State`：`@State` 的初始值表达式在**每次**
/// 视图结构体初始化时都会求值（只是被丢弃），而 `StarfieldBackdrop` 每帧
/// 都在被重建 —— 600 颗星 × 8 次随机调用的开销会被反复付掉。
/// `static let` 是懒加载且只算一次。
private enum StarCatalog {
    static let stars = StarfieldModel.makeStars()
}

#Preview {
    StarfieldBackdrop(pull: 1, tilt: .zero, isAnimated: true)
        .background(.black)
}
