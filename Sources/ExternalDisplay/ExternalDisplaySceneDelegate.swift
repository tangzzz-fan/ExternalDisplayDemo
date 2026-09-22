import UIKit
import SwiftUI

/// 外接屏的 scene —— 整个接入链路的全部落点。
///
/// ## 何时会被调用
/// 由系统决定，应用无法主动创建：
/// - **iOS 17 ~ 26**：只要 `Support/Info.plist` 里声明了
///   `UIWindowSceneSessionRoleExternalDisplayNonInteractive`，
///   屏幕一接入系统就自动建立 session 并回调到这里。
/// - **iOS 27 起**：该系统行为被移除。应用必须先通过
///   `PhoneRootViewController` 注册 `UISceneAccessory`，系统才会连接本 scene。
///   仅靠 Info.plist 声明在 iOS 27+ 上不再生效，表现为「插上屏只镜像、不扩展」。
///
/// 触发场景：有线接入 USB-C / Lightning 转 HDMI 适配器、AirPlay 投送、
/// 以及 iPad 台前调度下的外接显示器。应用只负责声明与响应。
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {

    /// 与 `Support/Info.plist` 中 `UISceneConfigurationName` 保持一致。
    static let configurationName = "External Display Scene"

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        // 一个 delegate 可能被多个 role 复用，先自证身份。
        // Swift 名 `windowExternalDisplayNonInteractive` 来自
        // UIWindowSceneSessionRoleExternalDisplayNonInteractive（iOS 16.0+）。
        guard session.role == .windowExternalDisplayNonInteractive,
              let windowScene = scene as? UIWindowScene else { return }

        // 外接屏上不能再用 UIScreen.main / UIScreen.screens（均已废弃），
        // 屏幕信息一律从当前 windowScene 拿。
        let screen = windowScene.screen

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(
            rootView: ExternalDisplayRootView(
                resolution: "\(Int(screen.nativeBounds.width)) × \(Int(screen.nativeBounds.height))"
            )
        )
        // 该 role 本身不接收触摸事件（非交互屏），这里显式写出来只是表明语义。
        window.isUserInteractionEnabled = false

        // 刻意不用 makeKeyAndVisible()：外接屏窗口不应该从手机屏抢走 key 状态，
        // 否则手机端的第一响应者 / 键盘焦点可能被打断。
        window.isHidden = false
        self.window = window

        ExternalDisplayMonitor.shared.attach(windowScene)

        // iOS 27+ 若在 accessory 创建时带了 userInfo，
        // 可从 `connectionOptions.sceneAccessoryUserInfo` 取到，
        // 用来区分同一份 delegate 服务的不同外接屏用途。
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // 屏幕拔出。必须在这里释放 window，否则会残留一个无人持有的渲染面。
        ExternalDisplayMonitor.shared.detach(scene.session.persistentIdentifier)
        window = nil
    }
}
