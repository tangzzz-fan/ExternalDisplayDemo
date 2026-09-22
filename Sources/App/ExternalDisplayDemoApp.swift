import SwiftUI

/// 纯 SwiftUI 生命周期的入口。
///
/// 取代原来的 `AppDelegate` + `MainSceneDelegate` + `PhoneRootViewController` 三层：
///
/// - `@main` 从 `AppDelegate` 挪到这里；
/// - 主屏 scene 交给 `WindowGroup`，SwiftUI 自己装 scene delegate。
///   但 `Support/Info.plist` 里**仍然必须为 `UIWindowSceneSessionRoleApplication`
///   留一个条目，且不能带 `UISceneDelegateClassName`**：
///   `UISceneConfigurations` 字典一旦存在，缺了 application role 条目就会让 app
///   scene 连不上 —— 表现是黑屏（启动屏不被替换）且**零日志**，极难排查；
///   而带上 delegate class 又会与 SwiftUI 自己的 scene delegate 冲突。
///   注意这个坑只在 `UISceneConfigurations` 存在时才触发：如果整个字典都不要，
///   SwiftUI 反而正常，代价是 iOS 17~26 的 plist 自动连接外接屏那条路也没了；
/// - 原来由 `MainSceneDelegate` 干的杂活（反查 windowScene、起模拟外接屏替身、
///   注册 scene accessory）全部收进 `PhoneSceneBridge`。
///
/// ## 仍然必须有 UIKit 的地方
/// SwiftUI 接管不了 `windowExternalDisplayNonInteractive` —— `App` / `Scene` /
/// `WindowGroup` 只能创建 `windowApplication` role 的 scene。
/// 所以 `ExternalDisplaySceneDelegate` 与 `Info.plist` 里的 external role 声明
/// **一个都不能少**，「纯 SwiftUI」到手机端为止。
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
