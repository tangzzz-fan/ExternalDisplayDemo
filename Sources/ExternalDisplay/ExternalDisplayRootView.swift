import Foundation
import SwiftUI

/// 外接屏上渲染的根视图。
///
/// 它有三个宿主，内容完全相同：
/// - **iOS 17~26**：`ExternalDisplaySceneDelegate` 经 `UIHostingController` 挂到外接屏的 `UIWindow`；
/// - **iOS 27+**：`ExternalNonInteractiveAccessory`（见 `ExternalDisplayAccessory`），由系统呈现；
/// - **无硬件时**：`MockExternalDisplay` 在手机屏上叠的替身窗口。
///
/// 所以它不依赖任何宿主专有的东西 —— **分辨率也由它自己量出来**（视口点数 × 屏幕 scale），
/// 而不是等宿主传进来。这样上面三条路一份代码，且不需要 UIKit 的 `UIScreen` / `windowScene`。
///
/// ## 为什么这里一个手势都没有
/// 外接屏的 role 是 `windowExternalDisplayNonInteractive` —— 系统不会向它投递
/// 任何触摸事件（真机上 `window.isUserInteractionEnabled = false`，模拟器 mock 里
/// `PassthroughWindow.hitTest` 恒返回 `nil`），SwiftUI 的 accessory 更是在 API 层面
/// 就叫 `ExternalNonInteractiveAccessory`。
///
/// 所以这个视图是**纯输出**的：它只读 `RemoteControl` 的共享状态，
/// 滚动 / 下拉 / 缩放 / 光标全部由手机端的遥控板写入。在这里加 `ScrollView`
/// 或 `.gesture` 是无效的 —— 手势根本到不了这棵视图树。
///
/// ## 层次
/// ```
/// StarfieldBackdrop        最底层，固定不动；幕墙半透，缝里看到的就是它
/// └ contentColumn          幕墙：一块半透光的板，整体随 scroll/pull/lateral 位移
///   ├ hero                 图案 canvas（帧驱动演示）+ 标题
///   └ WaterfallColumnView  瀑布流卡片
/// ├ hud                    固定，不参与滚动
/// ├ backButton             固定，浮在板上（不随幕墙位移，否则按不到）
/// ├ pointer / ripple       固定，跟随手机端光标
/// ```
///
/// 排版全部按画面短边等比缩放，因此同一份代码在 1080p 真外接屏、
/// 4K 外接屏、以及模拟器的 letterbox 小窗口里都不会溢出或截断。
struct ExternalDisplayRootView: View {

    /// 内容量出自己的**像素**尺寸后回调。
    ///
    /// 只有 iOS 27 的 accessory 路径需要它 —— 那条路没有 scene delegate，
    /// 也就没有 `UIWindowScene` 可查，手机端的连接状态只能由这里上报。
    /// 另外两条路的宿主自己就能拿到更准的 nativeBounds，都传 `nil`。
    var onMetricsChange: ((_ pixelSize: CGSize, _ nativeScale: CGFloat) -> Void)?

    /// 外接屏自己的缩放比：accessory 内容读到的就是这个 window 所在屏幕的值。
    @Environment(\.displayScale) private var displayScale

    private let store = DisplayContentStore.shared
    private let remote = RemoteControl.shared
    private let airMouse = AirMouse.shared

    /// 轻点反馈的涟漪。
    @State private var rippleScale: CGFloat = 0.35
    @State private var rippleOpacity: Double = 0

    /// 激光拖尾：最近若干个归一化落点，越靠后越淡越小。
    ///
    /// 拖尾必须存在视图侧而不是 `RemoteControl` 里 —— 它是纯渲染状态，
    /// 让共享模型为了画一条尾巴而保存历史位置，是把表现层的事漏进了状态层。
    @State private var laserTrail: [CGPoint] = []
    /// 扳机触发时的瞄准环回弹。
    @State private var reticleScale: CGFloat = 1

    /// 拖尾保留的采样点数。空鼠 60 Hz，10 个点约 0.17 s，视觉上刚好"有余晖"。
    private static let laserTrailLength = 10

