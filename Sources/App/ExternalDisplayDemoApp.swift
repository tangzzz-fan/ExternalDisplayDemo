import SwiftUI

/// 纯 SwiftUI 生命周期的入口。
///
/// 取代原来的 `AppDelegate` + `MainSceneDelegate` + `PhoneRootViewController` 三层：
///
/// - `@main` 从 `AppDelegate` 挪到这里；
/// - 主屏 scene 交给 `WindowGroup`，SwiftUI 自己装 scene delegate。
///   `Support/Info.plist` 里那个 `UIWindowSceneSessionRoleApplication` 空壳条目属于
///   **惰性保留**，不是必需项：实测（iOS 27）删掉它、乃至把整块 `UISceneConfigurations`
///   一起删掉，SwiftUI 都照常启动。它唯一的约束是**不能带 `UISceneDelegateClassName`**，
///   带上会与 SwiftUI 自己装的 scene delegate 冲突。
///   真正必需的是 external role 那条 —— iOS 17~26「plist 自动连接外接屏」的唯一声明处；
///   iOS 27 起那条路失效、改由 scene accessory 负责（见 `ExternalDisplayAccessory`）。
///   完整实测过程与对照表见 README 第八节；
/// - 原来由 `MainSceneDelegate` 干的杂活（起模拟外接屏替身、反查 windowScene）
///   收进 `PhoneSceneBridge`；
/// - **外接屏的 scene accessory 声明改到 SwiftUI 里**：`.externalDisplaySceneAccessory()`。
///
/// ## 仍然必须有 UIKit 的地方
/// iOS 17~26 的 `windowExternalDisplayNonInteractive` 只能由 plist + scene delegate 接 ——
/// SwiftUI 的 `App` / `Scene` / `WindowGroup` 只能创建 `windowApplication` role 的 scene。
/// 所以 `ExternalDisplaySceneDelegate` 与 `Info.plist` 里的 external role 声明
/// 一个都不能少；iOS 27 起这两者不再被调用，改由 SwiftUI 的 scene accessory 接管。
@main
struct ExternalDisplayDemoApp: App {

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .background {
                    // 零尺寸、不参与布局，纯粹是宿主 VC 的挂载点。
                    PhoneSceneBridge()
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
                // iOS 27 起外接屏 scene 必须靠 accessory 注册才会连上；
                // iOS 17~26 是 no-op（那条路靠 Info.plist 自动连接）。
                .externalDisplaySceneAccessory()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // 替身窗口在进后台时被拆掉，回前台要重新挂上。
                if let scene = PhoneSceneLocator.scene {
                    MockExternalDisplay.shared.bootstrap(on: scene)
                }
            case .background:
                // SwiftUI 没有 `sceneDidDisconnect` 的等价物，用进后台近似。
                // 真实项目若有必须在 scene 断开时释放的资源，这里要另行设计。
                MockExternalDisplay.shared.reset()
            default:
                break
            }
        }
    }
}
