import CoreGraphics
import Foundation

/// 幕墙横向推开的位移几何。
///
/// ## 为什么要单独一个类型，而不是塞进 `ScrollMetrics`
/// 纵向的 `ScrollMetrics` 里全是"进度"：滚动进度、下拉进度，都是 `0...1` 的无符号量，
/// 靠 `RemoteControl.position` 的正负去分派语义。
///
/// 横向**没有这层关系**：它是纯粹的位移，`0` 在正中、正负各一边，
/// 两条边同时也是两个极限。硬塞进 `ScrollMetrics` 就得在里面再写一套
/// "带符号的进度"，两套语义共用一个类型，读代码的人要先猜这一处用的是哪套。
///
/// 所以并列成两个类型，各自只讲一件事。
struct LateralMetrics: Equatable, Sendable {

    let viewport: CGSize

    /// 满行程时幕墙能横移多少，占画面**短边**的比例。
    ///
    /// `0.278` 这个数是反推出来的：需求钉的是"幕墙移动 150pt"，
    /// 而 1080p 外接屏按本项目的惯例折算成 `960 × 540 pt`（短边 540），
    /// 于是 `150 / 540 ≈ 0.278`。
    ///
    /// 为什么钉在**幕墙**这一侧而不是手指那一侧：手机采集面宽约 370pt、
    /// 外接屏可以是 960pt，归一化 1:1 映射之下这两件事不可能同时成立
    /// （见 `PadGesture` 的归一化口径）。钉住幕墙，观感在哪块屏上都一致；
    /// 手指要滑多远才能推满，那是采集面的手感参数，归 `LateralCurve.rawLimit` 管。
    ///
    /// 模拟器替身窗口（362 × 204）上这个上限是 56.7pt，恰好也是屏宽的 **16%** ——
    /// 比例不随屏幕尺寸漂移，这正是按短边取比例的意义。
    static let travelRatio: CGFloat = 0.278

    /// 满行程的横向位移。
    var maxTravel: CGFloat {
        min(viewport.width, viewport.height) * Self.travelRatio
    }

    /// 归一化推程 → 实际位移。正数 = 幕墙右移（露出左侧星海）。
    ///
    /// 硬钳制在 `±1`：超限不做回弹。本项目至今没有回弹机制
    /// （滚动与下拉都是"手指停在哪就停在哪"），横向与它们保持一致，
    /// 免得出现"三条轴里只有一条会弹"这种要单独解释的行为。
    func offset(for lateral: CGFloat) -> CGFloat {
        maxTravel * min(max(lateral, -1), 1)
    }
}

/// 横向推开的手感曲线。
///
/// 与 `PullCurve` 同族（`1 - (1 - t)^e`，`t = 1` 处**恰好**取到 1），
/// 区别只有一个：这条是**带符号**的。
///
/// 手感曲线必须是**唯一**来源：手机端读数、渲染侧位移、验证脚本的断言
/// 三处都取自这里，才不会出现"改了模型没改渲染"或"测的是另一条曲线"。
/// 与 `PullCurve` 分开的理由同 `LateralMetrics` —— 一个无符号进无符号出，
/// 一个带符号进带符号出，合成一个类型反而要靠参数去区分调用姿势。
enum LateralCurve {

    /// 到达 `lateral == ±1` 所需的原始行程（归一化到采集面**宽度**）。
    ///
    /// `0.42` 的来历：纵向 `rawLimit` 是 `0.9` 个**板高**，而采集面高 168pt，
    /// 也就是推满一条轴要滑约 151pt。横向沿用同一个**物理行程**，
    /// 除以采集面宽 360pt 得到 `0.42` —— 两条轴推到底所付出的手指距离一致，
    /// 手感才是同一个人写的。
    ///
    /// 若照抄 `0.9`（即按宽度归一化也取 0.9），推满要滑 324pt，
    /// 触控板上一次滑动几乎不可能覆盖，横向就变成"推不动"的那条轴。
    static let rawLimit: CGFloat = 0.42

    /// 阻尼指数。与 `PullCurve` 取同一个值，两条轴的"先松后紧"才是同一种观感。
    static let exponent: CGFloat = 1.7

    /// 原始行程 → 归一化推程（`-1...1`）。符号跟着 `raw` 走。
    static func progress(raw: CGFloat) -> CGFloat {
        guard raw != 0 else { return 0 }
        let t = min(abs(raw) / rawLimit, 1)
        let magnitude = 1 - CGFloat(pow(Double(1 - t), Double(exponent)))
        return raw < 0 ? -magnitude : magnitude
    }

    /// 归一化推程 → 原始行程。`progress(raw:)` 的反函数。
    ///
    /// 供滑杆与调试状态预置使用 —— 它们想给的是"推开多少"，
    /// 而权威量是原始行程，换算必须在这里做，不能让调用方自己凑。
    static func rawValue(forProgress progress: CGFloat) -> CGFloat {
        let magnitude = min(abs(progress), 1)
        guard magnitude > 0 else { return 0 }
        let raw = rawLimit * (1 - CGFloat(pow(Double(1 - magnitude), 1 / Double(exponent))))
        return progress < 0 ? -raw : raw
    }
}
