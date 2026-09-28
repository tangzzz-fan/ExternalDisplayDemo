import CoreGraphics
import Foundation

/// 一帧的姿态读数：三个 Tait-Bryan 分量（度）。
///
/// ## 为什么打包成类型，而不是继续传三个 `CGFloat`
/// 三个裸数传下去之后，"哪个是哪个"只剩位置关系 —— 而在视角那条链上
/// 三者的**用法完全不同**：横向（yaw 与 roll）走逐帧增量累积，竖向（pitch）
/// 走绝对映射。调换两个参数既不报错也不崩，只会让某个方向莫名地反了或不动，
/// 而静态截图里没有"转的方向"这个信息。具名类型让参数自解释。
///
/// ## 区间口径
/// 与 `CMAttitude` 的 Tait-Bryan 角一致：`(−180, 180]`，**不是** `[0, 360)`。
/// 折算只发生在累积那一步（`PanoramaLook.shortestArc` + `wrap`），
/// 所以这里不做任何折角 —— 把 `yaw` 提前归一到 `[0, 360)` 会在跨零点时
/// 让 `shortestArc` 收到一对不同口径的输入。
///
/// 非有限值不在这里拦：消费它的 `shortestArc` / `guardrailPitch` 各自都判了
/// `isFinite`，在这里再拦一次只是多一份要同步的护栏。
struct AttitudeReading: Equatable, Sendable {

    /// 绕参考系 z 轴（= 世界垂直轴）的转动。**罗盘式转身**喂它。
    var yaw: CGFloat

    /// 绕参考系 x 轴的俯仰。**点头**喂它。
    var pitch: CGFloat

    /// 绕参考系 y 轴（= 手机初始朝向那条世界水平线）的翻滚。
    ///
    /// **左右倾手机喂它** —— 它才是点头在世界坐标里的对称动作（见
    /// `LookInput.reading` 与票 `08`）。竖持时倾的是屏法线，而屏法线正好是
    /// 同一条轴的负向，所以两种握法同号。
    var roll: CGFloat

    static let zero = AttitudeReading(yaw: 0, pitch: 0, roll: 0)

    init(yaw: CGFloat = 0, pitch: CGFloat = 0, roll: CGFloat = 0) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }
}

/// 拖动增量 → 全景视角增量；相对姿态 → 视角读数。
///
/// ## 为什么单独抽一个类型
/// 方向与系数是这条链路上**最容易被写成"看着对"**的两件事：符号错了画面照样动，
/// 只是反着转；系数错了也照样动，只是手感不对。两者都不报错，
/// 而静态截图里**没有"转的方向"这个信息** —— 单张图看不出它是从 90° 转到 180°
/// 还是从 180° 转到 90°。所以它必须能进 `.scratch/verify/main.swift` 那条
/// `swiftc` 命令，被真正断言，而不是靠看一遍。
///
/// ## 为什么系数不用 `fov`
/// `fov` 是"一窗看到多少"，这里是"手滑一屏转多少"。两者混在一起之后，
/// 调 `fov` 会顺手改掉拖动的手感 —— 而调 `fov` 的本意只是改视场。
/// 分开之后各自独立：真要 1:1 的手感，再单独调这个常数。
enum LookInput {

    /// 拖动**一个采集面高/宽**，视角转过多少度。
    ///
    /// 取 180°：滑一屏 = 半圈，滑两屏 = 转满一圈。
    /// 与幕墙"拖一屏走一屏"的手感同源 —— 全景页与幕墙页的拖动不该是两种手感。
    static let degreesPerSwipe: CGFloat = 180

    /// 纵向拖动 → pitch 增量（度）。
    ///
    /// 入参口径是 `RemoteControl.scroll(by:)` 的 `dy`（归一化位移，手指上滑为负）。
    ///
    /// **拖动即转身**（票 `09`）：手指上滑 `dy < 0` → 抬头看上方 → 视线上升。
    /// 而 `PanoramaLook.pitch` 为**正**表示看向下方
    /// （`EquirectProjection.originY = centered − pitch · Dh/180`：pitch 增大则贴图上移，
    /// 视口看到的是贴图更靠下的部分），所以增量与 `dy` **同号**。
    static func pitchDelta(forScroll dy: CGFloat) -> CGFloat {
        guard dy.isFinite else { return 0 }
        return dy * degreesPerSwipe
    }

