import SwiftUI
import UIKit

/// 主屏 `UIWindowScene` 的登记处。
///
/// SwiftUI **没有** windowScene 的环境值（只有 `scenePhase`），所以只能在宿主 VC 里
/// 反查出来存一份，供 `ExternalDisplayDemoApp` 在 `scenePhase` 变化时重新 bootstrap。
@MainActor
enum PhoneSceneLocator {
    static weak var scene: UIWindowScene?
}

/// 纯 SwiftUI 下接管原 `MainSceneDelegate` + `PhoneRootViewController` 的职责。
///
/// SwiftUI 没有 windowScene 的环境值（只有 `scenePhase`），只能在宿主 VC 里反查出来存一份，
/// 供 `ExternalDisplayDemoApp` 在 `scenePhase` 变化时重新 bootstrap 模拟外接屏替身：
///
/// 优先从 `view.window?.windowScene` 反查；`viewDidLoad` 阶段 `view.window` 还是 nil，
/// 退回遍历 `UIApplication.shared.connectedScenes` 找 `windowApplication` role。
///
/// 挂载方式是根视图的 `.background`，零尺寸即可 —— 它不参与布局，
/// 只需要真实存在于视图层级里。
///
/// > iOS 27 的 scene accessory 注册**已经不在这里**：改用 SwiftUI 原生
/// > `View.sceneAccessory`，见 `ExternalDisplayAccessory`。
struct PhoneSceneBridge: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> BridgeViewController {
        BridgeViewController()
    }

    func updateUIViewController(_ controller: BridgeViewController, context: Context) {}

    final class BridgeViewController: UIViewController {

        override func viewDidLoad() {
            super.viewDidLoad()

            // 不参与交互，也不显示任何东西，只作为宿主存在。
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false

            syncScene()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // 此时 `view.window` 必定可用，再确认一次。
            syncScene()
        }

        // MARK: - 主屏 scene

        private func syncScene() {
            guard let scene = view.window?.windowScene ?? Self.mainWindowScene else { return }
            PhoneSceneLocator.scene = scene
            MockExternalDisplay.shared.bootstrap(on: scene)
        }

        private static var mainWindowScene: UIWindowScene? {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.session.role == .windowApplication }
        }
    }
}
