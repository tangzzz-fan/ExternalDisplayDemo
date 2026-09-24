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
struct WaterfallColumnView: View {

    let layout: WaterfallLayout
    let metrics: WaterfallMetrics

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
    }

    // MARK: - 卡片

    private func card(_ item: WaterfallItem) -> some View {
        let height = layout.heights[item.id] ?? metrics.unitHeight
        let footerHeight = min(
            max(height * 0.30, metrics.base * 0.072),
            metrics.base * 0.095
        )

        return VStack(spacing: 0) {
            cover(item)
            footer(item)
                .frame(height: footerHeight)
        }
        .frame(width: metrics.columnWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: metrics.base * 0.018, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.base * 0.018, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }

    /// 封面：主渐变 + 一层斜向高光。
    ///
    /// 只有主渐变的话，卡片看起来像一张纯色贴纸。叠一层从左上角散开的
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
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            RadialGradient(
                colors: [.white.opacity(0.16), .clear],
                center: UnitPoint(x: 0.18, y: 0.12),
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
            // 一根按色相着色的小竖条：让"这张卡属于哪个色系"在缩略尺度上也读得出来
            Capsule()
                .fill(Color(hue: item.tone.hue, saturation: 0.7, brightness: 0.85))
                .frame(width: max(1.5, metrics.base * 0.008))

            Text("内容条目")
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
        .background(.white.opacity(0.05))
    }
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

        WaterfallColumnView(layout: .make(items: items, metrics: metrics), metrics: metrics)
    }
    .background(.black)
    .ignoresSafeArea()
}
