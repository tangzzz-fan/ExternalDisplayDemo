import SwiftUI

/// 瀑布流内容列。
///
/// 布局由 `WaterfallLayout` 这个纯函数算出，这里只负责把结果摆出来 ——
/// 于是"列怎么分、总高多少"可以在没有 UI 的情况下单独验证，
/// 而它恰好是这类视图里最容易算错的部分。
///
/// ## 为什么不用 `LazyVGrid`
/// `LazyVGrid` 是**等高网格**：同一行的所有 cell 高度取该行最高的那个，
/// 剩下的用空白补齐。那是「网格」不是「瀑布流」—— 瀑布流要求每一列的项
/// 独立堆叠、互不对齐，这样才能形成错落的竖列。SwiftUI 没有内置这个布局，
/// 只能自己算。
///
/// ## 没有虚拟化
/// 外接屏侧不能用 `ScrollView`（见 `ExternalDisplayRootView` 的说明），
/// 所以也就没有 `Lazy*` 容器的按需创建。所有卡片一次性建出来。
/// 40~80 张在这个量级完全没问题；真要上百张得自己写回收池。
///
/// ## 左右边距
/// 列排布区（`columnFieldWidth`）比视口**窄** `horizontalInset * 2`，
/// 于是每一列都完整落在屏内，最外两列不再被屏幕边缘切开。
/// 留白由外层那个「视口宽」的 frame 居中让出 —— 这里不做任何裁剪。
struct WaterfallColumnView: View {

    let layout: WaterfallLayout
    let metrics: WaterfallMetrics

    /// 指针当前落在哪张卡上（`nil` = 指针不在屏上，或没落在任何卡片范围内）。
    ///
    /// 由渲染侧每帧现算后传进来，视图自己不做命中判定 —— 那件事需要知道
    /// hero 高度与滚动位移，属于 `WaterfallFocus` 的职责，这里只负责画。
    let focusedID: Int?

    /// 已确认选中的那张卡（轻点 / 扳机），`nil` 表示当前没有选中。
    ///
    /// 与 `focusedID` 是两个独立的状态：指针移开之后选中仍然留着，
    /// 它只由"再次确认"改变。
    let selectedID: Int?

    /// 底栏文案。与 `WaterfallItem.captionCount` 一一对应，
    /// 取用时取模兜底，两处数量对不上也不会崩。
    private static let captions = [
        "内容条目", "精选合集", "编辑推荐", "专题报道", "专栏文章", "图集速览"
    ]

    var body: some View {
        HStack(alignment: .top, spacing: metrics.columnSpacing) {
            ForEach(Array(0..<metrics.columns), id: \.self) { column in
                VStack(spacing: metrics.itemSpacing) {
                    ForEach(layout.columns[column]) { item in
                        card(item)
                    }
                }
                // 每列都锁死列宽并顶对齐，否则列内项数不同会把列高拉开，
                // 短的那列会被 HStack 居中，整片内容出现参差的起始线。
                .frame(width: metrics.columnWidth, alignment: .top)
            }
        }
        .frame(width: metrics.columnFieldWidth, alignment: .top)
        // 外层再套一个**视口宽**的 frame：排布区比它窄，居中放置后两侧各让出
        // `horizontalInset` —— 这就是左右边距。同时让父级 VStack 拿到的宽度
        // 仍然锁死为视口宽，容器不会被撑宽，圆角、阴影、下拉位移都不会跑偏。
        .frame(width: metrics.viewport.width, alignment: .center)
    }

    // MARK: - 卡片

    /// 选中态优先于悬浮态：两张卡同时被指针和选中踩中时，画选中那一种。
    @ViewBuilder
    private func card(_ item: WaterfallItem) -> some View {
        let height = layout.heights[item.id] ?? metrics.unitHeight
        let cornerRadius = metrics.base * 0.018 * item.cornerScale
        let footerHeight = min(
            max(height * 0.30, metrics.base * 0.072),
            metrics.base * 0.095
        )
        let isSelected = item.id == selectedID
        let isFocused = !isSelected && item.id == focusedID

        let body = VStack(spacing: 0) {
            cover(item)
            footer(item)
                .frame(height: footerHeight)
        }
        .frame(width: metrics.columnWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    .white.opacity(item.isFeatured ? 0.30 : 0.10),
                    lineWidth: item.isFeatured ? 1.5 : 1
                )
        }

