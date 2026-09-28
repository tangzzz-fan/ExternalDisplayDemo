import SwiftUI

/// 全景素材条：外接屏上「hero 与瀑布流之间」那条素材选择入口。
///
/// ## 它解决的是"绕过卡片"
/// `01` 的「只看全景」筛选改的是**幕墙上摆哪些卡**；这条改的是**直接看哪张素材**。
/// 演示时不必先滚到某张全景卡、再点它 —— 条子上五条一览，点哪条进哪条。
/// 两者不互相替代（那个是过滤集合，这个是入口），所以条子的内容**不随筛选变**。
///
/// ## 只画不算
/// 与 `WaterfallColumnView` 同一条纪律：槽位落位与命中判定全在
/// `PanoramaStripGeometry`（纯函数、可断言），这里只把结果摆出来。
/// 而且落位用的 `slotWidth` / `spacing` / `leftInset` **就是**几何里那几个数 ——
/// 视图与命中不共享同一组常量的话，会出现"环画在这一条上、点下去进的是另一条"，
/// 而静态截图完全看不出来（环确实画出来了，只是画错了地方）。
///
/// ## 为什么用 `HStack` 而不是绝对定位
/// 槽位是**等宽等距**的一排，`HStack(spacing:)` 加上左右各一份 `leftInset`
/// 拼出来的正是那条 `n × slotWidth + (n − 1) × spacing = fieldWidth` 的等式 ——
/// 与 `WaterfallColumnView` 用 `VStack` 拼列高是同一种写法。
/// 绝对定位反而要额外解释"`.offset` 不改变布局尺寸"那层语义。
///
/// ## 它是第三类可命中元素
/// 与卡片、返回按钮同一套驱动方式：外接屏收不到触摸（见 `ExternalDisplayRootView`），
/// 所以这里一个手势都没有，命中由渲染侧按手机端送来的指针落点算（`handleTap`）。
struct PanoramaStripView: View {

    /// 条子上列出的素材，顺序即槽位顺序。
    let assets: [PanoramaAsset]

    let geometry: PanoramaStripGeometry

    /// 指针当前压在第几条上（`nil` = 指针不在屏上，或没压在条子上）。
    ///
    /// 与卡片的 `focusedID` 同源：由渲染侧每帧现算，视图不做命中判定。
    let focusedIndex: Int?

    /// 已确认选中的那条所对应的卡片 id。
    ///
    /// 存 id 而不是条子下标：`openDetail` 本来就会写 `RemoteControl.selectedItemID`，
    /// 于是"从卡片点进去"与"从条子点进去"落到的是同一个状态 ——
    /// 条子因此不新增任何共享状态，它是已有选择的一个**额外入口**。
    let selectedItemID: Int?

