import CoreGraphics
import Foundation

/// 调试用：从启动参数预置 `RemoteControl` 的视口状态。
///
/// ## 为什么必须有它
/// `simctl` **没有触摸注入 API** —— 手机端触控板上的拖拽、捏合无法在自动化里复现。
/// 于是「手势 → 状态」这半条链路只能靠手点；如果「状态 → 渲染」也依赖手点，
/// 那"逐状态截图核对几何"这件事就根本做不了，星海的相机推进、内容的下拉位移
/// 全都只能靠肉眼看一遍了事。
///
/// 这里把状态直接写进去，让后半个链路可以脚本化：
/// 每个 `pull` 值启动一次、截一张图，五张图并排就能核对几何对不对。
///
/// 与 `MockExternalDisplay` / `MockAirMouseSource` 同一约定：只在带启动参数时生效，
/// 不参与真机链路。**它伪造的是输入，不是度量** —— 和 `MockAirMouseSource` 一样，
/// 不编造任何"看起来像真实数据"的读数。
///
/// ## 用法
/// ```
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay -remoteState pull=0.5
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay \
///     -remoteState scroll=0.3,pull=0.25,zoom=1.5
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay -remoteState pointer=0.3:0.35
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay \
///     -remoteState pointer=0.3:0.4,selected=7
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay -remoteState lateral=-1
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay -remoteState bottom=1
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay -remoteState detail=7
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay -remoteState detail=7:fill,pan=0:1
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay -remoteState filter=panorama
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay -remoteState pano=8
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay -remoteState pano=8,look=90:0
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay -remoteState strip=2
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay -remoteState pano=8,fov=60,look=180:0
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay \
///     -remoteState pano=8 -panoramaAsset=frame
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay \
///     -remoteState pano=8,phase=0.25 -panoramaAsset=animated
/// ```
///
/// `selected` 写的是 `RemoteControl.selectedItemID`（瀑布流卡片的选中态）。
/// 它本该由外接屏那侧的命中判定写回，这里直接预置是为了绕开"没有触摸注入 API
/// 就点不动卡片"这个限制 —— 与 `pointer` 合起来就能截出「hover」与「选中」两态。
///
/// `strip=<index>` 是**素材条**那一排的预置（票 `07`）：把指针摆到第 `index` 条的
/// 槽心、并把那条选中。它是"条子的悬停环 / 选中环画得对不对"唯一可脚本化的入口 ——
/// 环画错了在截图上是"确实有个环"，只是亮在隔壁，肉眼极难判。
/// 槽心位置由 `PanoramaStripGeometry` 按**替身窗口的宽高比**算成归一化落点，
/// 所以它随 `-mockExternalDisplayAspect` 自动跟着走，不是写死的像素。
///
/// `lateral` 是横向推程（`-1` 最左、`+1` 最右），`bottom` 是底部上拉进度 ——
/// 两者都是"三条位移轴"里靠手势才能到达的状态，同样必须先能预置，
/// 否则幕墙推到边缘时的几何（有没有被推出屏外、那几个角的圆角对不对）
/// 就只剩肉眼看一遍。
///
/// `detail=<id>` 直接进照片详情页；加 `:fill` 后缀则进"铺满"模式
/// （`detail=7:fill`）。`pan=x:y` 是该页的归一化行程进度（`0` 居中、`±1` 两端）——
/// 这一条是详情页能被截图验证的**全部依据**：拖拽是连续手势，
/// 没有它就只能手划一遍，而"拖到边界时照片有没有露白"恰恰是最容易错的地方。
///
/// `pano=<id>` 与 `detail=<id>` 同义，只是写明"要进的是全景页"—— 画哪一页由
/// 卡片自己的 `projection` 决定，不由这里声明。`look=yaw:pitch`（度）预置
/// 全景视角；它由**代码顺序**保证在 `pano` / `detail` 之后写入，
/// 因为 `openDetail` 会把视角重置成正前方（票 `09`）。
///
/// `fov=<度>` 预置全景视场（票 `09`）。它**不受**上面那条次序约束 ——
/// `openDetail` 不碰视场（它是观看偏好，不是"这一页的位置"）。给一个不在
/// 档位表里的值会被折到最近的一档（`EquirectProjection.nearestFOV`），
/// 所以 `fov=75` 会落到 60° —— 这是刻意的：分段控件没有对应段可点亮。
///
/// `phase=<0..1>` 把**动画纹理**冻结在某个相位（票 `05`）。它配合
/// `-panoramaAsset=animated` 使用：动画档默认挂在 `TimelineView(.animation)`
/// 上、取的是挂钟时间，两次启动落在不同相位 ⇒ 截图基线不可复现。
/// 给了这一条就把那一帧钉死，于是"两个不同相位、经纬线仍在原处"
/// 这条判据才成立。与 `filter` 同一个归属（`DisplayContentStore`），
/// 同样不参与次序依赖。
///
/// 也支持 `-remoteState pull=0.5` 这种不带 `=` 的写法（与 `-mockExternalDisplayAspect`
/// 的解析保持一致）。
enum MockRemoteState {