        // 环与阴影**只画在命中的那一张上**。做成条件分支而不是"给所有卡都挂一层
        // 透明度为 0 的阴影"：后者在 4K 上等于每张卡都多一个离屏合成图层，
        // 36 张全静止也要付这笔钱。分支只让 0 ~ 2 张卡额外绘制。
        if isFocused || isSelected {
            body
                .overlay { focusRing(cornerRadius: cornerRadius, isSelected: isSelected) }
                .modifier(FocusGlow(isSelected: isSelected, base: metrics.base))
        } else {
            body
        }
    }

    /// 焦点环：画在卡片**外面**，与卡片边缘之间留一道空隙。
    ///
    /// 圆角半径跟着 `gap` 一起放大，环与卡片才是同心的一对轮廓；
    /// 只把矩形撑大而不动圆角，四角会出现肉眼可见的"两只角不平行"。
    ///
    /// `.strokeBorder` 而不是 `.stroke`：前者画在形状**内侧**，尺寸就是
    /// `padding(-gap)` 撑出来的那圈，不会往外再多占一个线宽。
    private func focusRing(cornerRadius: CGFloat, isSelected: Bool) -> some View {
        let gap = metrics.base * FocusPalette.gapRatio

        return RoundedRectangle(cornerRadius: cornerRadius + gap, style: .continuous)
            .strokeBorder(
                isSelected ? LaserPalette.core : .white.opacity(0.45),
                lineWidth: metrics.base * (isSelected
                    ? FocusPalette.selectedLineRatio
                    : FocusPalette.hoverLineRatio)
            )
            .padding(-gap)
    }

    /// 封面：主渐变 + 一层同侧高光。
    ///
    /// 只有主渐变的话，卡片看起来像一张纯色贴纸。叠一层从光源方向散开的
    /// 径向高光之后才有了"有光源"的体积感 —— 这一步很便宜，但决定卡片
    /// 是"色块"还是"图"。
    private func cover(_ item: WaterfallItem) -> some View {
        let tone = item.tone

        return LinearGradient(
            colors: [
                Color(
                    hue: tone.hue,
                    saturation: tone.saturation * 0.85,
                    brightness: min(1, tone.brightness * 1.55)
                ),
                Color(
                    hue: tone.hue,
                    saturation: tone.saturation,
                    brightness: tone.brightness * 0.62
                )
            ],
            startPoint: unitPoint(WaterfallItem.gradientStart(for: item.gradientAngle)),
            endPoint: unitPoint(WaterfallItem.gradientEnd(for: item.gradientAngle))
        )
        .overlay {
            RadialGradient(
                colors: [.white.opacity(item.isFeatured ? 0.24 : 0.16), .clear],
                center: UnitPoint(x: item.highlight.x, y: item.highlight.y),
                startRadius: 0,
                endRadius: metrics.columnWidth * 1.1
            )
        }
        .overlay(alignment: .topLeading) {
            Text(String(format: "%02d", item.id))
                .font(.system(size: metrics.base * 0.036, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .padding(metrics.base * 0.022)
        }
    }

    private func footer(_ item: WaterfallItem) -> some View {
        HStack(spacing: metrics.base * 0.016) {
            // 一根按色相着色的小竖条：让"这张卡属于哪个色系"在缩略尺度上也读得出来。
            // 深色中性卡的色相是随机的，这里反而成了一个彩色标记。
            Capsule()
                .fill(Color(hue: item.tone.hue, saturation: 0.7, brightness: 0.85))
                .frame(width: max(1.5, metrics.base * 0.008))

            Text(Self.captions[item.captionIndex % Self.captions.count])
                .font(.system(size: metrics.base * 0.038, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.90))
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            Spacer(minLength: 0)

            Text(String(format: "%.2f×", item.heightWeight))
                .font(.system(size: metrics.base * 0.030, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
        }
        .padding(.horizontal, metrics.base * 0.02)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.white.opacity(item.isFeatured ? 0.10 : 0.05))
    }

    private func unitPoint(_ point: CGPoint) -> UnitPoint {
        UnitPoint(x: point.x, y: point.y)
    }
}

/// 焦点光晕。
///
/// 两态**都是发光**，不是投影 —— 这一层底是 `Color(red: 0.004, ...)` 的近黑，
/// 黑色投影落在上面完全看不见（第一版就是这么写的，截图上一点痕迹都没有）。
/// 近黑底上唯一读得出来的"阴影"是外溢的光，所以这里只换颜色与半径：
/// 悬浮是一圈白，选中是更浓的红再叠一层白把环内侧压实。
///
/// 光晕用 `.shadow(radius:y: 0)` 而不是 `.blur`：前者作用在卡片**轮廓**上，
/// 不会把卡片本身的内容（渐变封面、底栏文字）一起糊掉。
private struct FocusGlow: ViewModifier {

    let isSelected: Bool
    let base: CGFloat

    func body(content: Content) -> some View {
        if isSelected {
            content
                .shadow(color: LaserPalette.core.opacity(0.55), radius: base * 0.050, y: 0)
                .shadow(color: .white.opacity(0.30), radius: base * 0.018, y: 0)
        } else {
            content
                .shadow(color: .white.opacity(0.30), radius: base * 0.030, y: 0)
        }
    }
}

/// 焦点环的几何常量。颜色刻意不放在这里 —— 它们来自 `LaserPalette`，
/// 与外接屏上的光标共用同一套配色，见 `focusRing`。
private enum FocusPalette {

    /// 环与卡片之间的空隙。
    ///
    /// 取值要压得住卡片自己的白描边（1 ~ 1.5pt）：空隙太窄的话，环和卡片轮廓
    /// 会糊成一条粗线，看起来像描边画重了，而不是"这一项被聚焦了"。
    static let gapRatio: CGFloat = 0.012

    /// 环宽。选中比悬浮粗一档 —— 这是"确认过"与"只是扫过"之间最省事的区分。
    static let hoverLineRatio: CGFloat = 0.006
    static let selectedLineRatio: CGFloat = 0.010
}

#Preview {
    GeometryReader { geometry in
        let base = min(geometry.size.width, geometry.size.height)
        let items = WaterfallItem.demoItems(count: 42)
        let metrics = WaterfallMetrics(
            base: base,
            viewport: geometry.size,
            columns: WaterfallMetrics.columnCount(for: geometry.size)
        )

        WaterfallColumnView(
            layout: .make(items: items, metrics: metrics),
            metrics: metrics,
            focusedID: items[3].id,
            selectedID: items[8].id
        )
    }
    .background(.black)
    .ignoresSafeArea()
}
