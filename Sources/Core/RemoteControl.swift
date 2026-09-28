import CoreGraphics
import Foundation
import Observation

/// 手机端遥控板 → 外接屏的**单向**交互状态。
///
/// ## 为什么必须有这一层
/// 外接屏的 role 是 `windowExternalDisplayNonInteractive` —— 它**收不到任何触摸事件**：
///
/// - 真机：`ExternalDisplaySceneDelegate` 里 `window.isUserInteractionEnabled = false`，
///   系统本来也不向该 role 投递触摸。
/// - 模拟器 mock：`PassthroughWindow.hitTest` 恒返回 `nil`，触摸全部落到下层窗口。
///
/// 所以「在外接屏上上下滑动」这件事，物理上不可能由外接屏自己完成，
/// 必须在手机屏采集手势，再送到外接屏的渲染视图上。这就是本类的职责。
///
/// ## 与 `DisplayContentStore` 的分工
/// - `DisplayContentStore`：内容本身（图案、标题、动画开关）—— 手机端"选什么"。
/// - `RemoteControl`：视口状态（滚动、下拉、缩放、光标）—— 手机端"怎么看"。
///
/// 两者都是同进程单例，外接屏侧直接读，不需要任何跨 scene 通道。
///
/// ## 纵向为什么是**一个**标量而不是两个
/// 外接屏上有几件相关但语义不同的事：
/// - **滚动**：内容在瀑布流里往上走，`0...1`；
/// - **下拉**：已经在顶部还继续往下拽，把内容推下去露出背景墙；
/// - **上拉**：已经到底还继续往上拽，把内容拽上去露出星海。
///
/// 它们看似三个维度，实际是**同一条数轴上的三段**：手指一直在往一个方向拖，
/// 只是越过两端之后语义变了。所以内部只留一个权威标量 `position`：
///
/// ```
/// position < 0  →  顶部下拉的超出行程
/// 0 ... 1       →  正常滚动进度（0 = 顶部，1 = 底部）
/// position > 1  →  底部上拉的超出行程
/// ```
///
/// 对外仍然暴露三个属性，因为渲染侧关心的是三件不同的事（内容位移 / 顶部露出量 /
/// 底部露出量）。但**唯一权威只有 `position`** —— 若把它拆成三个可独立写的存储属性，
/// 过卷时被阻尼吃掉的那部分行程，在回拉时会变成凭空多出来的滚动，手指一松内容就跳。
@MainActor
@Observable
final class RemoteControl {

    static let shared = RemoteControl()

    /// 缩放倍率的合法区间，滑杆与手势都以此为准。
    static let zoomRange: ClosedRange<CGFloat> = 1...3

    /// **唯一权威**标量。见类型文档。
    ///
    /// 存归一化值而不是像素位移：外接屏可能是 1080p / 4K / 模拟器里的
    /// letterbox 小窗口，尺寸差异巨大。归一化之后，外接屏侧按自身内容高度
    /// 换算成实际位移，同一份手机端状态在哪块屏上都成立。
    private var position: CGFloat = 0

    /// 归一化滚动进度：`0` = 顶部，`1` = 底部。
    ///
    /// 上限钳到 1（而不是直接取 `max(0, position)`）：进入底部上拉之后
    /// `position` 会超过 1，若不钳住，读数栏会一直显示到 190% ——
    /// "进度 190%" 是没有意义的，超过 100% 的那部分归 `bottomPull` 表达。
    var scroll: CGFloat { min(max(position, 0), 1) }

    /// 顶部下拉进度：`0` = 没下拉，`1` = 内容顶边落到屏幕中线。
    ///
    /// 手感曲线由 `PullCurve` 提供 —— 渲染侧拿到的是**已含阻尼**的值，
    /// 直接乘 `ScrollMetrics.maxPullDistance` 即可，不必再处理一次曲线。
    var pull: CGFloat {
        PullCurve.progress(raw: -min(0, position))
    }

    /// 底部上拉进度：`0` = 没上拉，`1` = 内容下沿离开屏幕下沿半个视口高。
    ///
    /// 与 `pull` 复用同一条 `PullCurve`：两条边是同一个动作的两端，
    /// 手感曲线不一致的话，"往上拽比往下拽费劲"会变成一个说不清来由的差异。
    var bottomPull: CGFloat {
        PullCurve.progress(raw: max(0, position - 1))
    }