    static var isEnabled: Bool {
        rawValue != nil
    }

    /// 取出 `-remoteState` 后面的原始字符串。
    static var rawValue: String? {
        let flag = "-remoteState"
        let arguments = ProcessInfo.processInfo.arguments

        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix(flag + "=") {
                return String(argument.dropFirst(flag.count + 1))
            } else if argument == flag, index + 1 < arguments.count {
                return arguments[index + 1]
            }
        }
        return nil
    }

    /// 解析结果。
    struct State: Equatable {
        var scroll: CGFloat?
        var pull: CGFloat?
        var bottom: CGFloat?
        var lateral: CGFloat?
        var zoom: CGFloat?
        var pointer: CGPoint?
        var selectedItemID: Int?
        var detailItemID: Int?
        var detailMode: PhotoViewMode?
        var detailPan: CGSize?
        var look: PanoramaLook?
        var fov: CGFloat?
        var filter: PanoramaFilter?
        var stripIndex: Int?
        var phase: Double?
    }

    /// 解析 `key=value` 列表，逗号分隔。无法识别的键直接忽略 ——
    /// 打错字时宁可少设一个状态，也不要让整个应用起不来。
    static func parse(_ raw: String) -> State {
        var state = State()

        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "scroll":
                state.scroll = CGFloat(Double(value) ?? 0)
            case "pull":
                state.pull = CGFloat(Double(value) ?? 0)
            case "bottom":
                state.bottom = CGFloat(Double(value) ?? 0)
            case "lateral":
                state.lateral = CGFloat(Double(value) ?? 0)
            case "zoom":
                state.zoom = CGFloat(Double(value) ?? 1)
            case "pointer":
                // `pointer=x:y` —— 用冒号而不是逗号，因为逗号已经是键值对之间的分隔符，
                // 复用会让 `pointer=0.3,0.35` 被切成两个残缺的键值对。
                // 冒号也与 `-mockExternalDisplayAspect=4:3` 的写法一致。
                let components = value.split(separator: ":").compactMap { Double($0) }
                if components.count == 2 {
                    state.pointer = CGPoint(x: components[0], y: components[1])
                }
            case "selected":
                state.selectedItemID = Int(value)
            case "detail":
                // `detail=7` 进详情页（整图）；`detail=7:fill` 直接进铺满模式。
                let parts = value.split(separator: ":").map(String.init)
                if let id = Int(parts.first ?? "") {
                    state.detailItemID = id
                    if parts.count > 1 { state.detailMode = parts[1] == "fill" ? .fill : .fit }
                }
            case "pan":
                // `pan=x:y`，与 `pointer` 同理用冒号分隔。
                let components = value.split(separator: ":").compactMap { Double($0) }
                if components.count == 2 {
                    state.detailPan = CGSize(width: components[0], height: components[1])
                }
            case "pano":
                // `pano=7` 与 `detail=7` 同义，只是写明"要进的是全景页"。
                // 留两个键是为了让截图脚本自解释：真正决定画哪一页的是**数据本身**
                // （`item.projection`），调用方声明的只是一个 id。
                if let id = Int(value) {
                    state.detailItemID = id
                }
            case "look":
                // `look=yaw:pitch`（度），与 `pointer` / `pan` 同理用冒号分隔。
                let components = value.split(separator: ":").compactMap { Double($0) }
                if components.count == 2 {
                    state.look = PanoramaLook(yaw: components[0], pitch: components[1])
                }
            case "fov":
                // `fov=<度>`：全景页的视场。非法值由 `nearestFOV` 折到最近档位。
                state.fov = CGFloat(Double(value) ?? EquirectProjection.defaultFOV)
            case "filter":
                // `filter=panorama` 切到「只看全景」，其余值（含 `all`）都是全部。
                // 它与上面那些量不同，落在 `DisplayContentStore` 而不是 `RemoteControl`，
                // 所以它**不受**"必须排在 detail 之后"那条次序约束 ——
                // 它改的是内容集合，跟当前在哪一页无关。
                state.filter = value == "panorama" ? .panoramaOnly : .all
            case "strip":
                // `strip=<index>`：素材条第几条（0 起）。越界在下面应用时丢弃。
                state.stripIndex = Int(value)
            case "phase":
                // `phase=<0..1>`：把**动画纹理**冻结在某个相位（票 `05`）。
                // 动画档默认挂在 `TimelineView(.animation)` 上，取的是挂钟时间 ⇒
                // 两次启动落在不同相位、截图基线不可复现。这一条是唯一可脚本化的入口，
                // 也是"两个不同时刻，经纬线还在原处"这条判据能成立的前提。
                // 折回 `[0, 1)` 交给绘制侧（见 `EquirectSourceCanvas.phase`）。
                state.phase = Double(value)
            default:
                continue
            }
        }

        return state
    }

    /// 把启动参数里的状态写进 `RemoteControl`（`filter` 那位写进 `DisplayContentStore`）。
    ///
    /// 顺序有讲究：先 `pull` 再 `scroll`、最后 `bottom`。`pull(to:)` 会清掉滚动，
    /// 反过来调用则不会 —— 想要"滚动到中段**同时**下拉"这种组合态时，
    /// 这个顺序才成立。`bottom(to:)` 必须排在 `scroll` 之后，理由见调用处。
    ///
    /// `lateral` 与它们互不干扰（另一条轴），放在哪一步都行，位置只是为了读起来顺。
    ///
    /// 默认值写成 `nil` 再在函数体里解析，而不是 `= .shared`：
    /// 默认参数表达式在**调用方**的上下文求值，而 `.shared` 是 `@MainActor` 隔离的，
    /// 直接写在参数上会触发「main actor-isolated property can not be referenced
    /// from a nonisolated context」告警。
    @MainActor
    static func applyIfNeeded(to target: RemoteControl? = nil, content store: DisplayContentStore? = nil) {
        guard let raw = rawValue else { return }
        let remote = target ?? .shared
        let state = parse(raw)

        // 先补上投影分流表。渲染侧是在 `.onAppear` 里注入的，而本函数跑在那**之前** ——
        // 而 `openDetail` 的**入口朝向**要读它（票 `09`）。不补这一句，
        // `-remoteState pano=8` 截出来是 `yaw 0°`（180° 那条经线仍在视口正中），
        // 看上去像锚点又错了一次，实际只是表还没注入。
        // 与 `look` 必须排在 `detail` 之后是同一类次序问题：状态之间有依赖，
        // 而依赖方向在代码里，不在命令行参数的书写顺序里。
        remote.setPanoramaItems(ExternalDisplayRootView.panoramaItems)

        if let pull = state.pull {
            remote.pull(to: pull)
        }
        if let scroll = state.scroll {
            remote.scroll(to: scroll)
        }
        // `bottom` 排在 `scroll` 之后：它把位置设到数轴的另一端（> 1），
        // 先设它再设 `scroll` 会被覆盖成"滚到某个进度"。
        if let bottom = state.bottom {
            remote.bottomPull(to: bottom)
        }
        if let lateral = state.lateral {
            remote.lateral(to: lateral)
        }
        if let zoom = state.zoom {
            remote.setZoom(zoom)
        }
        if let pointer = state.pointer {
            remote.movePointer(to: pointer, source: .touch)
        }
        // 放在最后：它不依赖上面任何一个量，但排在指针之后读起来
        // 与"先指过去、再点确认"的实际顺序一致。
        if let selected = state.selectedItemID {
            remote.select(item: selected)
        }
        // `strip` 排在 `selected` 之后、`detail` 之前。
        //
        // 两个次序都有理由：它自己会写 `selectedItemID`（选中那条对应的卡），
        // 与上面那个键写的是同一个量，谁后写谁生效，所以必须有个明确先后；
        // 而 `detail` 那段里的 `openDetail` 会把全景页的指针清掉
        // （见 `RemoteControl.openDetail`），若把 `strip` 排在它后面，
        // 「预置指针 + 顺带进了详情页」这个组合就会只剩后者 ——
        // 而这两种用法本来就不该混（条子是幕墙页的入口）。
        if let index = state.stripIndex {
            let assets = ExternalDisplayRootView.panoramaAssets
            if index >= 0, index < assets.count {
                // 参考视口只给宽高比：槽心的归一化落点与绝对点数无关
                // （见 `PanoramaStripGeometry.normalizedSlotCenter`）。
                // 宽高比取替身窗口那个 —— 预置与渲染必须用**同一个**比例，
                // 否则指针会稳稳地压在隔壁那条上，而截图上"确实有个环亮着"。
                let reference = CGSize(width: MockExternalDisplay.aspectRatio, height: 1)
                let geometry = PanoramaStripGeometry.make(
                    viewport: reference,
                    count: assets.count
                )
                remote.movePointer(to: geometry.normalizedSlotCenter(at: index), source: .touch)
                remote.select(item: assets[index].itemID)
            }
        }
        // 详情页相关的三个键必须排在**所有幕墙状态之后**：`openDetail` 会
        // 重置 `detailMode` 与 `detailPan`，先设它们就会被随后的一次
        // `openDetail` 抹掉（与 `bottom` 必须排在 `scroll` 之后是同一种次序问题）。
        if let detail = state.detailItemID {
            remote.openDetail(item: detail)
            if state.detailMode == .fill {
                remote.toggleDetailMode()
            }
        }
        if let pan = state.detailPan {
            remote.setDetailPan(pan)
        }
        // `look` 排在**最后**。注意这不是"命令行里要写在后面"—— 下面这些
        // `if let` 的执行顺序由**代码**固定，与参数书写的先后无关。
        // 放在末尾是因为 `openDetail`（由 `detail=` / `pano=` 触发）会把视角
        // 重置成 0，而 `setLook` 必须发生在那次重置**之后**才留得住。
        if let look = state.look {
            remote.setLook(look)
        }
        // 视场与 `look` 并列放在最后：它同样只在全景页可见，而 `openDetail`
        // 不重置它 —— 这个位置只是为了读起来与 `look` 挨着，
        // 不承担任何次序依赖（与 `filter` 同理）。
        if let fov = state.fov {
            remote.setPanoramaFOV(fov)
        }
        // 内容筛选落在 `DisplayContentStore`，与上面那些视口量不在同一个对象上。
        // 它也不参与上面的次序依赖（只换"摆哪些卡"，不动任何视口标量）。
        if let filter = state.filter {
            (store ?? .shared).filter = filter
        }
        // 动画相位与 `filter` 同一个归属（都是"显示什么"那半边），
        // 同样不参与次序依赖 —— 它只决定动画档停在哪一帧。
        if let phase = state.phase {
            (store ?? .shared).panoramaPhase = phase
        }
    }
}
