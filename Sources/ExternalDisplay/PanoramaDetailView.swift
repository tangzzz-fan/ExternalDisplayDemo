import SwiftUI

/// 全景详情页：外接屏上的第三页。
///
/// ## 它跟 `PhotoDetailView` 不是同一个东西
/// 照片详情页是「平移一张平面的图」；全景页是「在一个包围你的表面上移动一个窗口」。
/// 平面的两个方向在这里不再对等 —— 水平是恒等（equirect 的横轴就是经度），
/// 垂直是近似。所以它是**新视图**而不是给 `PhotoDetailView` 加分支：
/// 混在一起会让 `PhotoDetailGeometry` 里长出角度概念（spec §4.4 / 票 `03` 的落点）。
///
/// ## 只画不算
/// 几何一行都不在这里：`EquirectProjection` 算出贴图多大、摆在哪、要画几份，
/// 本视图只把它摆出来。纯函数能被断言，视图不能 —— 所以能推出去的全推出去。
///
/// ## 接缝
/// 一份贴图铺不满一整圈（`fov ≤ 180` 时最多占半圈），所以横向要画 `tileCount` 份
/// 绕回来的内容。不画它，转到接缝就会露出底色 —— 而 360° 内容本该无缝衔接，
/// 这是它与普通宽幅图最直观的差别。
struct PanoramaDetailView: View {

    let item: WaterfallItem

    /// 详情页的查看集合。素材查表要按"同投影内的出现序号"铺开，
    /// 所以要看到全集 —— 筛选只影响幕墙上摆哪些卡（见 `ExternalDisplayRootView`）。
    let items: [WaterfallItem]

    let viewport: CGSize

    /// 画面短边。所有排版按它等比缩放，与其余视图同一套口径。
    let base: CGFloat

    /// 当前视角。权威在 `RemoteControl`，本视图只读。
    ///
    /// 口径是**朝向**（票 `09`）：视口正中显示的就是 `yaw` 那条经线。
    let look: PanoramaLook

    /// 视场（度）—— 这一窗横跨多少经度。权威在 `RemoteControl.panoramaFOV`。
    ///
    /// 它同时决定两件事，所以不能是视图自己的局部状态：
    /// 贴图要放大多少倍（`displayWidth = vw × 360/fov`），以及纵向能走多远
    /// （`maxPitch = (1 − vh/Dh) × 90`，`Dh` 又由 `displayWidth` 推出）——
    /// 后者是每帧回写 `RemoteControl` 的那个量，两边算的不是同一个 fov 就会形成
    /// "回写完又被夹回去"的抖动。
    let fov: CGFloat

    /// 帧源档位（票 `05` 起是四档：网格 / 真实素材 / 视频抽帧 / 动画纹理）。
    let source: PanoramaAssetSource

    /// 整屏动画总开关（`DisplayContentStore.isAnimated`）。
    ///
    /// 与 `phase` 是两个正交的开关：这个管"整块屏要不要动"，
    /// 那个管"动到哪一帧停住"。动画帧源要同时看这两个 ——
    /// 只关其中一个都还能截出可复现的一帧。
    let isAnimated: Bool

    /// 动画纹理的**冻结相位**（`0..<1`）；`nil` = 逐帧推进。
    let phase: Double?

    /// 最近一帧的**原始姿态读数**（度）；`nil` = 当前没有姿态源（触控板模式就是这样）。
    ///
    /// 纯诊断量，不进任何几何 —— 它是票 `08` 那条真机反馈的判读依据，见 `badge`。
    let raw: AttitudeReading?

    /// 把夹取后的 pitch 回写给共享状态（与 `PhotoDetailView.onClampPan` 同一条纪律）。
    let onClampPitch: (CGFloat) -> Void

