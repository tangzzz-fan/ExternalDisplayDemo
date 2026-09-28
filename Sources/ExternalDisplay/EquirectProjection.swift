import CoreGraphics
import Foundation

/// 全景视角（yaw / pitch）。
///
/// ## 这是一个**累积量**，不是姿态的直读
/// `CMAttitude` 的 Tait-Bryan 角归一化在 `(−π, π]` 区间里 —— 也就是说
/// **直接把某一帧的姿态当视角用，最多只能转到 ±180°，再转就跳变**。
/// 要覆盖 360° 只有一条路：逐帧取"本帧与上帧的**最短弧**增量"，再累加。
///
/// 累加的代价是**漂移会攒**：每一帧的量化误差都会留下来。
/// 所以 `recentered()` 不是"顺手的功能"，而是这条链路上**必需的**归零按钮 ——
/// 与 `AirMouse` 里 `recenter()` 存在的理由同源。
///
/// ## 与 `AirMouse` 的姿态处理是两套东西
/// 指针要的是"现在指向哪"（绝对映射一帧就够），视角要的是"总共转过多少"
/// （必须累积）。所以这里不复制 `AirMouse.smoothed` 那套，
/// 也不与它共享状态 —— 两者在同一份 `CMDeviceMotion` 上**物理互斥**，
/// 由输入层按页面分流。
///
/// ## 纯函数
/// 只依赖 `CoreGraphics` / `Foundation`，零 SwiftUI 依赖 ——
/// 于是它能进 `.scratch/verify/main.swift` 那条 `swiftc` 命令，
/// 「环绕不丢、夹取幂等」这些最容易算错的性质可以被真正断言。
struct PanoramaLook: Equatable, Sendable {

    /// yaw 的一个整圈。
    static let yawPeriod: CGFloat = 360

    /// Core 层的**护栏**夹取上限。
    ///
    /// 真正的可达范围取决于视口尺寸与 fov（见 `EquirectProjection.maxPitch`），
    /// 只有渲染侧知道 —— 所以这里只挡"超过天顶"这种物理上无意义的值，
    /// 真正的夹取由渲染侧每帧用 `clamped(toPitchLimit:)` 做并回写
    /// （与 `PhotoDetailGeometry.clamped(_:)` 同一条纪律）。
    static let pitchGuardrail: CGFloat = 90

    static let zero = PanoramaLook()

    /// 水平视角，`[0, 360)`。**环绕，永不夹取**。
    private(set) var yaw: CGFloat

    /// 俯仰视角，`[−90, 90]`。护栏夹取见 `pitchGuardrail`。
    private(set) var pitch: CGFloat

    init(yaw: CGFloat = 0, pitch: CGFloat = 0) {
        self.yaw = PanoramaLook.wrap(yaw)
        self.pitch = PanoramaLook.guardrailPitch(pitch)
    }

    /// 折到 `[0, 360)`。
    ///
    /// 用**取模**而不是夹取：yaw 是环上的坐标，"转到 370°"与"转到 10°"
    /// 是同一个位置，夹取会让走到 360° 之后画面停死。
    static func wrap(_ angle: CGFloat) -> CGFloat {
        guard angle.isFinite else { return 0 }
        let remainder = angle.truncatingRemainder(dividingBy: yawPeriod)
        return remainder < 0 ? remainder + yawPeriod : remainder
    }

    static func guardrailPitch(_ pitch: CGFloat) -> CGFloat {
        guard pitch.isFinite else { return 0 }
        return min(max(pitch, -pitchGuardrail), pitchGuardrail)
    }

    /// 最短弧增量：把任意角差折算到 `(−180, 180]`。
    ///
    /// 这是整条链路上唯一处理 ±180° 跨零的地方。少了它，
    /// 设备从 179° 转到 −179°（实际只转了 2°）会被读成 −358°，
    /// 画面瞬移半圈 —— 而它在慢速试玩里几乎撞不上，只在快速转头时炸。
    static func shortestArc(from previous: CGFloat, to current: CGFloat) -> CGFloat {
        guard previous.isFinite, current.isFinite else { return 0 }
        var delta = (current - previous).truncatingRemainder(dividingBy: yawPeriod)
        if delta > yawPeriod / 2 { delta -= yawPeriod }
        if delta <= -yawPeriod / 2 { delta += yawPeriod }
        return delta
    }