    /// 横向推程：`0` = 居中，`> 0` = 幕墙右移（露出左侧星海）。
    ///
    /// ## 为什么是**另一条**轴，而不是塞进 `position`
    /// 纵向的 `scroll` / `pull` / `bottomPull` 是"同一条数轴上的三段"，
    /// 所以能共用一个权威标量；横向和它们在物理上正交（手指横向位移与纵向位移
    /// 是两件独立的事），合进同一个标量就得在每次读写时把它拆出来再接回去，
    /// 纯属自找麻烦。
    ///
    /// 这也是本类第一次出现"两条平行权威量"。判据很简单：
    /// **能不能靠一个数轴上的位置关系互相推导** —— 能就合并，不能就并列。
    ///
    /// 命名用 `lateral` 而不是 `x`：本类里 `x` 已经被光标坐标占了。
    private var lateralRaw: CGFloat = 0

    /// 已含阻尼的横向推程，`-1...1`。
    var lateral: CGFloat { LateralCurve.progress(raw: lateralRaw) }

    /// 画面缩放倍率。
    private(set) var zoom: CGFloat = 1

    /// 光标当前由谁驱动。外接屏据此换渲染样式：
    /// 触控板画环形光标，空鼠画激光。
    enum PointerSource: String {
        case touch
        case airMouse
    }

    /// 手机端手指在外接屏上的归一化落点（0...1）；`nil` 表示光标不在屏上。
    private(set) var pointer: CGPoint?

    /// 光标的当前归属。空鼠与触控板共用同一个落点，谁在动谁说了算。
    private(set) var pointerSource: PointerSource = .touch

    /// 轻点计数。外接屏侧靠它的变化触发一次涟漪反馈。
    private(set) var tapCount: Int = 0

    /// 当前选中的瀑布流项（`nil` = 没有选中）。
    ///
    /// ## 这一项是**反向**写入的
    /// 「指针落在哪张卡上」需要外接屏的几何 —— 视口尺寸、hero 高度、内容的滚动位移，
    /// 全都在渲染那侧，手机端无从判断。所以命中由外接屏算出来，再把结果写回这里：
    /// **本类里唯一一条「外接屏 → 模型」的写入**，其余全部由手机端单向驱动。
    ///
    /// 之所以不把它留在渲染侧的 `@State`：那样就只能靠手点验证。选中态没法在启动参数里
    /// 预置，也就进不了逐状态截图对比 —— 而 `simctl` 没有触摸注入 API，
    /// 这个项目里"能脚本化验证"是硬指标（见 `MockRemoteState`）。
    private(set) var selectedItemID: Int?

    /// 记录一次选中。传 `nil` 取消选中。
    func select(item id: Int?) {
        guard selectedItemID != id else { return }
        selectedItemID = id
        lastEvent = id.map { "选中第 \($0) 项" } ?? "取消选中"
    }

    // MARK: - 照片详情页

    /// 当前正在查看的照片（`nil` = 停在幕墙页）。
    ///
    /// 这就是"当前在哪一页"的**唯一**依据 —— 渲染侧按它决定画幕墙还是画照片，
    /// 拖拽动作也按它分流（见 `scroll(by:)`）。不额外维护一个页面枚举：
    /// 两个来源描述同一件事，迟早会有一处忘了同步，而症状是"明明在详情页
    /// 却把幕墙滚走了"，看起来像手势错乱。
    private(set) var detailItemID: Int?

    /// 全景项的 `id → 投影档`。**由渲染侧注入** —— 只有它知道每张卡的 `projection`。
    ///
    /// 这不是一份"新状态"而是**派生数据**：真实来源是 `WaterfallItem.demoItems`，
    /// 一个 `static let`，注入一次即恒定。之所以要让本类拿到它：
    /// 输入分流（`scroll(by:)` / `lateral(by:)` / `AirMouse`）全在本层，
    /// 而它们只看得到 `detailItemID`，看不见卡片的投影。
    ///
    /// 存**档位**而不只是一个 id 集合，是因为两类全景吃的输入本来就不一样：
    /// 柱面没有俯仰（见 `scroll(by:)`），球面两个轴都吃。
    /// 只存一个集合的话，"A 类纵向拖动"会悄悄改一个它根本不读的角度 ——
    /// 画面纹丝不动，而那个角度会一直留着。
    private var panoramaItems: [Int: PanoramaProjection] = [:]

