import CoreGraphics
import Foundation

/// 外接屏左上角「返回」按钮的几何。
///
/// ## 为什么做成纯几何
/// 按钮的命中与卡片命中是同一类事（指针落点 → 有没有东西被踩中），
/// 而卡片那套（`WaterfallFocus`）已经证明：做成纯函数就能在没有模拟器的情况下
/// 断言边界。按钮的输入比它更少（只有视口），没有理由不照做。
///
/// ## 为什么是圆，而不是一条栏
/// 需求里有一条明确的否命题：按钮**不能形成一条横栏**。
/// 一条铺满屏宽的不透明栏会把幕墙从视觉上切成两段 —— 上沿露出的星海与幕墙本体
/// 被那条栏隔开，看起来像两个不相干的区域。所以这里只画一个圆，浮动在幕墙之上，
/// 四周透出去的都是幕墙本身。
///
/// 命中同样按**圆**判，不是按外接矩形：指针从四角划过时，矩形会在视觉上
/// 根本没有按钮的地方把点击吃掉 —— 按钮是圆的，判定就该是圆的。
struct BackButtonGeometry: Equatable, Sendable {

    let viewport: CGSize

    /// 圆形按钮的直径占画面短边的比例。
    ///
    /// 模拟器替身窗口（362 × 195.6）上是 21.5pt，1080p（960 × 540）上是 59.4pt ——
    /// 与项目里其它尺寸同源，跟着短边等比缩放。
    static let diameterRatio: CGFloat = 0.11

    /// 按钮外沿距屏幕上、左两条边的距离，同样按短边取比例。
    static let marginRatio: CGFloat = 0.045

    /// 画面短边。与项目里其它几何同源（`min(width, height)`）。
    var base: CGFloat { min(viewport.width, viewport.height) }

    var diameter: CGFloat { base * Self.diameterRatio }

    /// 按钮圆心。
    ///
    /// 边距钉的是**外沿**（`margin + 直径/2`），不是圆心 —— 需求说的是
    /// "左上角一个按钮"，人眼看到的是它的外轮廓到屏幕边的距离。
    var center: CGPoint {
        let margin = base * Self.marginRatio
        return CGPoint(x: margin + diameter / 2, y: margin + diameter / 2)
    }

    var frame: CGRect {
        CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    func contains(_ point: CGPoint) -> Bool {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = diameter / 2
        return dx * dx + dy * dy <= radius * radius
    }
}
