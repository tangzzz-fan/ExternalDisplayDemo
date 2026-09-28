import SwiftUI

/// 程序化 equirect 源：经纬网 + 度数标签 + 一个**独一无二**的经度标记。
///
/// ## 它为什么是直线的
/// V1 的投影模型就是线性的（spec §4.2）：equirect 的横轴与经度成正比、
/// 纵轴与纬度成正比。所以画出来的经纬网**本该**是等间距直线 ——
/// 网格与几何是同一套假设，一眼就能看出"这一格是不是 15°"。
///
/// 将来换成真球面（分条带 `tan` 校正）时，网格要改成"越靠两极越密"的版本：
/// **两者的差异正好是那次近似的误差本身**。这张图于是从"占位"升级成
/// "投影正确性的对照物" —— 这是它不退场的理由（spec §4.6）。
///
/// ## 那个独一无二的标记
/// `look = 0` 与 `look = 360` 是否逐像素一致、`look = 90/180/270` 时内容
/// 是否落到理论位置 —— 这些判据都要有一个**可复现的参考物**。实景照片里
/// 找不到，所以 0° 经线画一条暖红色粗线 + 顶部箭头 + 赤道处圆点，
/// 它在截图里是唯一的，量它就行。
///
/// ## 它同时是"动画帧源"的底（票 `05`）
/// 带上 `phase` 之后，本视图就是 `PanoramaAssetSource.animated` 那一档：
/// 一条扫描带在经度空间里扫过，**经纬线一个点不动** ——
/// 因为会动的只有带子，而线的位置由本视图内部的公式给出，与相位无关。
///
/// 不另起一个视图来画动画，是为了让两张不同时刻的截图**共用同一套参照物**：
/// 判读只需要看"线还在不在原处"，不必先把两套坐标系对齐。
struct EquirectSourceCanvas: View {

    /// 经线间隔（度）。360 能被它整除，接缝处不会出现半格。
    private static let meridianStep = 15

    /// 纬线间隔（度）。
    private static let parallelStep = 15

    /// 赤道上的度数标签间隔。
    private static let labelStep = 30

    /// 动画相位，`0..<1`；`nil` = 静态。
    ///
    /// 有相位时这一帧比静态版多一条扫描带，在**经度空间**里扫过。
    /// **经纬线的位置一个点不动** —— 这正是票 `05` 要证的事：帧变了，几何不变。
    ///
    /// ## 为什么变化刻意只做"一条带子"，不做全帧色相漂移
    /// 试过让底色随相位转色相 —— 那看着更像"一帧活的内容"，但它把**整幅图**
    /// 都改了，于是"线没动"这件事在逐像素比对里被淹没：两张不同时刻的截图
    /// 处处都有差异，结论退化成"看着像"。
    ///
    /// 只动一条带宽 `sweepSpan` 的带子，差异就被**限制在一个竖直条带里**，
    /// 于是有两件事可以真判：
    /// - `.animated` 与 `.grid` 在带子之外**逐像素相同**；
    /// - 两个不同相位之间，差异区域的宽度就是一条带子。
    /// 两条都指向同一个结论：会变的东西是"内容"，不是"几何"。
    var phase: Double?

    var body: some View {
        Canvas { context, size in
            draw(&context, size: size)
        }
        .foregroundStyle(Self.label)
    }