    /// 注入 `id → 投影档`。渲染侧在挂载时调一次。
    func setPanoramaItems(_ items: [Int: PanoramaProjection]) {
        guard panoramaItems != items else { return }
        panoramaItems = items
    }

    /// 当前详情页的投影档（`nil` = 不在详情页，或者那是一张普通照片）。
    ///
    /// 它与 `detailPage` 的分叉取自**同一个来源**（卡片自己的 `projection`），
    /// 所以"画的是全景、动的却是照片平移"这种错位不可能发生。
    /// 刻意不做成第二个开关：两个来源描述同一件事，迟早会有一处忘了同步，
    /// 而症状是"手势失灵"，查起来会往手势层跑偏。
    var detailProjection: PanoramaProjection? {
        guard let id = detailItemID else { return nil }
        return panoramaItems[id]
    }

    /// 当前详情页是不是全景页 —— 输入分流的判据。
    var isPanoramaDetail: Bool { detailProjection != nil }

    /// 详情页的查看模式：整图（默认）或铺满。
    private(set) var detailMode: PhotoViewMode = .fit

    /// 详情页照片的**归一化行程进度**，各分量 `-1...1`。
    ///
    /// 存进度而不是像素：手机端不知道外接屏多大，像素行程由渲染侧按
    /// `PhotoDetailGeometry` 算（与 `position` 存归一化进度同一条规矩）。
    ///
    /// 这里的夹取是**保守**的（只保证 `-1...1`）：真正可达的范围取决于
    /// 照片宽高比、视口尺寸与查看模式，三者都在渲染侧。渲染侧每帧会用
    /// `PhotoDetailGeometry.clamped(_:)` 夹一次并回写（见 `setDetailPan`），
    /// 于是"某个方向根本不可拖"时手机端不会攒下一堆要回拉才能抵消的行程。
    private(set) var detailPan: CGSize = .zero

    /// 双击次数。渲染侧靠它的变化触发一次查看模式切换。
    ///
    /// 与 `tapCount` 分成两个计数而不是让渲染侧去推断"这次是单还是双"：
    /// `onChange` 的顺序不可控，两个独立的计数让两条分支各自幂等。
    private(set) var doubleTapCount: Int = 0

    /// 点击序列。跨会话的记忆在这里，不在 `PadGesture` 里（见那个类型的文档）。
    private var tapSequence = TapSequence()

    /// 进入某张照片的详情页。
    ///
    /// 会**重置视角**：换一张照片之后旧的朝向没有意义（新照片的 0° 与旧的
    /// 0° 不是同一个方向）。这条重置有一个可观测的后果 ——
    /// 启动参数里 `look=` 必须排在 `pano=`/`detail=` **之后**，否则会被这一行抹掉
    /// （与 `bottom` 必须排在 `scroll` 之后是同一种次序问题）。
    ///
    /// 重置到的是**该投影的正前方**而不是 `PanoramaLook.zero` —— 见 `frontLook(for:)`。
    func openDetail(item id: Int) {
        select(item: id)
        detailItemID = id
        detailMode = .fit
        detailPan = .zero
        panoramaLook = Self.frontLook(for: panoramaItems[id])
        // 全景页里姿态归视角（见 `AirMouse` 的分流），激光让位 ——
        // 上一次留下的落点会变成一枚钉死在全景页上的激光点，动不了也点不掉。
        // 清掉之后，用户一转头它自然会重新出现（如果那时还在指针模式）。
        if panoramaItems[id] != nil { pointer = nil }
        lastEvent = "查看第 \(id) 张"
    }

    /// 退出详情，回幕墙。
    ///
    /// 刻意**不动** `position` / `lateralRaw`：幕墙的滚动位置是用户进来之前
    /// 自己滚到的，返回时原样呈现才对。详情页的平移量是另一套量，见 `detailPan`。
    func closeDetail() {
        guard detailItemID != nil else { return }
        detailItemID = nil
        detailMode = .fit
        detailPan = .zero
        panoramaLook = .zero
        lastEvent = "返回幕墙"
    }

    /// 切换查看模式（双击触发）。不在详情页时什么都不做。
    func toggleDetailMode() {
        guard detailItemID != nil else { return }
        detailMode = detailMode.toggled
        // 换适配口径之后原来的行程没有意义了：同一个进度值在两种模式下
        // 对应的像素位移完全不同，留着它会让照片"跳"到某个奇怪的位置。
        detailPan = .zero
        lastEvent = detailMode == .fill ? "铺满显示" : "整图显示"
    }