    var body: some View {
        HStack(spacing: geometry.spacing) {
            ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                slot(asset, index: index)
                    .frame(width: geometry.slotWidth, height: geometry.height)
            }
        }
        // 左右各一份 `leftInset`：于是条子的两端与瀑布流最外两列严格对齐。
        // 这个量与 `WaterfallFocus.fieldOrigin.x` 同源（都是"视口宽 − 排布区宽"的一半），
        // 条子与瀑布流因此看起来是同一块板上的两个区，而不是两个各自居中的东西。
        .padding(.horizontal, geometry.leftInset)
        .frame(width: geometry.viewport.width, height: geometry.height, alignment: .leading)
        // 外接屏收不到触摸，这是如实声明 —— 与返回按钮同一句。
        .allowsHitTesting(false)
    }

    // MARK: - 槽位

    /// 选中态优先于悬浮态 —— 与卡片同一条规则（两张同时被踩中时画选中那一种）。
    @ViewBuilder
    private func slot(_ asset: PanoramaAsset, index: Int) -> some View {
        let radius = geometry.base * 0.022
        let isSelected = asset.itemID == selectedItemID
        let isFocused = !isSelected && index == focusedIndex

        let body = VStack(spacing: 0) {
            thumbnail(asset)
            label(asset)
                .frame(height: labelHeight)
        }
        .frame(width: geometry.slotWidth, height: geometry.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }

        // 环与光晕只画在命中的那一 / 两条上 —— 与卡片同一条取舍：
        // 给所有槽位都挂一层"透明度为 0"的阴影，等于每个槽位每帧多一个离屏合成图层。
        if isFocused || isSelected {
            body
                .overlay { ring(cornerRadius: radius, isSelected: isSelected) }
                .modifier(FocusGlow(isSelected: isSelected, base: geometry.base))
        } else {
            body
        }
    }

    // MARK: - 缩略图

    /// 缩略图。取不到素材时回落占位底。
    ///
    /// ## 素材缺失**不是错误**
    /// 素材是可选资源（`PanoramaAssetCatalog.url` 判的是文件在不在），
    /// 没跑过获取脚本的机器上那个目录整个不存在。这时条子照样列满五条、
    /// 照样能点进去（全景页回落程序化网格），只是缩略图位置画占位底。
    /// 把它做成"素材缺失就整条不显示"会让这个功能在没素材的机器上凭空消失，
    /// 而那正是"看起来像没做"的最坏表现。
    ///
    /// ## 降采样尺寸按槽宽算
    /// 槽位只有视口的若干分之一宽，而素材宽 3840。不降采样的话每次求值
    /// 都要解一张全尺寸 JPEG（约 30 MB 位图），五条就是 150 MB ——
    /// 而它每帧都会被问到（滚动、拖动都会触发重算）。`×3` 是给 3x 屏留的余量。
    @ViewBuilder
    private func thumbnail(_ asset: PanoramaAsset) -> some View {
        if let image = PanoramaImageStore.thumbnail(
            named: asset.fileName,
            maxPixelSize: geometry.slotWidth * 3
        ) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                // 编号压在缩略图左上角，与卡片的编号角标同一位置 ——
                // 于是"条子第几条指向哪张卡"在截图上一眼可对（编号就是卡片 id）。
                .overlay(alignment: .topLeading) {
                    Text(String(format: "%02d", asset.itemID))
                        .font(.system(size: geometry.base * 0.030, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(geometry.base * 0.016)
                        .shadow(color: .black.opacity(0.7), radius: geometry.base * 0.01)
                }
        } else {
            placeholder(asset)
        }
    }

    /// 素材缺失时的占位底。图标标出这一条**本来会走哪种几何** ——
    /// 缩略图看不出来，但"点进去是球面还是柱面"恰恰是这一条最要紧的信息。
    private func placeholder(_ asset: PanoramaAsset) -> some View {
        WallMaterial.plate
            .overlay {
                Image(systemName: asset.projection == .equirect ? "globe" : "panorama")
                    .font(.system(size: geometry.base * 0.06, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.30))
            }
            .overlay {
                Rectangle()
                    .strokeBorder(
                        .white.opacity(0.12),
                        style: StrokeStyle(lineWidth: 1, dash: [geometry.base * 0.012, geometry.base * 0.010])
                    )
            }
    }

    // MARK: - 文案行

    /// 底栏：短名 + 投影图标。
    ///
    /// 短名走 `minimumScaleFactor` 而不是截断：模拟器 letterbox 那一档槽宽只有
    /// 六十来点，"eso adaptive optics" 全写不下，截断之后五条里会有一条只剩
    /// "eso ada…" —— 而**区分**这五条靠的正是名字。
    private func label(_ asset: PanoramaAsset) -> some View {
        HStack(spacing: geometry.base * 0.014) {
            Text(asset.displayName)
                .font(.system(size: geometry.base * 0.034, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Spacer(minLength: 0)

            Image(systemName: asset.projection == .equirect ? "globe" : "panorama")
                .font(.system(size: geometry.base * 0.030, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, geometry.base * 0.018)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // 与卡片底栏同一层半透深底：一块板上不该有第二种底色。
        .background(WallMaterial.plate.opacity(WallMaterial.cardFillOpacity))
    }

    /// 文案行高度。
    ///
    /// 上下都夹：下限保证即使条子被压得很矮（模拟器 letterbox 上是 34pt）
    /// 文字也还放得下；上限防止高清屏上文案行被拉成一块和缩略图一样高的板。
    private var labelHeight: CGFloat {
        min(
            max(geometry.height * 0.32, geometry.base * 0.055),
            geometry.base * 0.09
        )
    }

    // MARK: - 焦点环

    /// 与卡片共用同一组比例（`FocusPalette`）：悬浮一圈白、选中一圈红。
    /// 这两处若各写一套，表现是"条子的选中态比卡片的淡"，看起来像两套设计混在一起。
    private func ring(cornerRadius: CGFloat, isSelected: Bool) -> some View {
        let gap = geometry.base * FocusPalette.gapRatio

        return RoundedRectangle(cornerRadius: cornerRadius + gap, style: .continuous)
            .strokeBorder(
                isSelected ? LaserPalette.core : .white.opacity(0.45),
                lineWidth: geometry.base * (isSelected
                    ? FocusPalette.selectedLineRatio
                    : FocusPalette.hoverLineRatio)
            )
            .padding(-gap)
    }
}

#Preview {
    GeometryReader { geometry in
        let assets = PanoramaAssetCatalog.assets(in: WaterfallItem.demoItems(count: 36))
        let strip = PanoramaStripGeometry(
            viewport: geometry.size,
            fieldWidth: geometry.size.width - 2 * min(geometry.size.width, geometry.size.height) * 0.07,
            base: min(geometry.size.width, geometry.size.height),
            count: assets.count,
            originY: 0
        )

        PanoramaStripView(
            assets: assets,
            geometry: strip,
            focusedIndex: 1,
            selectedItemID: assets[2].itemID
        )
    }
    .background(.black)
    .ignoresSafeArea()
}
