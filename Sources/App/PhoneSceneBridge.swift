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
/// SwiftUI 有两样东西拿不到，只能借一个宿主 VC 补齐：
///
/// 1. **主屏的 `UIWindowScene`** —— 优先从 `view.window?.windowScene` 反查；
///    `viewDidLoad` 阶段 `view.window` 还是 nil，退回遍历
///    `UIApplication.shared.connectedScenes` 找 `windowApplication` role。
/// 2. **`registerSceneAccessory(_:)` 的宿主** —— iOS 27 起外接屏 scene 不再自动连接，
///    必须在一个「主界面里的 view controller」上注册，且句柄要强引用住。
///
/// 挂载方式是根视图的 `.background`，零尺寸即可 —— 它不参与布局，
/// 只需要真实存在于视图层级里（`registerSceneAccessory` 的生效条件是宿主处于呈现状态）。
struct PhoneSceneBridge: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> BridgeViewController {
        BridgeViewController()
    }

    func updateUIViewController(_ controller: BridgeViewController, context: Context) {}

    final class BridgeViewController: UIViewController {

        /// `registerSceneAccessory` 的句柄，**必须强引用住**，否则注册立即失效。
        ///
        /// 用 `Any?` 承接是因为该类型标注了 `API_AVAILABLE(ios(27.0))`，
        /// 而本 target 的 deployment target 是 17.0，直接写类型名会要求
        /// 整个属性做可用性标注。
        private var sceneAccessoryRegistration: Any?

        override func viewDidLoad() {
            super.viewDidLoad()

            // 不参与交互，也不显示任何东西，只作为宿主存在。
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false

            syncScene()
            registerExternalDisplayAccessory()
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

        // MARK: - Scene accessory（iOS 27+）

        private func registerExternalDisplayAccessory() {
            guard sceneAccessoryRegistration == nil else { return }
            guard #available(iOS 27.0, *) else { return }

            // 用与 Info.plist 中一致的配置名，同时显式指定 delegateClass，
            // 这样即使 plist 查表失败也能落到同一个 scene delegate 上。
            let configuration = UISceneConfiguration(
                name: ExternalDisplaySceneDelegate.configurationName,
                sessionRole: .windowExternalDisplayNonInteractive
            )
            configuration.delegateClass = ExternalDisplaySceneDelegate.self

            let accessory = UISceneAccessory.externalNonInteractive(sceneConfiguration: configuration)
            sceneAccessoryRegistration = registerSceneAccessory(accessory)
        }
    }
}