    var body: some View {
        let projection = EquirectProjection(viewport: viewport, fov: fov, look: look)

        ZStack(alignment: .topLeading) {
            ForEach(0..<projection.tileCount, id: \.self) { index in
                tile(at: index, projection: projection)
            }
        }
        // 与 `contentColumn` 同一个坑：ZStack 的尺寸被最大的子视图（整张贴图）撑大，
        // 而 `.frame` 默认居中 —— 不显式写 `.topLeading`，贴图会被往上顶掉半个差值，
        // 画面看起来"莫名从赤道附近开始"。
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .clipped()
        // 兜底色。贴图之外的任何缝隙都该是黑的，而不是透出底下的星海 ——
        // 星海是幕墙的语言，出现在全景页里会被误读成"渲染漏了一块"。
        .background(Color.black)
        .overlay(alignment: .bottomLeading) { badge }
        .allowsHitTesting(false)
        .onAppear { clampPitch(projection) }
        .onChange(of: look) { _, newValue in
            clampPitch(EquirectProjection(viewport: viewport, fov: fov, look: newValue))
        }
        // 换档位会改 `Dh`，可达的 pitch 范围跟着变 —— 宽窗口下走到头的位置，
        // 换窄窗口之后可能已经越界。少这一次夹取，画面会停在越界处
        // （贴图边缘露白），而要等下一次动视角才被拉回来。
        .onChange(of: fov) { _, _ in
            clampPitch(EquirectProjection(viewport: viewport, fov: fov, look: look))
        }
    }

    // MARK: - 贴图

    /// 第 `index` 份贴图。`index = 0` 是主份，其余是绕回来补接缝的。
    private func tile(at index: Int, projection: EquirectProjection) -> some View {
        let size = CGSize(width: projection.displayWidth, height: projection.displayHeight)
        let x = projection.originX + CGFloat(index) * projection.displayWidth
        let y = projection.originY

        return content(size: size)
            .frame(width: size.width, height: size.height)
            .offset(x: x, y: y)
    }

    /// 贴图内容 —— 由 `source` 决定像素从哪来。
    ///
    /// ## 这里一个几何量都没有
    /// 位置与尺寸全部来自 `tile(at:projection:)` 算好的 `frame` + `offset`，
    /// 本函数只回答"画什么像素"。所以**加一档帧源不可能挪动画面** ——
    /// 票 `05` 那条"帧源与几何解耦"就是靠这个分工成立的，
    /// 而不是靠"改完之后量一遍发现没挪"。
    ///
    /// ## 取不到就回落网格
    /// `real` 与 `frame` 都是**可选资源**（素材目录在 gitignore 下，没跑过获取／
    /// 抽帧脚本的机器上根本没有）。取不到就画网格 —— 与其余素材同一条退路：
    /// 少一张图，不该变成一片黑。
    @ViewBuilder
    private func content(size: CGSize) -> some View {
        switch source {
        case .real:
            if let image = assetImage {
                tileImage(image)
            } else {
                EquirectSourceCanvas()
            }
        case .frame:
            if let image = frameImage {
                tileImage(image)
            } else {
                EquirectSourceCanvas()
            }
        case .grid:
            EquirectSourceCanvas()
        case .animated:
            animatedTexture
        }
    }