    /// 由渲染侧回写夹取后的行程（见 `PhotoDetailGeometry.clamped(_:)`）。
    ///
    /// 这是本类里第二条「外接屏 → 模型」的写入（第一条是 `select(item:)`
    /// 的命中结果）。之所以必须有：手机端做不了这个夹取，而攒下不可达的
    /// 行程会让反向拖动"粘住"一段才响应。
    func setDetailPan(_ pan: CGSize) {
        guard detailItemID != nil, pan != detailPan else { return }
        detailPan = pan
    }

    /// 详情页里的拖动：只改 `detailPan`，不碰幕墙的位置。
    private func panDetail(by delta: CGSize) {
        detailPan = CGSize(
            width: Self.clamp(detailPan.width + delta.width, -1, 1),
            height: Self.clamp(detailPan.height + delta.height, -1, 1)
        )
    }

    // MARK: - 全景详情页的视角

    /// 全景详情页的视角。
    ///
    /// ## 为什么归这里
    /// 与 `detailPan` 同一条理由：手机端不知道外接屏多大，更不该知道 `fov`
    /// 与视口比例 —— 它只送"转过了多少"，几何全在渲染侧。
    /// 而"当前在哪一页"（`detailItemID`）与"这一页的视角"本来是一件事的两面，
    /// 拆到两个对象里就多出一处要手动同步的状态。
    ///
    /// ## 它与激光指针**物理互斥**
    /// 全景页里手机姿态喂视角、不喂激光（spec §4.3-3，已标为行为变更）：
    /// 一份物理姿态不可能同时干两件事。分流点在输入层（`AirMouse`），
    /// 本类只提供量 —— 它不认识 `CMDeviceMotion`。
    ///
    /// ## `pitch` 的权威在渲染侧
    /// 与 `detailPan` 同一条纪律：Core 层只做 ±90 的护栏（见 `PanoramaLook`），
    /// 真正可达的范围取决于视口与 `fov`，只有渲染侧算得出 ——
    /// 所以它每帧夹一次再回写（`clampLookPitch(to:)`），与 `setDetailPan` 并列。
    private(set) var panoramaLook: PanoramaLook = .zero

    /// 直接落到某个视角，供调试预置使用。
    func setLook(_ look: PanoramaLook) {
        panoramaLook = look
        guard detailItemID != nil else { return }
        lastEvent = String(format: "视角 yaw %.0f° · pitch %.0f°", look.yaw, look.pitch)
    }

    /// 按两帧**姿态读数**推进视角。输入层（`AirMouse`）逐帧调用。
    ///
    /// 与 `setLook` 的分工：那个是"落到某个值"（调试预置，会写 `lastEvent`），
    /// 这个只改量 —— 姿态是 60 Hz 的连续流，逐帧刷文案既无意义，
    /// 又会带着观察它的界面一起重算（与 `movePointer` 不写 `lastEvent` 同一条规矩）。
    ///
    /// 三个分量各自怎么用（横向累积、竖向绝对、roll 也走横向）收在
    /// `PanoramaLook.advanced(from:to:)`，本方法只做那一道页面判定 ——
    /// 两份实现迟早会漂开，而症状是"某个方向莫名不动"（票 `08`）。
    func advanceLook(from previous: AttitudeReading, to current: AttitudeReading) {
        guard detailItemID != nil else { return }
        panoramaLook = panoramaLook.advanced(from: previous, to: current)
    }

    /// 由渲染侧回写夹取后的 pitch（见 `PanoramaLook.clamped(toPitchLimit:)`）。
    ///
    /// 夹取幂等 ⇒ 不形成更新循环；这与 `setDetailPan` 是同一条纪律，
    /// 也是本类第三条「外接屏 → 模型」的写入。
    func clampLookPitch(to limit: CGFloat) {
        let clamped = panoramaLook.clamped(toPitchLimit: limit)
        guard clamped != panoramaLook else { return }
        panoramaLook = clamped
    }