    /// 有符号 yaw，落在 `(−180, 180]`。
    ///
    /// 柱面（A 类）把 yaw 映射到横向平移进度时要用它 —— 那里的 pan 是
    /// 以居中为 0 的对称量，而 `yaw` 本身是 `[0, 360)` 的非负量。
    var signedYaw: CGFloat {
        yaw > PanoramaLook.yawPeriod / 2 ? yaw - PanoramaLook.yawPeriod : yaw
    }

    /// 按**增量**推进。
    ///
    /// 输入是"本帧相对上帧转过了多少"（调用方用 `shortestArc` 折过），
    /// 而不是绝对姿态 —— 这正是覆盖 360° 的唯一方式。
    func advanced(deltaYaw: CGFloat, deltaPitch: CGFloat, gain: CGFloat = 1) -> PanoramaLook {
        let step = gain.isFinite ? gain : 1
        return PanoramaLook(
            yaw: PanoramaLook.wrap(yaw + deltaYaw * step),
            pitch: PanoramaLook.guardrailPitch(pitch + deltaPitch * step)
        )
    }

    /// 按两帧的**原始姿态读数**推进，内部处理 ±180° 跨零。
    ///
    /// 输入直接是 `CMAttitude` 给的原始 yaw / pitch（会被回绕的那个），
    /// 调用方不必自己记上一帧 —— 把跨零处理收在这里，是为了让它**只有一份实现**，
    /// 也就能被同一组断言覆盖。
    func advanced(
        fromRawYaw previousRaw: CGFloat,
        toRawYaw currentRaw: CGFloat,
        rawPitch: CGFloat,
        gain: CGFloat = 1
    ) -> PanoramaLook {
        advanced(
            from: AttitudeReading(yaw: previousRaw),
            to: AttitudeReading(yaw: currentRaw, pitch: rawPitch),
            gain: gain
        )
    }

    /// 按两帧**姿态读数**推进视角（三个分量都参与）。
    ///
    /// ## yaw 与 roll 走增量、pitch 走绝对
    /// 这不是随手定的：
    ///
    /// - **横向必须累积**：`CMAttitude` 的 Tait-Bryan 角归一化在 `(−π, π]`，
    ///   直接当视角用最多只能转到 ±180°（见类型文档）。
    /// - **横向有第二个来源：roll**。手机"左右倾"这个动作在 `ZVertical` 参考系里
    ///   落的是 **roll**，不是 yaw —— 平持时绕机身长轴翻、竖持时绕屏法线翻，
    ///   两者在世界坐标里是同一条轴（见 `LookInput.reading`）。
    ///   只读 yaw 的话，"点头的对称动作"毫无反应，唯一有响应的是另一种手腕动作
    ///   （绕垂直轴拧），症状正是"上下很灵、左右几乎没反应"（票 `08` 的真机反馈）。
    ///   两个分量正交（一个绕 z、一个绕 y），相加就是"横向一共转了多少"。
    /// - **pitch 走绝对**：竖直方向的可达范围由渲染侧算出的 `maxPitch` 管着
    ///   （每帧夹取后回写）。绝对映射意味着"点一下头 20° 就是 20°"、回到原位
    ///   画面也回原位；改成累积反而会多出"松手不回正"这个漂移源。
    ///
    /// 两个增量的跨零都收在同一条 `shortestArc` 里 —— 它是本链唯一处理 ±180°
    /// 的地方，只留一份实现才可能被同一组断言覆盖。
    func advanced(
        from previous: AttitudeReading,
        to current: AttitudeReading,
        gain: CGFloat = 1
    ) -> PanoramaLook {
        let step = gain.isFinite ? gain : 1
        let swing = PanoramaLook.shortestArc(from: previous.yaw, to: current.yaw)
        let tilt = PanoramaLook.shortestArc(from: previous.roll, to: current.roll)
        return PanoramaLook(
            yaw: PanoramaLook.wrap(yaw + (swing + tilt) * step),
            pitch: PanoramaLook.guardrailPitch(current.pitch)
        )
    }

    /// 归零。
    ///
    /// 把当前朝向定为新的"正前方"：yaw 与 pitch 都清成 0。
    /// 漂移攒到看得出来了，用户按一下就回到正前方 —— 这是本线唯一的手动纠偏手段。
    func recentered() -> PanoramaLook { .zero }

