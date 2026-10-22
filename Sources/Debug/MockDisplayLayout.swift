import CoreGraphics

/// 替身屏在手机屏上的两种摆法。
///
/// 竖屏时它是一条居中的宽条（宽度顶满、上下留黑）；横屏时手机纵向只剩一百多点，
/// 同样一条宽条会盖掉大半屏 —— 所以横屏改成右下角的 PIP：**保留，但不抢位置**。
///
/// 纯几何，不依赖 UIKit / SwiftUI，可以独立断言。
enum MockDisplayLayout {

    /// 横屏 PIP 的高度占可用高度的比例。
    ///
    /// 取值靠"能看清、又不挡住手势面"两头夹：低于 0.35 那块 16:9 里认不出字，
    /// 高于 0.5 就和手机端状态栏、手势面抢地方了。
    static let pipHeightRatio: CGFloat = 0.42

    /// 判据用宽高比，而不是 `UIDevice.orientation`。
    ///
    /// 后者在「手机横放但 app 仍按竖屏排版」（比如某些 iPhone 只声明了竖屏）的场合会撒谎，
    /// 而容器比宽更宽这件事本身就是横屏布局成立的充要条件。
    static func isLandscape(_ container: CGRect) -> Bool {
        container.width > container.height
    }

    /// 距容器边缘的留白。
    private static let edge: CGFloat = 16

    static func rect(in container: CGRect, aspect: CGFloat) -> CGRect {
        guard container.width > 0, container.height > 0, aspect > 0 else { return container }

        return isLandscape(container)
            ? pipRect(in: container, aspect: aspect)
            : centeredRect(in: container, aspect: aspect)
    }

    /// 竖屏：宽度顶满，高度按宽高比算。
    ///
    /// 这里没有"高度受限"那个分支 —— 竖屏容器满足 `width <= height`，
    /// 而 `width / height > aspect`（16:9）要求 `width > height`，两者不可能同时成立。
    /// 换句话说，只要判定成竖屏，宽度就一定是瓶颈。
    private static func centeredRect(in container: CGRect, aspect: CGFloat) -> CGRect {
        let height = container.width / aspect
        return CGRect(
            x: container.minX,
            y: container.midY - height / 2,
            width: container.width,
            height: height
        )
    }

    /// 横屏：右下角，按高度定尺寸。
    private static func pipRect(in container: CGRect, aspect: CGFloat) -> CGRect {
        var height = container.height * pipHeightRatio
        var width = height * aspect

        // 容器极窄（分屏 / 超宽比）时按宽度收，否则 PIP 会顶出边界。
        let maxWidth = max(container.width - edge * 2, 1)
        if width > maxWidth {
            width = maxWidth
            height = width / aspect
        }

        return CGRect(
            x: container.maxX - edge - width,
            y: container.maxY - edge - height,
            width: width,
            height: height
        )
    }
}