    /// 瀑布流卡片数量。
    ///
    /// 没有虚拟化（外接屏用不了 `ScrollView`，也就没有 `Lazy*` 容器），
    /// 全部一次性建出来。这个量级没问题，上百张得自己写回收池。
    private static let itemCount = 36

    /// 瀑布流列数。
    ///
    /// 取值与理由见 `WaterfallMetrics.wallColumns` —— 定义在那里是为了让验收
    /// 脚本能取到**同一个数**。列数若在这里与脚本里各写一份，脚本断言的
    /// 就是另一套列宽，而它在截图上完全看不出来。
    private static let columnCount = WaterfallMetrics.wallColumns

    /// 卡片数据。固定种子 → 每次启动的高度与配色完全一致，
    /// 逐状态截图对比才有意义。
    private static let items = WaterfallItem.demoItems(count: itemCount)

    /// hero 区（图案 canvas + 标题）的理想高度占比。
    private static let heroHeightRatio: CGFloat = 0.56

    /// hero 区的实际高度。
    ///
    /// 理想占比会被 `ScrollMetrics.maxLeadingElementHeight` **压低** ——
    /// 后者是下拉几何反推出的硬上限：`pull = 1` 时可见的内容高度只剩半个视口，
    /// hero 再高就会被屏幕下沿切掉标题。
    ///
    /// 理想值 0.56 在 letterbox 小窗口（362×204 点）上算出来是 114pt，
    /// 而上限只有 87.6pt —— 也就是说这个场景下**上限才是生效的那个**，
    /// 占比只是个不越界的愿望。
    private static func heroHeight(for viewport: CGSize, inset: CGFloat) -> CGFloat {
        min(
            viewport.height * heroHeightRatio,
            ScrollMetrics.maxLeadingElementHeight(viewport: viewport, inset: inset)
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let plan = DisplayPlan(viewport: geometry.size)

            ZStack(alignment: .topLeading) {
                StarfieldBackdrop(
                    dolly: exposure,
                    tilt: parallaxTilt,
                    isMoving: exposure > 0,
                    isAnimated: store.isAnimated
                )

                contentColumn(plan)

                hud(plan)

                backButton(plan)

                pointer(plan)

                ripple(plan)
            }
            // 内容容器刻意不受视口高度约束（它要能滚动、能溢出），于是 ZStack
            // 的尺寸会被撑到内容总高 —— 而 `.frame` 默认是**居中**对齐，
            // 一旦 ZStack 比 frame 大，它就会被往上顶掉半个差值，画面看起来
            // "莫名其妙从第 3 行开始"。必须显式写 `alignment: .topLeading`。
            // 这与 `scrollColumn` 当年踩的是同一个坑（README 踩坑第 10 条）。
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            .onAppear { reportMetrics(geometry.size) }
            .onChange(of: geometry.size) { _, size in reportMetrics(size) }
            // 挂在 GeometryReader **内部**：选中判定要问 `plan` 当前命中的是哪一张卡，
            // 而 `plan` 是这一层闭包里的局部值，外层拿不到。
            .onChange(of: remote.tapCount) { _, _ in handleTap(in: plan) }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onChange(of: remote.tapCount) { _, _ in playTapFeedback() }
        .onChange(of: remote.pointerSource) { _, _ in laserTrail.removeAll() }
        .onChange(of: remote.pointer) { _, point in appendToLaserTrail(point) }
    }

    // MARK: - 几何

    /// 一帧内所有几何量的汇总。
    ///
    /// 打包成一个值而不是散在 `body` 里逐层传参：布局有顺序依赖
    /// （先瀑布流分列 → 才有内容总高 → 才有可滚动距离），
    /// 集中在一处算能保证这个顺序不会被后续改动打乱。
    private struct DisplayPlan {

        let base: CGFloat
        let waterfall: WaterfallMetrics
        let layout: WaterfallLayout
        let scroll: ScrollMetrics
        let lateral: LateralMetrics
        let heroHeight: CGFloat
        let focus: WaterfallFocus
        let backButton: BackButtonGeometry

        init(viewport: CGSize) {
            let base = min(viewport.width, viewport.height)
            let waterfall = WaterfallMetrics(
                base: base,
                viewport: viewport,
                columns: ExternalDisplayRootView.columnCount
            )
            let layout = WaterfallLayout.make(items: ExternalDisplayRootView.items, metrics: waterfall)
            let heroHeight = ExternalDisplayRootView.heroHeight(for: viewport, inset: waterfall.inset)

            self.base = base
            self.waterfall = waterfall
            self.layout = layout
            self.heroHeight = heroHeight
            self.lateral = LateralMetrics(viewport: viewport)
            // 内容总高 = hero + 间距 + 瀑布流。上下内边距由 ScrollMetrics 自己加。
            self.scroll = ScrollMetrics(
                viewport: viewport,
                contentHeight: heroHeight + waterfall.inset + layout.contentHeight,
                inset: waterfall.inset
            )
            // 列排布区左上角在容器里的位置：横向是排布区居中让出的那侧留白，
            // 纵向是「上内边距 + hero + VStack 间距」——
            // 与 `contentColumn` 里那个 VStack 的结构一一对应，改一边要改两边。
            //
            // 横向刻意用「视口宽 − 排布区宽」而不是 `horizontalInset`：视口窄到
            // 装不下两侧留白时 `columnFieldWidth` 会被 `max(0, _)` 护栏夹住，
            // 那时两者不再相等，而排布区**实际**的位置由被夹住的那个值决定。
            self.focus = WaterfallFocus(
                fieldOrigin: CGPoint(
                    x: (viewport.width - waterfall.columnFieldWidth) / 2,
                    y: waterfall.inset * 2 + heroHeight
                ),
                placements: layout.placements
            )
            // 固定层，不随幕墙位移 —— 它是"浮在板上面"的控件，
            // 跟着板一起被推走就成了板的装饰，而不是一个能按的按钮。
            self.backButton = BackButtonGeometry(viewport: viewport)
        }
    }

    // MARK: - 自测量

    /// 视口点数 × 屏幕 scale 即为像素尺寸。
    ///
    /// 不使用 `UIScreen`：`UIScreen.screens` / `didConnectNotification` 在 iOS 16 已废弃，
    /// `UIScreen.main` 在 iOS 26 已废弃，而 SwiftUI 的 accessory 内容本来也拿不到 `windowScene`。
    private func pixelSize(for viewport: CGSize) -> CGSize {
        CGSize(
            width: (viewport.width * displayScale).rounded(),
            height: (viewport.height * displayScale).rounded()
        )
    }

    private func resolutionText(for viewport: CGSize) -> String {
        let size = pixelSize(for: viewport)
        return "\(Int(size.width)) × \(Int(size.height)) px"
    }

    private func reportMetrics(_ viewport: CGSize) {
        guard let onMetricsChange, viewport.width > 0, viewport.height > 0 else { return }
        onMetricsChange(pixelSize(for: viewport), displayScale)
    }

    // MARK: - 内容容器

    /// 幕墙"浮起来"的程度：三条轴里被推开最多的那一条。
    ///
    /// 它只负责"这块板离开了原位多少"这一件事 —— 投影、四角圆角强度、
    /// 星海的相机推进都按它走。三条轴的位移方向各不相同，但"离开原位多少"
    /// 是一致的：横推露出的左侧星海，与下拉露出的上半屏，
    /// 是同一块板浮起来的两面。
    ///
    /// 计算挪进了纯函数 `wallExposure`，好让"三向过卷 → 曝光量"这条规则
    /// 进得了验收脚本（见 `DisplayScrollGeometry.swift`）。
    private var exposure: CGFloat {
        wallExposure(pull: remote.pull, bottomPull: remote.bottomPull, lateral: remote.lateral)
    }

    /// 幕墙这一帧的整体位移：纵向（滚动 / 下拉 / 上拉）与横向（推开）相加。
    ///
    /// 单独抽成方法是因为它有**两个**消费方 —— 容器的 `.offset` 与命中判定
    /// （`WaterfallFocus`）。之前命中只吃纵向那一个分量，横向一动就会点到邻卡；
    /// 让两处共用同一个来源，才能保证"画在哪"与"点到哪"永远是同一个位移。
    private func contentOffset(in plan: DisplayPlan) -> CGSize {
        CGSize(
            width: plan.lateral.offset(for: remote.lateral),
            height: plan.scroll.contentOffset(
                scroll: remote.scroll,
                pull: remote.pull,
                bottomPull: remote.bottomPull
            )
        )
    }

    /// 内容容器：正常铺满视口；任一侧被推开时整体位移、那一侧浮起圆角，
    /// 变成浮在星海之上的一张半透光的板。
    ///
    /// 三个几何动作叠加在同一次 `.offset` 里（纵向三段 + 横向一段），
    /// 而它们分别取自 `RemoteControl` 里互不干扰的两条权威轴，不会互相污染。
    ///
    /// ## 材质
    /// 底板半透、卡片半透，两者都由 `WallMaterial` 定。这是需求 R1 / R6
    /// 的落点：列间距那条缝要看得到星海。代价与取舍记在那个类型的文档里。
    ///
    /// ## 左右边距在瀑布流内部就成立了
    /// 列排布区比视口窄，居中放置后两侧各让出 `horizontalInset` ——
    /// 这件事完全由 `WaterfallColumnView` 自己完成，这里不必为它做任何事。
    /// 现在那两侧的留白也归底板管，于是同样透光。
    ///
    /// `clipShape` 的职责有两个：把滚出视口的内容裁掉，以及画出浮板
    /// **四角各自**的圆角（见 `WallShape`）。它不再与横向留白有关。
    private func contentColumn(_ plan: DisplayPlan) -> some View {
        let exposure = self.exposure
        let offset = contentOffset(in: plan)
        let radii = WallRadii.forExposure(
            pull: remote.pull,
            bottomPull: remote.bottomPull,
            lateral: remote.lateral,
            radius: plan.scroll.cornerRadius(base: plan.base)
        )
        let viewport = plan.scroll.viewport

        return VStack(alignment: .leading, spacing: plan.waterfall.inset) {
            hero(plan)
            WaterfallColumnView(
                layout: plan.layout,
                metrics: plan.waterfall,
                focusedID: focusedItem(in: plan),
                selectedID: remote.selectedItemID
            )
        }
        .padding(.vertical, plan.waterfall.inset)
        // 容器宽度**锁死**为视口宽。父级 VStack 拿到的宽度一旦被子视图撑宽，
        // 圆角、投影、位移都会跟着跑偏。
        .frame(width: viewport.width, alignment: .top)
        // 底板**半透**（`WallMaterial.plateOpacity`）：列间距那条缝里透出来的
        // 是星海，不是底色。这与最初那条注释（"容器背景必须不透明，否则星海
        // 从卡片缝隙透上来，墙就立不住了"）正好相反，是需求明确反转的一条决定 ——
        // 幕墙从"挡住星海的墙"变成"浮在星海之上的玻璃板"。
        .background(WallMaterial.plate.opacity(WallMaterial.plateOpacity))
        .clipShape(WallShape(radii: radii))
        .shadow(
            color: .black.opacity(Double(exposure) * 0.7),
            radius: plan.base * 0.05 * exposure,
            y: plan.base * 0.012 * exposure
        )
        .offset(offset)
    }

    /// hero 区：帧驱动图案 + 标题 + 分辨率。
    ///
    /// 图案从"铺满整屏的底"降级成"内容的第一屏" —— 它现在随内容一起被滚走、
    /// 被下拉推下去，物理上自洽；而它作为「外接屏真的由本应用逐帧渲染」的
    /// 验证手段依然成立（手机端关掉帧驱动，这一块立刻静止）。
    ///
    /// 缩放仍然只作用于这块图案：它是"封面图缩放"，不是画面缩放 ——
    /// 让 `zoom` 去缩放整个内容容器会连带打乱瀑布流的列宽计算。
    private func hero(_ plan: DisplayPlan) -> some View {
        ZStack(alignment: .bottomLeading) {
            DisplayPatternCanvas(pattern: store.pattern, isAnimated: store.isAnimated)
                .scaleEffect(remote.zoom)
                .animation(.easeOut(duration: 0.15), value: remote.zoom)

            // 压暗底部，保证标题在任何图案上都读得出来
            LinearGradient(
                colors: [.clear, .black.opacity(0.78)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: plan.base * 0.012) {
                Text(store.caption)
                    .font(.system(size: plan.base * 0.072, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Text(resolutionText(for: plan.scroll.viewport))
                    .font(.system(size: plan.base * 0.036, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(plan.base * 0.045)
        }
        .frame(height: plan.heroHeight)
        .clipShape(RoundedRectangle(cornerRadius: plan.base * 0.022, style: .continuous))
        // hero 的圆角是画面上的一个显式形状，被屏幕边缘切掉会看起来像布局错了，
        // 所以左右内边距由它自己补。取 `horizontalInset` —— 与瀑布流的左右边对齐。
        .padding(.horizontal, plan.waterfall.horizontalInset)
    }

    // MARK: - 固定 HUD

    private func hud(_ plan: DisplayPlan) -> some View {
        VStack(alignment: .trailing, spacing: plan.base * 0.012) {
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                Text(timeline.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: plan.base * 0.1, weight: .thin, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }

            Text(readout)
                .font(.system(size: plan.base * 0.032, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))

            if let text = airMouseHudText {
                Text(text)
                    .font(.system(size: plan.base * 0.032, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(LaserPalette.core.opacity(0.85))
            }
        }
        .padding(plan.base * 0.06)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .shadow(color: .black.opacity(0.6), radius: plan.base * 0.02)
    }

    // MARK: - 返回按钮

    /// 左上角的返回按钮。
    ///
    /// ## 为什么是浮动圆，而不是一条栏
    /// 需求里有一条明确的否命题：**不能形成一条拦截的横线**。
    /// 一条铺满屏宽的不透明栏会把幕墙切成两段 —— 上沿露出的星海与幕墙本体
    /// 被那条栏隔开，看起来像两个不相干的区域。所以这里只画一个圆：
    /// 四周透出去的都是幕墙本身，它只是浮在板上的一枚控件。
    ///
    /// ## 命中不靠 SwiftUI
    /// 外接屏收不到触摸（见类型文档），所以 `.allowsHitTesting(false)` 是如实声明：
    /// 按钮的"按下"由手机端指针落点 + 轻点事件驱动，判定在
    /// `BackButtonGeometry.contains(_:)` 里，优先级高于卡片。
    @ViewBuilder
    private func backButton(_ plan: DisplayPlan) -> some View {
        let geometry = plan.backButton
        let isFocused = focusedBackButton(in: plan)

        ZStack {
            // 只垫一层薄暗。垫厚了就等于又造了一条"栏"，正是要避开的东西。
            Circle().fill(.black.opacity(0.35))

            Circle()
                .stroke(
                    isFocused ? Color.white.opacity(0.80) : Color.white.opacity(0.28),
                    lineWidth: max(1, plan.base * (isFocused ? 0.006 : 0.003))
                )

            Image(systemName: "chevron.left")
                .font(.system(size: geometry.diameter * 0.42, weight: .semibold))
                .foregroundStyle(.white.opacity(isFocused ? 0.95 : 0.72))
        }
        .frame(width: geometry.diameter, height: geometry.diameter)
        .position(geometry.center)
        .allowsHitTesting(false)
    }

    private var readout: String {
        var parts = [
            "滚动 \(Int(remote.scroll * 100))%",
            "缩放 \(String(format: "%.2f", remote.zoom))×"
        ]
        if remote.pull > 0 {
            parts.append("下拉 \(Int(remote.pull * 100))%")
        }
        if remote.bottomPull > 0 {
            parts.append("上拉 \(Int(remote.bottomPull * 100))%")
        }
        if remote.lateral != 0 {
            parts.append("横向 \(Int(remote.lateral * 100))%")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 光标与轻点反馈

    /// 光标渲染按归属分派：触控板画环形光标，空鼠画激光。
    ///
    /// 两者共用 `RemoteControl.pointer` 这一个落点，只是外观不同 ——
    /// 这样"谁在动"就完全由 `pointerSource` 决定，不需要两套坐标互相同步。
    @ViewBuilder
    private func pointer(_ plan: DisplayPlan) -> some View {
        if let pointer = remote.pointer {
            switch remote.pointerSource {
            case .touch:
                touchCursor(at: pointer, plan: plan)
            case .airMouse:
                laserCursor(at: pointer, plan: plan)
            }
        }
    }

    /// 星海的视差倾斜，归一化 `-1...1`。
    ///
    /// **只由空鼠驱动**。空鼠的物理动作就是"抬手转动手机"，那正是视差的来源；
    /// 触控板上手指的位置和"视角"没有任何物理关系 —— 拿它做视差会让
    /// 星海在滚动时跟着乱晃，纯属错配。
    private var parallaxTilt: CGPoint {
        guard remote.pointerSource == .airMouse, let pointer = remote.pointer else { return .zero }
        return CGPoint(x: (pointer.x - 0.5) * 2, y: (pointer.y - 0.5) * 2)
    }

    // MARK: 触控板光标

    private func touchCursor(at pointer: CGPoint, plan: DisplayPlan) -> some View {
        let diameter = plan.base * 0.1
        return ZStack {
            Circle().fill(LaserPalette.touch.opacity(0.22))
            Circle().stroke(LaserPalette.touch, lineWidth: max(1.5, plan.base * 0.007))
            Circle()
                .fill(LaserPalette.touch)
                .frame(width: diameter * 0.18, height: diameter * 0.18)
        }
        .frame(width: diameter, height: diameter)
        .position(point(pointer, in: plan))
        .shadow(color: .black.opacity(0.6), radius: plan.base * 0.015)
    }

    // MARK: 激光光标

    /// 激光指针：拖尾 + 光晕 + 白芯光斑 + 瞄准环。
    ///
    /// 后三层各自独立 `.position`，都落在与外层 `ZStack` 同一坐标系里。
    /// **不要**把它们再套一层 ZStack 后整体 position —— 内层已经用绝对坐标定位，
    /// 再套一层会二次偏移。拖尾是铺满视口的 `Canvas`，自己按归一化坐标换算，
    /// 同样不参与这条 `.position` 约定。
    @ViewBuilder
    private func laserCursor(at pointer: CGPoint, plan: DisplayPlan) -> some View {
        let unit = plan.base * 0.1
        let center = point(pointer, in: plan)

        // 1. 拖尾
        laserTrailCanvas(plan)

        // 2. 光晕
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        LaserPalette.core.opacity(0.7),
                        LaserPalette.glow.opacity(0.2),
                        LaserPalette.core.opacity(0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: unit * 0.95
                )
            )
            .frame(width: unit * 1.9, height: unit * 1.9)
            .position(center)

        // 3. 光斑本体：红边包白芯，白芯是"过曝"的部分
        Circle()
            .fill(LaserPalette.core)
            .frame(width: unit * 0.4, height: unit * 0.4)
            .overlay {
                Circle()
                    .fill(.white)
                    .frame(width: unit * 0.16, height: unit * 0.16)
            }
            .shadow(color: LaserPalette.core.opacity(0.9), radius: unit * 0.22)
            .position(center)

        // 4. 瞄准环 + 四向刻度
        reticle(unit: unit)
            .position(center)
    }

    /// 拖尾：一条渐细渐淡的折线，从尾到头收敛到当前光斑。
    ///
    /// 用**单张 `Canvas` 一次描完**，而不是给每个采样点各挂一个带 `.blur` 的
    /// `Circle`。拖尾随光标每帧重算，而空鼠是 60 Hz；10 个模糊图层意味着外接屏
    /// 每个采样周期都要重新合成 10 次离屏模糊 —— 在 4K 外接屏上是实打实的掉帧源。
    /// 描边一次就没有这层开销，且省掉了每段的布局抖动。
    private func laserTrailCanvas(_ plan: DisplayPlan) -> some View {
        let unit = plan.base * 0.1
        let points = laserTrail.map { point($0, in: plan) }

        return Canvas { context, _ in
            guard points.count >= 2 else { return }

            for index in 1..<points.count {
                // 0（最早）→ 1（最新）
                let progress = CGFloat(index) / CGFloat(points.count - 1)

                var path = Path()
                path.move(to: points[index - 1])
                path.addLine(to: points[index])

                context.stroke(
                    path,
                    with: .color(LaserPalette.core.opacity(Double(progress * progress) * 0.55)),
                    style: StrokeStyle(
                        lineWidth: unit * 0.24 * progress,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        .frame(width: plan.scroll.viewport.width, height: plan.scroll.viewport.height)
        .allowsHitTesting(false)
    }

    private func reticle(unit: CGFloat) -> some View {
        let diameter = unit * 0.95
        return ZStack {
            Circle()
                .stroke(LaserPalette.core.opacity(0.6), lineWidth: max(1, unit * 0.02))

            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(LaserPalette.core.opacity(0.8))
                    .frame(width: max(1, unit * 0.016), height: unit * 0.14)
                    // 先位移再旋转：offset 不改变布局框，rotationEffect 仍绕
                    // ZStack 中心转，于是四根刻度均匀落在环外。
                    .offset(y: -(diameter / 2 + unit * 0.1))
                    .rotationEffect(.degrees(Double(index) * 90))
            }
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(reticleScale)
        .shadow(color: LaserPalette.core.opacity(0.5), radius: unit * 0.08)
    }

    // MARK: 涟漪

    private func ripple(_ plan: DisplayPlan) -> some View {
        let center = remote.pointer.map { point($0, in: plan) }
            ?? CGPoint(x: plan.scroll.viewport.width / 2, y: plan.scroll.viewport.height / 2)
        let color = remote.pointerSource == .airMouse ? LaserPalette.core : LaserPalette.touch

        return Circle()
            .stroke(color, lineWidth: max(2, plan.base * 0.01))
            .frame(width: plan.base * 0.22, height: plan.base * 0.22)
            .scaleEffect(rippleScale)
            .opacity(rippleOpacity)
            .position(center)
            .allowsHitTesting(false)
    }

    // MARK: 反馈与拖尾

    private func playTapFeedback() {
        rippleScale = 0.35
        rippleOpacity = 0.9
        withAnimation(.easeOut(duration: 0.55)) {
            rippleScale = 2.0
            rippleOpacity = 0
        }
        // 瞄准环先弹开再收回，给扳机一个"咔哒"的视觉对应
        withAnimation(.spring(response: 0.26, dampingFraction: 0.42)) {
            reticleScale = 1.45
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.6).delay(0.08)) {
            reticleScale = 1
        }
    }

    /// 拖尾只在空鼠驱动光标时累积；切回触控板立刻清空。
    private func appendToLaserTrail(_ normalized: CGPoint?) {
        guard remote.pointerSource == .airMouse, let normalized else {
            if !laserTrail.isEmpty { laserTrail.removeAll() }
            return
        }
        laserTrail.append(normalized)
        if laserTrail.count > Self.laserTrailLength {
            laserTrail.removeFirst()
        }
    }

    // MARK: - 焦点

    /// 指针当前命中的瀑布流卡片。
    ///
    /// 纯计算、每次现算：命中结果随指针每帧变化（空鼠 60 Hz），
    /// 存进 `@State` 只会多出一份要手动同步的副本，而它没有任何跨帧语义。
    ///
    /// 喂给命中的位移与喂给容器 `.offset` 的**是同一个值**（`contentOffset(in:)`）。
    /// 横向推开之后这一点尤其要紧：少喂横向分量不会报错、也不会在纵向滚动时露馅，
    /// 只在横向一动才显形 —— 表现为"指针点到的永远是隔壁那张卡"。
    ///
    /// 指针不在屏上（`pointer == nil`）时直接返回 `nil` —— 触控板与空鼠
    /// 两条路都靠这个判断"现在没有焦点"，不需要再分模式。
    private func focusedItem(in plan: DisplayPlan) -> Int? {
        guard let pointer = remote.pointer else { return nil }
        return plan.focus.item(
            at: point(pointer, in: plan),
            contentOffset: contentOffset(in: plan)
        )
    }

    /// 指针是否落在返回按钮上。
    ///
    /// 与卡片命中同源：都用**视口坐标**上的指针落点。按钮在固定层，
    /// 不随幕墙位移，所以这里**不能**减 `contentOffset` ——
    /// 减了就变成"按钮跟着板一起被推走"，而它明明画在板上方不动。
    private func focusedBackButton(in plan: DisplayPlan) -> Bool {
        guard let pointer = remote.pointer else { return false }
        return plan.backButton.contains(point(pointer, in: plan))
    }

    /// 轻点 / 扳机。
    ///
    /// **返回按钮优先于卡片**：按钮压在幕墙之上，指针在它里面的时候，
    /// 底下那张卡不该抢走这次点击。按钮的判定区比卡片小得多，
    /// 优先判它不会让卡片的命中变"粘"。
    ///
    /// 按钮的动作目前只记一条事件 —— "点了之后跳到哪一页"还没有定论
    /// （见 `docs/specs/glass-wall-gesture.md` 的 D5），这一段刻意留空，
    /// 不拿一个猜测出来的页面顶上。
    private func handleTap(in plan: DisplayPlan) {
        if focusedBackButton(in: plan) {
            remote.noteBackButton()
            return
        }
        toggleSelection(in: plan)
    }

    /// 把当前命中的卡片设为选中，再确认同一张则取消。
    ///
    /// 指针没落在任何卡片上时**不动选中** —— 空白处点一下不该把已经选好的东西
    /// 丢掉；而"取消"已经有"再点同一张"这条明确路径，不必再占一个手势。
    private func toggleSelection(in plan: DisplayPlan) {
        guard let focused = focusedItem(in: plan) else { return }
        remote.select(item: remote.selectedItemID == focused ? nil : focused)
    }

    // MARK: - 几何与文案

    private func point(_ normalized: CGPoint, in plan: DisplayPlan) -> CGPoint {
        CGPoint(
            x: normalized.x * plan.scroll.viewport.width,
            y: normalized.y * plan.scroll.viewport.height
        )
    }

    /// 空鼠状态行。未启动时不占地方，故障状态则必须显示 ——
    /// 否则眼镜屏上什么都看不到，手机端又不在眼前，用户无从判断。
    private var airMouseHudText: String? {
        switch airMouse.state {
        case .idle, .stopped:
            return nil
        case .warming:
            return "空鼠预热中…"
        case .tracking:
            if airMouse.warmup.isSynthetic { return "空鼠 模拟源" }
            guard let usable = airMouse.warmup.milestones.usable else { return "空鼠 就绪" }
            return String(format: "空鼠 可用 %.2fs", usable)
        case .noSamples:
            return "空鼠 无数据"
        case .unavailable:
            return "空鼠 不可用"
        }
    }
}

/// 光标配色。触控板沿用原来的橙色，空鼠用红色激光系。
///
/// 非 private：瀑布流的焦点环也取这里的颜色 —— 整块屏上"红色 = 交互焦点"
/// 是同一套语言，两处各写一遍迟早会漂开。
enum LaserPalette {
    static let core = Color(red: 1.0, green: 0.21, blue: 0.25)
    static let glow = Color(red: 1.0, green: 0.45, blue: 0.28)
    static let touch = Color.orange
}

/// 四角**各自独立**圆角的矩形。
///
/// 取代了当初的 `TopRoundedRect`（底角写死 0）。当年只做顶边是有理由的：
/// 内容容器只在下拉时浮起，另外三条边永远贴着屏幕边缘或者伸到屏幕外，
/// 圆角根本看不见，多算两个值是白算。
///
/// 幕墙能被四向推开之后这条前提不成立了：横推露出的那一条**竖边**整条都在屏内，
/// 上下两个角都看得见。所以四角各算各的 —— 具体归属由 `WallRadii` 决定。
///
/// 四个半径都进 `animatableData`：过卷是手指逐帧驱动的连续量，
/// 圆角必须跟着连续变化；只把其中一部分设为可动画的话，
/// 那些没进差值链的角会阶梯式跳。
private struct WallShape: Shape {

    var radii: WallRadii

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(radii.topLeading, radii.topTrailing),
                AnimatablePair(radii.bottomLeading, radii.bottomTrailing)
            )
        }
        set {
            radii.topLeading = newValue.first.first
            radii.topTrailing = newValue.first.second
            radii.bottomLeading = newValue.second.first
            radii.bottomTrailing = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path(
            roundedRect: rect,
            cornerRadii: RectangleCornerRadii(
                topLeading: radii.topLeading,
                bottomLeading: radii.bottomLeading,
                bottomTrailing: radii.bottomTrailing,
                topTrailing: radii.topTrailing
            ),
            style: .continuous
        )
    }
}

#Preview {
    ExternalDisplayRootView()
}