    mutating func recenter() { self = .zero }

    /// 把 pitch 夹到渲染侧算出的**真正可达**范围（`limit` 不超过 ±90 的护栏）。
    ///
    /// 夹取必须**幂等**：渲染侧每帧夹一次后回写 `RemoteControl`，
    /// 若夹取不幂等，回写会形成"每帧改一点"的更新循环（见 `PhotoDetailGeometry.clamped`）。
    /// 同理 `limit` 若比护栏还大，以护栏为准 —— 否则 Core 层那道护栏形同虚设。
    func clamped(toPitchLimit limit: CGFloat) -> PanoramaLook {
        let bound = min(abs(limit), PanoramaLook.pitchGuardrail)
        return PanoramaLook(yaw: yaw, pitch: min(max(pitch, -bound), bound))
    }

    mutating func clamp(toPitchLimit limit: CGFloat) {
        self = clamped(toPitchLimit: limit)
    }
}

/// equirect（等距柱状）全景的投影几何。
///
/// ## 它跟 `PhotoDetailGeometry` 的本质差别
/// 照片详情页是**平移一张平面的图**；全景是**在一个包围你的表面上移动一个窗口**。
/// 所以平面的那两个方向不再对等：
///
/// - **水平方向是恒等，不是近似。** equirect 的横轴**就是**经度，且与角度成正比
///   ⇒ 图像横移 `displayWidth / 360` 点，正好等于视角转 1°。
/// - **垂直方向是近似。** equirect 的纵轴是纬度，而针孔相机的竖直视角是
///   `focal × tan(仰角)`。精确映射要求逐像素反查（`lat = pitch + atan(dy/focal)`），
///   SwiftUI 的矩形视图做不到。V1 取线性：
///   `originY = 居中基准 − pitch × (displayHeight / 180)`。
///
/// 线性近似在**视场中心是精确的**，误差随离屏心距离二次增长；
/// fov = 90° 时四角约在 1°~3° 量级 —— 看网格能看出来，看照片看不出来。
/// 升级成"分条带 tan 校正"的取舍记在 spec §4.2。
///
/// ## 为什么所有量都是"算出来的"而不是"存下来的"
/// 存几何会在 `look`、`fov`、`viewport` 三者之间产生一致性维护问题
/// （改一个忘改另一个，症状是画面错位）。这些都是同一份输入的纯函数，
/// 现算一遍的成本是常数级，换来的是"不可能不一致"。
struct EquirectProjection: Equatable, Sendable {

    /// 水平视场默认值。
    ///
    /// 90° = 转 90° 看到 1/4 圈。取它的理由是手感 1:1：
    /// 设备转过的角度与画面里内容移动的角度相同，最直观。
    static let defaultFOV: CGFloat = 90

    /// equirect 的源宽高比，固定 **2:1**。
    ///
    /// 这不是"取个常见值"，而是等距柱状的**定义**：经度覆盖 360°、
    /// 纬度覆盖 180°，两者在图上等比 ⇒ 宽:高 = 2:1。
    /// 比值不是 2 的图贴到这套几何上会垂直拉伸（素材脚本里有硬校验守这一条）。
    static let equirectAspect: CGFloat = 2

    /// fov 的合法区间。
    ///
    /// 下限 1° 只是护栏（挡住 0 与负数把 `displayWidth` 算成无穷）；
    /// 上限 180° 是物理上限 —— 针孔相机的水平视场不可能超过半圈，
    /// 而且超过 180° 之后"一份贴图铺不满一整圈"的假设就不再成立了。
    static let fovRange: ClosedRange<CGFloat> = 1...180

    let viewport: CGSize
    let fov: CGFloat
    let sourceAspect: CGFloat
    let look: PanoramaLook

    init(
        viewport: CGSize,
        fov: CGFloat = defaultFOV,
        sourceAspect: CGFloat = equirectAspect,
        look: PanoramaLook = .zero
    ) {
        self.viewport = viewport
        self.fov = EquirectProjection.clampedFOV(fov)
        // 与 `PhotoDetailGeometry` 同一条护栏：损坏的宽高比会一路算出 NaN 尺寸，
        // 表现为"整块画面凭空消失"，且看起来像渲染 bug，查错方向容易跑偏。
        let safeAspect = sourceAspect.isFinite ? sourceAspect : EquirectProjection.equirectAspect
        self.sourceAspect = min(max(safeAspect, 0.125), 8)
        self.look = look
    }