    /// 横向拖动 → yaw 增量（度）。
    ///
    /// 入参口径是 `RemoteControl.lateral(by:)` 的 `dx`（归一化位移，手指右滑为正）。
    ///
    /// **拖动即转身**（票 `09`）：手指右滑 `dx > 0` → 转身向右 → 视线右移。
    /// 而 `PanoramaLook.yaw` 增大就是视线右移
    /// （`originX = vw/2 − (yaw/360) · displayWidth`：yaw 增大则贴图左移、露出右侧），
    /// 所以增量与 `dx` **同号**。
    ///
    /// ## ⚠️ 它刻意**不**与幕墙的 `lateral(by:)` 同向
    /// 幕墙那条是"推板、露出那一侧的星海"（手指右滑 → 板右移 → 露出左侧）；
    /// 全景页是"转身、看向那一侧"。判据是**你在这个页面上想干什么** ——
    /// 幕墙上你想挪动内容，全景页里你想转动视线。
    ///
    /// 旧口径（跟手）与空鼠那条"转头 → 同向扫"正好反向：同一页里两条输入源
    /// 会给出相反的结果，而用户只会觉得"它有时候是反的"。票 `09` 的取舍是
    /// **页内必须同向、页间允许不同向**。
    static func yawDelta(forLateral dx: CGFloat) -> CGFloat {
        guard dx.isFinite else { return 0 }
        return dx * degreesPerSwipe
    }

    /// 相对姿态的三个 Tait-Bryan 角（度）→ 视角读数（度）。
    ///
    /// 输入是 `CMAttitude` 经 `multiply(byInverseOf: origin)` 之后的相对量，
    /// 单位从弧度折成度。**符号是这条链上唯一靠推导而非靠试的东西**，
    /// 所以三支都写明依据：
    ///
    /// - **yaw 取负**：`AirMouse` 的常规映射回答"指向哪"（`x = 0.5 − θ/sweep`），
    ///   而视角问的是"看向哪" —— 指向左就该看向左；`look.yaw` **减小**才是视线左移
    ///   （`originX = vw/2 − (yaw/360)·Dw`：yaw 减小则贴图右移、露出左侧），所以取负。
    ///   绕 +z 的正向转动把手机的指向从北转向西（`R_z(θ)` 把 x 轴转向 y 轴方向），
    ///   即"把手机转向左"—— 与上面的"指向左"同向，符号一致。
    ///
    /// - **roll 不取负**：手机"往左倾"是绕参考 y 轴的一次**负**转动
    ///   （`R_y(φ)` 的正向把 z 轴转向 +x，即左边缘抬起；左倾是它的反向）。
    ///   而它同样应当让视线左移（yaw 减小）—— 负增量 × 正号 = 所需方向，
    ///   所以这里**不加**负号。平持（绕机身长轴）与竖持（绕屏法线）两种握法
    ///   在世界坐标里同号，推导与 yaw 一致，于是两者能共用同一个反向开关。
    ///
    /// - **pitch 取负**：`AirMouse` 的指针口径里"指向下 → pitch 减小 → y 增大"，
    ///   而视角里 `pitch` 为**正**表示看向下方
    ///   （`originY = centered − pitch · Dh/180`：pitch 增大则贴图上移，
    ///   视口看到贴图更靠下的部分）。两套口径反号，所以取负。
    ///
    /// 两个反向开关与 `AirMouse` 的指针链**共用**（见 `AirMouse.invertHorizontal`
    /// 的文档）：两条链的符号出自同一个握持假设，真机上反了必然是同一个原因。
    static func reading(
        fromRelativeYaw yaw: CGFloat,
        pitch: CGFloat,
        roll: CGFloat,
        invertHorizontal: Bool,
        invertVertical: Bool
    ) -> AttitudeReading {
        let signX: CGFloat = invertHorizontal ? -1 : 1
        let signY: CGFloat = invertVertical ? -1 : 1
        let degrees = 180 / CGFloat.pi

        return AttitudeReading(
            yaw: -yaw * degrees * signX,
            pitch: -pitch * degrees * signY,
            roll: roll * degrees * signX
        )
    }
}
