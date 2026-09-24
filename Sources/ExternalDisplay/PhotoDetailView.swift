import SwiftUI

/// 照片详情页：从幕墙点进来之后看到的那一张。
///
/// ## 它只负责画
/// 几何全部由 `PhotoDetailGeometry` 算（纯函数、可独立断言），
/// 状态全部在 `RemoteControl` 里。本视图拿到的是「查看模式 + 行程进度」，
/// 输出的是「照片画多大、画在哪」—— 一处计算都没有。
///
/// ## 为什么每帧要回写一次行程
/// 手机端只能做**保守**夹取：真正可达的行程取决于视口尺寸与照片宽高比，
/// 两者都在渲染侧（见 `RemoteControl.detailPan`）。这里算出可达范围后回写，
/// 反向拖动才不会先"粘"一段。回写是**幂等**的 —— 夹取过的值再夹一次不变，
/// 因此不会形成更新循环。
///
/// ## 照片本体还是渐变
/// 工程里没有真实图片资源（瀑布流卡片同样是渐变占位）。
/// `item.aspectRatio` 就是留给真实相册数据源的接口：接进来之后把这一层
/// 换成 `Image`，几何一行都不用改。
///
/// ## 一处 Swift 编译器的坑
/// 所有尺寸常量都写成了**显式 `CGFloat` 局部量**，且每个子视图各自成属性。
/// 这不是为了好看：把这些 `base * 0.0xx` 的算式直接铺进视图表达式的参数里，
/// 编译器会在类型检查阶段超时（实测报 "unable to type-check this expression
/// in reasonable time"）。字面量的数值类型要参与重载决策，链一长就爆炸 ——
/// 显式标注之后每个子表达式都只剩一种解，编译瞬间就过。
struct PhotoDetailView: View {

    let item: WaterfallItem
    let viewport: CGSize

    /// 画面短边。所有排版按它等比缩放，与其余视图同一套口径。
    let base: CGFloat

    let mode: PhotoViewMode

    /// 归一化行程进度，各分量 `-1...1`。
    let pan: CGSize

    /// 把夹取后的行程回写给共享状态。
    let onClampPan: (CGSize) -> Void

    var body: some View {
        let geometry = PhotoDetailGeometry(
            viewport: viewport,
            aspectRatio: item.aspectRatio,
            mode: mode
        )

        ZStack {
            photo(geometry: geometry)
        }
        // 视口大小的容器 + 居中：照片的"居中"与"平移"因此可以分开表达 ——
        // 居中交给容器，平移只用一个 `.offset`。若把两者都塞进 offset，
        // 平移量一变就要重算居中基准，容易算漏一个分量。
        .frame(width: viewport.width, height: viewport.height, alignment: .center)
        .overlay(alignment: .bottomLeading) { badge(geometry: geometry) }
        .allowsHitTesting(false)
        .onChange(of: pan) { _, newValue in
            let clamped = geometry.clamped(newValue)
            if clamped != newValue { onClampPan(clamped) }
        }
    }

    // MARK: - 照片