    static func clampedFOV(_ fov: CGFloat) -> CGFloat {
        guard fov.isFinite else { return defaultFOV }
        return min(max(fov, fovRange.lowerBound), fovRange.upperBound)
    }

    /// 贴图在"视角空间"里的宽度。
    ///
    /// `viewport.width` 是"看出去的窗口有多宽"，`360 / fov` 是"这一窗占了整圈多少"，
    /// 两者相乘就是整圈内容展开后有多宽。
    var displayWidth: CGFloat {
        guard viewport.width > 0 else { return 0 }
        return viewport.width * 360 / fov
    }

    /// 贴图高度。由源宽高比推出 —— equirect 固定 2:1 ⇒ 等于宽度的一半。
    var displayHeight: CGFloat {
        guard displayWidth > 0 else { return 0 }
        return displayWidth / sourceAspect
    }

    /// fov 的档位。手机端只在这些值之间切，不做无级滑杆。
    ///
    /// 有档位才有"这一个窗口宽多少度"的确定说法 —— 无级调节下每改一点窗口宽都变，
    /// 而"转 90° 换几屏"这个判据只能靠嘴说。默认 90° 必须在这个表里
    /// （它同时是 `fovRange` 的中点附近最保守的那个）。
    static let fovStops: [CGFloat] = [60, 90, 120]

    /// 折到最近的档位。
    ///
    /// 外部输入（调试预置、将来的设置同步）可能给一个不在表里的值，而"当前值必须在
    /// 档位表里"是这套 UI 自洽的前提：分段控件没有对应段可点亮，会渲染成一片空白。
    ///
    /// 折到**最近**而不是丢弃回默认：屏幕上正看着的画面不该因为一个越界输入跳档。
    static func nearestFOV(to fov: CGFloat) -> CGFloat {
        let safe = clampedFOV(fov)
        return fovStops.min { abs($0 - safe) < abs($1 - safe) } ?? defaultFOV
    }

    /// 贴图左上角的横向位置（视口坐标）。
    ///
    /// ## 口径：`yaw` 是**朝向**，不是窗口的左边缘（票 `09`）
    /// 视口**正中**显示的经线就是 `yaw` —— 转多少就同向移多少、转满一圈看完整图，
    /// 也就是"坐在转椅上转头"。所以贴图要摆到让 `yaw` 落在 `vw/2` 处：
    /// `raw = vw/2 − (yaw/360)·Dw`。
    ///
    /// 旧口径少了 `vw/2` 这一项，等价于"屏幕左边缘 = yaw"：`look=90` 不是"看向 90°"
    /// 而是"90° 线贴在左边缘"，而且与柱面那支（`CylindricalPan` 的 0 = 居中）
    /// 对同一份 `yaw` 给出两种含义。
    ///
    /// ## 再折到 `(−Dw, 0]`
    /// `yaw` 小的时候 `raw` 是**正的**（贴图整体右移），而 tile 基准落在这个半开区间
    /// 是 `tileCount` 公式成立的前提（`originX + tileCount·Dw ≥ vw`）。
    /// 折掉整数个 `Dw` 不改变任何一像素 —— 贴图周而复始，第 −1 份与第 0 份
    /// 画的是同一圈内容。
    ///
    /// 折完仍恰等于 `−Dw` 只可能出自浮点边界（`raw` 正好是 `Dw` 的整数倍），
    /// 那一位归 0：留成 `−Dw` 会让"范围是 `(−Dw, 0]`"这条不变量失效。
    var originX: CGFloat {
        guard displayWidth > 0 else { return 0 }
        let raw = viewport.width / 2 - (look.yaw / 360) * displayWidth
        let folded = raw - displayWidth * (raw / displayWidth).rounded(.up)
        return folded <= -displayWidth ? 0 : folded
    }