    /// 视角归零 —— 把当前朝向定为新的"正前方"。
    ///
    /// 视角是**累积量**（逐帧最短弧增量累加，见 `PanoramaLook`），
    /// 所以漂移会攒；这是本线唯一的手动纠偏手段。
    ///
    /// 归到 `frontLook(for:)` 而不是 `PanoramaLook.zero`：归零的语义本来就是
    /// "回到正前方"，而正前方由投影档决定（见 `frontLook(for:)`）。
    /// 退回 0 会让 equirect 归零后正对 0° 经线 —— 那是贴图的接缝。
    func recenterLook() {
        let target = Self.frontLook(for: detailProjection)
        guard panoramaLook != target else { return }
        panoramaLook = target
        lastEvent = "视角归零"
    }

    /// 某个投影档的"正前方"。
    ///
    /// 两类全景的正面**落在不同的数上**：equirect 是 180°（等距柱状把相机的
    /// 正前方缝在贴图水平中点，而 0° 是接缝），柱面是 0°（`CylindricalPan` 的居中口径）。
    /// 依据收在 `PanoramaProjection.frontYaw`，这里只负责翻档。
    ///
    /// 「进页面」与「视角归零」共用它，是因为它们问的是同一件事 ——
    /// 正前方只有一个，两处各写一套迟早会漂开。
    private static func frontLook(for projection: PanoramaProjection?) -> PanoramaLook {
        guard let projection else { return .zero }
        return PanoramaLook(yaw: projection.frontYaw)
    }

    // MARK: - 全景页的视场

    /// 全景页的视场（度）。
    ///
    /// ## 为什么归"怎么看"这半边
    /// 它改的是"这一窗看到多少"，与"看哪一张"无关 —— 与 `panoramaLook` / `detailPan`
    /// 同属视口状态，所以和它们放在一起（`filter` / `panoramaSource` 改的是显示什么，
    /// 在 `DisplayContentStore`）。
    ///
    /// ## 为什么是档位而不是无级滑杆
    /// 有档位，"这一窗宽多少度"才有确定说法，也才说得清"转 90° 换几屏"
    /// （档位表在纯层：`EquirectProjection.fovStops`）。本类只存**当前值**，
    /// 且恒等于表里的某一项 —— 由 `setPanoramaFOV` 折到最近档位保证。
    ///
    /// ## 只有 equirect 读它
    /// 柱面（A 类）走 `PhotoDetailGeometry(.fill)`，压根没有视场这个概念
    /// （见 `ExternalDisplayRootView.detailPage(item:plan:)` 的分流）。
    ///
    /// 复位（`reset()`）**刻意不动**它：它是观看偏好，与"把画面挪回初始位置"
    /// 不是一回事；清掉会让每次截图都要重新选一遍档位。
    private(set) var panoramaFOV: CGFloat = EquirectProjection.defaultFOV

    /// 落到某个视场。入参不在档位表里时折到最近的一档。
    func setPanoramaFOV(_ fov: CGFloat) {
        let snapped = EquirectProjection.nearestFOV(to: fov)
        guard snapped != panoramaFOV else { return }
        panoramaFOV = snapped
        lastEvent = "视场 \(Int(snapped))°"
    }

    /// 在档位表上前后挪一格，越界回绕。
    ///
    /// 与 `setPanoramaFOV` 并存而不是只留一个：档位是**有序**的（60/90/120），
    /// "再宽一点"这个意图天然是相对量，而且在真机上按一下比在分段控件上瞄准一格容易。
    func stepPanoramaFOV(by step: Int) {
        let stops = EquirectProjection.fovStops
        guard !stops.isEmpty else { return }
        let current = stops.firstIndex(of: panoramaFOV) ?? 0
        let count = stops.count
        let next = ((current + step) % count + count) % count
        setPanoramaFOV(stops[next])
    }

    // MARK: - 文案与初始化

    /// 最近一次离散手势的说明，手机端面板上直读。
    private(set) var lastEvent: String = "等待操作"

    private init() {}

    // MARK: - 滚动与下拉