    private func photo(geometry: PhotoDetailGeometry) -> some View {
        let size: CGSize = geometry.photoSize
        let offset: CGSize = geometry.offset(for: pan)
        let corner: CGFloat = base * 0.014

        // 每一段都写成显式类型的局部量：Swift 在链式修饰符上做类型检查时，
        // 会把整条链当成**一个**表达式求解。链一长（ZStack 三个子视图 +
        // 四个修饰符），解的搜索空间就爆掉 —— 实测报的是 "unable to
        // type-check this expression in reasonable time"，甚至
        // "failed to produce diagnostic"。分段之后每段只剩一种解。
        let stack: some View = ZStack {
            gradient
            glow(size: size)
            caption
        }
        .frame(width: size.width, height: size.height)

        let clipped: some View = stack
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))

        let bordered: some View = clipped
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: max(1, base * 0.0025))
            }

        // 注意是 `.width` / `.height` 而非 `.x` / `.y`：`offset(for:)` 与断言脚本
        // 一并约定返回 `CGSize`（`offset` 在别处也是这个口径，见 `LateralMetrics`）。
        return bordered
            .shadow(color: .black.opacity(0.55), radius: base * 0.045, y: base * 0.008)
            .offset(x: offset.width, y: offset.height)
    }

    /// 主渐变。与瀑布流卡片同源：同一个方向角、同一个色相 ——
    /// 从卡片点进来时，照片的光向与刚才那张卡一致，观感上才像"同一张东西
    /// 被放大了"，而不是"跳到了另一张图"。
    private var gradient: some View {
        let start: CGPoint = WaterfallItem.gradientStart(for: item.gradientAngle)
        let end: CGPoint = WaterfallItem.gradientEnd(for: item.gradientAngle)

        return LinearGradient(
            colors: [highlightColor, shadowColor],
            startPoint: UnitPoint(x: start.x, y: start.y),
            endPoint: UnitPoint(x: end.x, y: end.y)
        )
    }

    private var highlightColor: Color {
        let tone: WaterfallTone = item.tone
        let saturation: CGFloat = tone.saturation * 0.85
        let brightness: CGFloat = min(1, tone.brightness * 1.55)
        return Color(hue: tone.hue, saturation: saturation, brightness: brightness)
    }

    private var shadowColor: Color {
        let tone: WaterfallTone = item.tone
        let brightness: CGFloat = tone.brightness * 0.62
        return Color(hue: tone.hue, saturation: tone.saturation, brightness: brightness)
    }

    private func glow(size: CGSize) -> some View {
        let peak: Double = item.isFeatured ? 0.22 : 0.14
        let reach: CGFloat = max(size.width, size.height) * 0.8

        return RadialGradient(
            colors: [.white.opacity(peak), .clear],
            center: UnitPoint(x: item.highlight.x, y: item.highlight.y),
            startRadius: 0,
            endRadius: reach
        )
    }

    // MARK: - 照片上的文案

    private var caption: some View {
        VStack(alignment: .leading, spacing: captionSpacing) {
            idText
            Spacer(minLength: 0)
            titleText
            ratioLabel
        }
        .padding(captionPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var idText: some View {
        Text(String(format: "%02d", item.id))
            .font(.system(size: idFontSize, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))
    }

    private var titleText: some View {
        Text(WaterfallColumnView.caption(for: item))
            .font(.system(size: titleFontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.94))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    /// 宽高比的显示形式。
    ///
    /// 直接把比例写在画面上：两种模式的差别完全由它决定，核对几何时
    /// 「这张是 3:2、那张是 9:16」比盯着照片猜要快得多。
    private var ratioLabel: some View {
        Text(ratioText)
            .font(.system(size: ratioFontSize, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.60))
    }

    private var ratioText: String {
        switch item.aspectRatio {
        case 9.0 / 16: return "9:16"
        case 2.0 / 3: return "2:3"
        case 3.0 / 4: return "3:4"
        case 1.0: return "1:1"
        case 4.0 / 3: return "4:3"
        case 3.0 / 2: return "3:2"
        case 16.0 / 9: return "16:9"
        default: return String(format: "比例 %.2f", item.aspectRatio)
        }
    }

    // MARK: - 模式与提示

    /// 左下角的状态胶囊：当前模式 + 下一步能做什么。
    ///
    /// 双击是**不可见**的操作，没有这行提示的话用户只能靠试。
    /// 它与幕墙上的返回按钮同一层次：浮在内容之上的一枚控件。
    private func badge(geometry: PhotoDetailGeometry) -> some View {
        let dot: CGFloat = base * 0.013
        let horizontal: CGFloat = base * 0.022
        let vertical: CGFloat = base * 0.013
        let inset: CGFloat = base * 0.045
        let shadowRadius: CGFloat = base * 0.02

        return HStack(spacing: badgeSpacing) {
            Circle()
                .fill(mode == .fill ? LaserPalette.core : Color.white.opacity(0.7))
                .frame(width: dot, height: dot)

            Text(modeTitle)
                .font(.system(size: modeFontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Text(hint(geometry: geometry))
                .font(.system(size: hintFontSize, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, horizontal)
        .padding(.vertical, vertical)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(inset)
        .shadow(color: .black.opacity(0.5), radius: shadowRadius)
    }

    private var modeTitle: String {
        mode == .fill ? "铺满" : "整图"
    }

    /// 下一步能做什么。**只说真有意义的那个方向** ——
    /// 整图模式下两个方向都没有超出量，这时写"可拖动"是骗人。
    private func hint(geometry: PhotoDetailGeometry) -> String {
        guard mode == .fill else { return "双击 → 铺满" }

        let limit: CGSize = geometry.panLimit
        if limit.width > 0, limit.height > 0 { return "双击 → 整图 · 可拖动查看" }
        if limit.width > 0 { return "双击 → 整图 · 可左右拖动" }
        if limit.height > 0 { return "双击 → 整图 · 可上下拖动" }
        return "双击 → 整图"
    }

    // MARK: - 字号（按短边等比）

    private var captionSpacing: CGFloat { base * 0.008 }
    private var captionPadding: CGFloat { base * 0.035 }
    private var badgeSpacing: CGFloat { base * 0.012 }
    private var idFontSize: CGFloat { base * 0.034 }
    private var titleFontSize: CGFloat { base * 0.042 }
    private var ratioFontSize: CGFloat { base * 0.028 }
    private var modeFontSize: CGFloat { base * 0.030 }
    private var hintFontSize: CGFloat { base * 0.026 }
}