    /// 视口横坐标 `x` 处显示的是哪条经线（度，已折到 `[0, 360)`）。
    ///
    /// 这是"窗口"这个说法的**定义式**：屏幕不是一张被平移的图，
    /// 而是套在一个包围你的环上的取景框。`x = 0` 是左边缘、`x = vw` 是右边缘，
    /// 两点之间的经度差恒为 `fov`。
    func longitude(atScreenX x: CGFloat) -> CGFloat {
        guard displayWidth > 0 else { return look.yaw }
        return PanoramaLook.wrap((x - originX) / displayWidth * 360)
    }

    /// 视口**正中**显示的经线 —— 也就是"你此刻朝向哪"。
    ///
    /// 单独抽出来，是为了让"`yaw` 就是朝向"这件事**可断言**而不是靠文档承诺：
    /// 它是本票（`09`）的口径锚点，错了在静态截图上只表现为"内容整体偏了半个窗口"，
    /// 而那种偏差看上去完全像一个正常的视角。
    var facingLongitude: CGFloat {
        longitude(atScreenX: viewport.width / 2)
    }

    /// 垂直可动上限（度）。
    ///
    /// 令"转到头时照片顶/底边正好贴住视口"就能解出来：
    /// `pitch × (Dh / 180) = (Dh − vh) / 2` ⇒ `pitch = (1 − vh / Dh) × 90`。
    ///
    /// 这个闭式解干净的**与视口比例、fov 有关，与像素尺寸无关** ——
    /// 同一份代码在 1080p、4:3、letterbox 小窗口上推出同一个角度。
    ///
    /// 当 `displayHeight ≤ viewport.height`（纵向根本没超出）时给出 `0`：
    /// 那个方向**不可动**，而不是"动了但画面不变"—— 后者会让反向拖动"粘住"。
    var maxPitch: CGFloat {
        guard displayHeight > 0 else { return 0 }
        return max(0, (1 - viewport.height / displayHeight) * 90)
    }

    /// 贴图左上角的纵向位置（视口坐标）。
    ///
    /// `pitch = 0` → 垂直居中；`±maxPitch` → 顶/底贴边、不再越过。
    var originY: CGFloat {
        guard displayHeight > 0 else { return 0 }
        let centered = (viewport.height - displayHeight) / 2
        let bounded = min(max(look.pitch, -maxPitch), maxPitch)
        return centered - bounded * (displayHeight / 180)
    }

    /// 横向需要画几份贴图。
    ///
    /// 一份贴图铺不满一整圈（fov ≤ 180 时最多占半圈），所以**接缝处必须补一份
    /// 绕回来的内容** —— 不画它，转到接缝就会露出空白，而 360° 内容
    /// 本该无缝衔接，这是它与普通宽幅图最直观的差别。
    ///
    /// fov ≤ 180（合法区间内）时恒为 2：`Dw ≥ 2·vw` ⇒ `(vw + Dw)/Dw ≤ 1.5`。
    var tileCount: Int {
        guard displayWidth > 0 else { return 1 }
        let raw = (viewport.width + displayWidth) / displayWidth
        return max(1, Int(raw.rounded(.up)))
    }

    /// 贴图的完整落位（含纵向）。
    var offset: CGSize {
        CGSize(width: originX, height: originY)
    }
}

/// 柱面（A 类，iPhone 全景）的视角 → 横向平移映射。
///
/// 柱面**不新增几何**：它就是既有 `PhotoDetailGeometry(.fill)` 的
/// "铺满 + 可左右拖"，这里只负责把视角折成那条 `pan.width` 进度。
enum CylindricalPan {

    /// `yaw`（有符号度，`−180...180`）→ 平移进度 `−1...1`。
    ///
    /// 单调、线性、居中为 0 —— 与 `PhotoDetailGeometry.offset(for:)` 的
    /// 进度定义对齐（`0` 居中，`±1` 两端）。
    static func progress(forYaw yaw: CGFloat) -> CGFloat {
        guard yaw.isFinite else { return 0 }
        return min(max(yaw / 180, -1), 1)
    }

    /// 反向：进度 `−1...1` → yaw。
    ///
    /// 供"从预置进度反推该给什么视角"用（截图矩阵里 `look` 与 `pan` 要能互相对照）。
    static func yaw(forProgress progress: CGFloat) -> CGFloat {
        guard progress.isFinite else { return 0 }
        return min(max(progress, -1), 1) * 180
    }
}