    /// 拖动增量，`dy` 为**归一化**位移（已除以触控板高度）。
    ///
    /// 方向约定跟手指走：手指上滑 `dy < 0` → 内容上移 → 进度增大。
    /// 越过顶部后自动转成下拉、越过底部后自动转成上拉，调用方不需要自己判断边界。
    ///
    /// ## 同一个动作落到哪个量上，取决于当前在哪一页
    /// | 页 | 纵向拖动改的是 |
    /// |---|---|
    /// | 幕墙 | 滚动 / 下拉 / 上拉（`position`） |
    /// | 照片详情 | 照片的纵向平移（`detailPan`） |
    /// | **全景详情** | **视角的俯仰（`panoramaLook.pitch`）** |
    ///
    /// 分流点选在这里而不是手势层：手势层（`PadGesture`）是纯状态机，
    /// 它不认识页面；渲染层则是纯输出，不该持有可写状态。
    /// 本类本来就是"所有输入的汇聚点"，由它按页面决定去向，
    /// 调用方（`GesturePad` / `AirMousePad`）一行都不用改。
    func scroll(by dy: CGFloat) {
        guard dy != 0 else { return }

        if detailItemID != nil {
            // 只有**球面**吃俯仰。柱面（A 类）的垂直行程恒为 0
            // （`cylindricalPan.height` 固定 0，见 `ExternalDisplayRootView`），
            // 让它也走这条分支的话，纵向拖动会改一个它根本不读的角度 ——
            // 画面纹丝不动，而那个角度会一直留着。
            if detailProjection == .equirect {
                panoramaLook = panoramaLook.advanced(
                    deltaYaw: 0,
                    deltaPitch: LookInput.pitchDelta(forScroll: dy)
                )
                return
            }
            panDetail(by: CGSize(width: 0, height: dy))
            return
        }

        let next = min(
            max(position - dy, -PullCurve.rawLimit),
            1 + PullCurve.rawLimit
        )

        // 只在过卷真正开始的那一刻记一次事件，避免逐帧刷屏
        if next < 0, position >= 0 {
            lastEvent = "下拉露出背景墙"
        } else if next > 1, position <= 1 {
            lastEvent = "上拉露出星海"
        }
        position = next
    }

    /// 直接落到某个滚动进度，供滑杆等绝对定位控件使用。
    ///
    /// 会把下拉一并收掉 —— 绝对定位的语义是"把画面挪到某个位置"，
    /// 留着下拉会让内容停在半路。
    func scroll(to value: CGFloat) {
        position = Self.clamp(value, 0, 1)
        lastEvent = "跳转到 \(Int(scroll * 100))%"
    }

    func scrollToTop() {
        position = 0
        lastEvent = "回到顶部"
    }

    /// 直接落到某个下拉进度（`0...1`），供滑杆、按钮与调试预置使用。
    ///
    /// 会先把滚动收掉 —— 下拉只在顶部成立，`position` 是**一个**标量，
    /// 不可能同时是正的滚动进度和负的下拉行程。
    func pull(to value: CGFloat) {
        position = -PullCurve.rawValue(forProgress: Self.clamp(value, 0, 1))
        lastEvent = value > 0
            ? "下拉 \(Int(pull * 100))%"
            : "收起背景墙"
    }

    /// 直接落到某个底部上拉进度（`0...1`），供调试预置使用。
    ///
    /// 与 `pull(to:)` 对称，但它落在数轴的**另一端**：先顶到 `position = 1`（滚到底），
    /// 再往上加超出行程。`scroll(to:)` 钳在 `0...1`，所以做不出这个状态 ——
    /// 这不是缺陷，而是"滚动进度"与"过卷行程"本来就该分开表达。
    func bottomPull(to value: CGFloat) {
        position = 1 + PullCurve.rawValue(forProgress: Self.clamp(value, 0, 1))
        lastEvent = value > 0
            ? "上拉 \(Int(bottomPull * 100))%"
            : "收起星海"
    }

    // MARK: - 横向推开

    /// 横向拖动增量，`dx` 为**归一化**位移（已除以采集面宽度）。
    ///
    /// 方向约定跟着手指走：手指右滑 `dx > 0` → 幕墙右移 → 露出**左侧**星海。
    /// 与纵向 `scroll(by:)` 的符号习惯相反（那边手指上滑是负增量），
    /// 原因是纵向送的是"进度增量"、横向送的是"位移本身"，两者本来就不是一种量。
    func lateral(by dx: CGFloat) {
        guard dx != 0 else { return }

        // 与 `scroll(by:)` 同一条分流规则，只是落在另一条轴上：
        // 幕墙推星海 / 照片推照片 / 全景转 yaw。
        // 横向两类全景都吃：A 类的真实几何正是"横向由视角折出"（`cylindricalPan`）。
        if detailItemID != nil {
            if isPanoramaDetail {
                panoramaLook = panoramaLook.advanced(
                    deltaYaw: LookInput.yawDelta(forLateral: dx),
                    deltaPitch: 0
                )
                return
            }
            panDetail(by: CGSize(width: dx, height: 0))
            return
        }

        let next = Self.clamp(lateralRaw + dx, -LateralCurve.rawLimit, LateralCurve.rawLimit)

        // 只在推满的那一刻记一次事件，避免逐帧刷屏
        if abs(next) >= LateralCurve.rawLimit, abs(lateralRaw) < LateralCurve.rawLimit {
            lastEvent = next > 0 ? "幕墙推到最右" : "幕墙推到最左"
        }
        lateralRaw = next
    }