    // MARK: - 绘制

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let line: CGFloat = max(1, size.height * 0.0016)
        let equatorY: CGFloat = size.height / 2

        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Self.background)
        )

        // 扫描带画在网格**之下**：会动的在下、不会动的在上，
        // 于是"经纬线一个点没动"在截图里是**看得见**的 ——
        // 带子经过的地方，线照样压在上面、一个像素不挪。
        if let phase {
            drawSweep(&context, size: size, phase: phase)
        }

        drawParallels(&context, size: size, lineWidth: line)
        drawMeridians(&context, size: size, lineWidth: line)
        drawEquator(&context, size: size, y: equatorY, lineWidth: line)
        drawLabels(&context, size: size, equatorY: equatorY)
        drawZeroMeridian(&context, size: size, lineWidth: line)
    }

    // MARK: - 动画帧源（票 05）

    /// 扫描带跨多少经度。
    private static let sweepSpan: CGFloat = 30

    private func drawSweep(_ context: inout GraphicsContext, size: CGSize, phase: Double) {
        let wrapped = phase.truncatingRemainder(dividingBy: 1)
        let longitude = (wrapped < 0 ? wrapped + 1 : wrapped) * 360
        let x = CGFloat(longitude) / 360 * size.width
        let band = size.width * (Self.sweepSpan / 360)

        // 画三份：经度是**环**上的坐标，扫描带跨过左右边缘时要绕回来。
        // 只画一份的话，扫到接缝处会有半帧"带子凭空断掉"。
        for offset in [-size.width, 0, size.width] {
            let rect = CGRect(x: x + offset - band / 2, y: 0, width: band, height: size.height)
            context.fill(Path(rect), with: .color(Self.sweep))
        }
    }

    private func drawParallels(_ context: inout GraphicsContext, size: CGSize, lineWidth: CGFloat) {
        for latitude in stride(from: -90, through: 90, by: Self.parallelStep) {
            let y = CGFloat(90 - latitude) / 180 * size.height
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(Self.grid), lineWidth: lineWidth)
        }
    }

    private func drawMeridians(_ context: inout GraphicsContext, size: CGSize, lineWidth: CGFloat) {
        for longitude in stride(from: 0, to: 360, by: Self.meridianStep) {
            let x = CGFloat(longitude) / 360 * size.width
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(Self.grid), lineWidth: lineWidth)
        }
    }

    /// 赤道单独描一条更亮的：它是 pitch 的零点，读数与截图都拿它当基准。
    private func drawEquator(
        _ context: inout GraphicsContext,
        size: CGSize,
        y: CGFloat,
        lineWidth: CGFloat
    ) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(path, with: .color(Self.equator), lineWidth: lineWidth * 1.6)
    }

    private func drawLabels(_ context: inout GraphicsContext, size: CGSize, equatorY: CGFloat) {
        let fontSize: CGFloat = max(9, size.height * 0.026)

        for longitude in stride(from: 0, to: 360, by: Self.labelStep) {
            let x = CGFloat(longitude) / 360 * size.width
            let text = Text("\(longitude)°")
                .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
            context.draw(
                text,
                at: CGPoint(x: x, y: equatorY - fontSize * 0.9),
                anchor: .center
            )
        }
    }

    /// 0° 经线：粗线 + 顶部箭头 + 赤道圆点。整幅图里只有它长这样。
    private func drawZeroMeridian(
        _ context: inout GraphicsContext,
        size: CGSize,
        lineWidth: CGFloat
    ) {
        let markerWidth = lineWidth * 3

        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        context.stroke(path, with: .color(Self.marker), lineWidth: markerWidth)

        let arrow = size.height * 0.045
        var head = Path()
        head.move(to: CGPoint(x: 0, y: arrow))
        head.addLine(to: CGPoint(x: -arrow * 0.42, y: 0))
        head.addLine(to: CGPoint(x: arrow * 0.42, y: 0))
        head.closeSubpath()
        context.fill(head, with: .color(Self.marker))

        let dot = size.height * 0.012
        context.fill(
            Path(ellipseIn: CGRect(x: -dot, y: size.height / 2 - dot, width: dot * 2, height: dot * 2)),
            with: .color(Self.marker)
        )
    }

    // MARK: - 配色

    private static let background = Color(red: 0.055, green: 0.065, blue: 0.095)
    private static let grid = Color(red: 0.62, green: 0.72, blue: 0.86).opacity(0.30)
    private static let equator = Color(red: 0.70, green: 0.82, blue: 0.96).opacity(0.62)
    private static let label = Color(red: 0.80, green: 0.88, blue: 0.98).opacity(0.78)
    private static let marker = Color(red: 1.0, green: 0.21, blue: 0.25)
    private static let sweep = Color(red: 1.0, green: 0.56, blue: 0.16).opacity(0.34)
}