    private func tileImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            // 贴图常被放大到数倍视口宽（`displayWidth = viewport.width × 360 / fov`），
            // 用 `.medium` 换取放大时的平滑，代价是锐度 —— 全景本来就是"看形变"，
            // 不是"看像素"，这个取舍对得上它要验的东西。
            .interpolation(.medium)
    }

    /// 逐帧纹理：内容随时间变，几何线一个点不动。
    ///
    /// ## 相位怎么来
    /// | `isAnimated` | `phase` | 行为 |
    /// |---|---|---|
    /// | `false` | 任意 | 静止在 `phase ?? 0` |
    /// | `true` | 给了值 | 静止在给定相位（截图基线可复现） |
    /// | `true` | `nil` | 跟着显示刷新逐帧推进 |
    ///
    /// 中间那一行是给截图核对用的：动画档要证的判据是"两个不同时刻，
    /// 经纬线还在原处"，而 `TimelineView(.animation)` 取的是挂钟时间、
    /// 两次启动落点不同 ⇒ 没有这一行就只能"看着像"。
    @ViewBuilder
    private var animatedTexture: some View {
        if isAnimated, phase == nil {
            TimelineView(.animation) { context in
                EquirectSourceCanvas(phase: Self.phase(at: context.date))
            }
        } else {
            EquirectSourceCanvas(phase: phase ?? 0)
        }
    }

    /// 一圈扫完要多久（秒）。慢到能看清"线没动"、快到两次刷新之间确实变了。
    private static let cycle: Double = 6

    /// 挂钟时刻 → `0..<1` 相位。
    private static func phase(at date: Date) -> Double {
        let seconds = date.timeIntervalSinceReferenceDate
        let wrapped = seconds.truncatingRemainder(dividingBy: cycle)
        return (wrapped < 0 ? wrapped + cycle : wrapped) / cycle
    }

    /// 真实素材；取不到就返回 `nil`，`content(size:)` 回落网格。
    ///
    /// **素材缺失不是错误**：素材是可选资源（`PanoramaAssetCatalog.url` 判的是
    /// 文件在不在），没跑过获取脚本的机器上它就该走网格。
    ///
    /// 解码与缓存都在 `PanoramaImageStore` —— 这里每次 body 求值都会问它一次，
    /// 而它只在第一次真的去解那张 JPEG。
    private var assetImage: UIImage? {
        guard source == .real else { return nil }
        return PanoramaImageStore.image(for: item, in: items)
    }

    /// 从 360 视频抽出的静帧（票 `05`）。
    ///
    /// 它**按卡片无关**取同一张 —— 抽帧这一档的用途是"验证帧源与几何解耦"，
    /// 而不是"给每张卡配素材"（那是 `.real` 的活）。
    private var frameImage: UIImage? {
        guard source == .frame else { return nil }
        return PanoramaImageStore.image(named: PanoramaAssetCatalog.videoFrameFile)
    }

    // MARK: - 回写

    /// 渲染侧每帧夹一次 pitch 再回写 —— 与 `PhotoDetailGeometry.clamped(_:)` 同一条纪律。
    ///
    /// 夹取**幂等**，所以不形成更新循环：回写后 `look` 变一次，再夹一次不变、不再回写。
    /// Core 层只做 ±90 的护栏，真正可达的范围取决于视口与 fov，只有这里知道。
    private func clampPitch(_ projection: EquirectProjection) {
        let clamped = projection.look.clamped(toPitchLimit: projection.maxPitch)
        guard clamped.pitch != projection.look.pitch else { return }
        onClampPitch(clamped.pitch)
    }

    // MARK: - 页脚

    /// 左下角状态胶囊。与 `PhotoDetailView.badge` 同一语言：
    /// 浮在内容之上的一枚控件，告诉用户现在在哪一页、下一步能做什么。
    ///
    /// 带上 yaw / pitch 与 fov 读数是有意的：截图判读时"`look=90` 那张图里
    /// `90°` 标签落在哪"要靠它对照（票 `09` 之后它落在**视口正中**），
    /// 比对着图猜视角快得多。
    ///
    /// 第二行是**原始姿态读数**（票 `08`）：真机反馈"左右倾几乎没反应"时，
    /// 它把两种可能分开 —— 三个数都不动 ⇒ 姿态没读到；只有 roll 在动 ⇒
    /// 读到了但映射缺一支。两种情形的修法完全不同，而它们在截图上长得一模一样。
    ///
    /// 第三行是退出的说法：全景页的退出只有两个入口（遥控台的「返回」与双击），
    /// 而"能做的事"必须写在这一页上 —— 手机在手里、眼镜屏在眼前，
    /// 用户不会去翻遥控台。
    private var badge: some View {
        let dot: CGFloat = base * 0.013
        let inset: CGFloat = base * 0.045

        return VStack(alignment: .leading, spacing: base * 0.010) {
            HStack(spacing: base * 0.012) {
                Circle()
                    .fill(LaserPalette.core)
                    .frame(width: dot, height: dot)

                Text("全景")
                    .font(.system(size: base * 0.030, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))

                Text(readout)
                    .font(.system(size: base * 0.026, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            if let raw {
                Text(rawReadout(raw))
                    .font(.system(size: base * 0.024, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            Text("双击 = 返回幕墙")
                .font(.system(size: base * 0.024, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, base * 0.022)
        .padding(.vertical, base * 0.013)
        .background(
            .black.opacity(0.45),
            in: RoundedRectangle(cornerRadius: base * 0.022, style: .continuous)
        )
        .padding(inset)
        .shadow(color: .black.opacity(0.5), radius: base * 0.02)
    }

    private var readout: String {
        String(
            format: "%@ · fov %.0f° · yaw %.0f° · pitch %.0f°",
            source.title,
            fov,
            look.yaw,
            look.pitch
        )
    }

    private func rawReadout(_ raw: AttitudeReading) -> String {
        String(
            format: "姿态 yaw %.0f° · pitch %.0f° · roll %.0f°",
            raw.yaw,
            raw.pitch,
            raw.roll
        )
    }
}
