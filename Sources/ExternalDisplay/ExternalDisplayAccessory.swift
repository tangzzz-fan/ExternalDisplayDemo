import SwiftUI

/// 外接屏 scene accessory 的声明处（iOS 27+）。
///
/// ## 为什么 iOS 27 起必须声明它
/// Apple 文档：*"Beginning in iOS 27, your app receives a scene with the
/// `windowExternalDisplayNonInteractive` role only after it registers a scene accessory.
/// In earlier releases, the system connected this scene automatically."*
/// 也就是光在 `Support/Info.plist` 里声明 role 不再够用，只声明不注册的表现是
/// **外接屏上只出现手机画面的镜像**（静默、无日志）。
///
/// ## 为什么用 SwiftUI 原生 API 而不是 UIKit 注册
/// 用 `View.sceneAccessory { ExternalNonInteractiveAccessory { … } }` 相比
/// `UIViewController.registerSceneAccessory(_:)` 少两类失效模式：
///
/// 1. **不需要宿主 VC** —— UIKit 那条路的语义是「随该 VC 的呈现状态生效」，
///    于是必须凑一个真实存在于视图层级里的控制器，还要担心它有没有真的在呈现；
///    声明式写法由系统决定何时呈现，没有这个前置条件。
/// 2. **不需要自己强引用注册句柄** —— UIKit 那条路返回 `UISceneAccessoryRegistration`，
///    引用一松手注册立即失效，是个很容易踩的生命周期坑；这边没有句柄。
///
/// ## iOS 17~26 怎么办
/// `sceneAccessory` 标了 `@available(iOS 27.0, *)`，而本 target 的 deployment target
/// 是 17.0，所以必须包在 `if #available` 里。更早的系统落到 `else` 分支 ——
/// 那条路仍由 `Support/Info.plist` 里声明的 external role 自动连接，
/// 内容由 `ExternalDisplaySceneDelegate` 挂载。两条路复用同一份 `ExternalDisplayRootView`。
private struct ExternalDisplayAccessoryModifier: ViewModifier {

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.sceneAccessory {
                ExternalNonInteractiveAccessory {
                    ExternalDisplayRootView(onMetricsChange: Self.report)
                }
                .onAvailabilityChange { isAvailable in
                    // 这条回调本身也是「注册被系统接受」的唯一可观测信号：
                    // 没有外接屏时它会被回调一次 `false`。
                    // 整条外接屏链路的失败模式清一色是「静默」，所以这里留一个观测点。
                    #if DEBUG
                    print("[ExternalDisplay] scene accessory availability = \(isAvailable)")
                    #endif
                    ExternalDisplayMonitor.shared.setAccessoryAvailable(isAvailable)
                }
            }
        } else {
            content
        }
    }

    /// 纯 SwiftUI 路径拿不到 `UIWindowScene`（没有 scene delegate 就没有 windowScene），
    /// 而手机端连接状态需要分辨率 —— 由外接屏那份内容把自己的实际尺寸量出来上报。
    private static func report(pixelSize: CGSize, nativeScale: CGFloat) {
        ExternalDisplayMonitor.shared.attachAccessory(
            pixelSize: pixelSize,
            nativeScale: nativeScale
        )
    }
}

extension View {

    /// 声明「外接屏」scene accessory。
    ///
    /// - iOS 27+：走 SwiftUI 原生 `sceneAccessory`，本调用即注册动作；
    /// - iOS 17~26：no-op，那条路由 Info.plist 的 external role 自动连接。
    ///
    /// 挂在 `WindowGroup` 的根视图上即可，与挂载位置无关的附加动作都不要写在这里。
    func externalDisplaySceneAccessory() -> some View {
        modifier(ExternalDisplayAccessoryModifier())
    }
}
