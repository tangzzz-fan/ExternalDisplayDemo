import UIKit

/// 手机屏（主屏）的 scene。
///
/// 这个类本身与外接屏无关，它只负责挂上手机端 UI。
/// 放在这里是为了让 `ExternalDisplaySceneDelegate` 保持纯粹。
final class MainSceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        assert(session.role == .windowApplication, "MainSceneDelegate 只应收到 windowApplication role")

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = PhoneRootViewController()
        window.makeKeyAndVisible()
        self.window = window

        // 模拟器无法接外接屏，用 `-mockExternalDisplay` 启动参数起一个假的
        MockExternalDisplay.shared.bootstrap(on: windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        MockExternalDisplay.shared.reset()
        window = nil
    }
}