    /// 直接落到某个横向推程（`-1...1`），供滑杆与调试预置使用。
    func lateral(to progress: CGFloat) {
        lateralRaw = LateralCurve.rawValue(forProgress: Self.clamp(progress, -1, 1))
        lastEvent = progress == 0
            ? "幕墙回中"
            : "横向推开 \(Int(lateral * 100))%"
    }

    // MARK: - 光标

    /// 更新外接屏上的光标位置，入参为归一化坐标。
    ///
    /// - Parameter source: 本次写入的来源。传 `nil` 则沿用上一次的来源，
    ///   只有 `point != nil` 时才改写归属 —— 清空光标不该顺手把归属也改掉。
    func movePointer(to point: CGPoint?, source: PointerSource? = nil) {
        pointer = point.map { CGPoint(x: Self.clamp($0.x, 0, 1), y: Self.clamp($0.y, 0, 1)) }
        if pointer != nil, let source {
            pointerSource = source
        }
    }

    /// 清空光标（空鼠停止时调用），归属保持不变。
    func clearPointer() {
        pointer = nil
    }

    /// 记录一条来自空鼠的离散事件，手机端读数栏直读。
    func noteAirMouseEvent(_ text: String) {
        lastEvent = text
    }

    /// 记录一次「返回」按钮被命中。
    ///
    /// ## 为什么现在只写一条事件
    /// 按钮的**动作**还没有定论 —— 外接屏没有导航栈，"返回"回到哪一页
    /// 只有需求方能定（见 `docs/specs/glass-wall-gesture.md` 的 D5）。
    /// 这一版先把"按钮能被命中"这件事做完整（几何 + 命中优先级 + 悬浮态），
    /// 动作留成一个**显式空位**：它在这里有名字、在渲染侧有唯一调用点，
    /// 接上去是一行的事。用一个猜出来的页面把它填满，
    /// 等于把不确定性藏进代码里 —— 那比明摆着留空难查得多。
    func noteBackButton() {
        lastEvent = "返回"
    }

    // MARK: - 缩放

    func setZoom(_ value: CGFloat) {
        zoom = Self.clamp(value, Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
        lastEvent = String(format: "缩放 %.2f×", zoom)
    }

    /// 相对缩放，`factor > 1` 放大。捏合手势逐帧调用。
    func zoom(by factor: CGFloat) {
        guard factor > 0 else { return }
        setZoom(zoom * factor)
    }

    // MARK: - 轻点

    /// 一次确认。
    ///
    /// 双击判定在这里做，而不是在 `PadGesture` 里 —— 本方法是**所有**确认路径的
    /// 汇聚点（面板轻点、空鼠扳机按钮、触控板上的兜底按钮），判定放在这里，
    /// 三条路自动获得同一种行为。判据本身是纯值类型 `TapSequence`，可断言。
    ///
    /// `tapCount` 每次轻点都自增（双击也算两次）—— 它驱动的是涟漪反馈，
    /// "点了几下"与"是不是双击"是两件事，后者归 `doubleTapCount`。
    func tap() {
        tapCount += 1

        switch tapSequence.registerTap(at: Date()) {
        case .single:
            lastEvent = "轻点 #\(tapCount)"
        case .double:
            doubleTapCount += 1
            lastEvent = "双击 #\(doubleTapCount)"
        }
    }

    // MARK: - 复位

    func reset() {
        position = 0
        lateralRaw = 0
        zoom = 1
        pointer = nil
        pointerSource = .touch
        selectedItemID = nil
        detailItemID = nil
        detailMode = .fit
        detailPan = .zero
        panoramaLook = .zero
        tapSequence = TapSequence()
        lastEvent = "已复位"
    }

    // MARK: - Helpers

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
