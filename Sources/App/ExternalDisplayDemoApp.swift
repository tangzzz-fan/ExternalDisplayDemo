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
/// - 原来由 `MainSceneDelegate` 干的杂活（起模拟外接屏替身）不需要宿主 VC 了：
///   替身自己从 `UIApplication` 查主屏 scene，外接屏的 scene accessory 也改到
///   SwiftUI 里声明（`.externalDisplaySceneAccessory()`）。
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
                // iOS 27 起外接屏 scene 必须靠 accessory 注册才会连上；
                // iOS 17~26 是 no-op（那条路靠 Info.plist 自动连接）。
                .externalDisplaySceneAccessory()
                .onAppear {
                    // 首次挂载就走一次，不依赖 scenePhase 的初始跳变。
                    MockExternalDisplay.shared.bootstrap()

                    // 与 `-mockExternalDisplay` 同一约定：带了 mock 参数就直接进入该模式，
                    // 否则这个参数要用户手动点开遥控台 → 切到空鼠 → 点启动才生效。
                    if MockAirMouseSource.isEnabled {
                        AirMouse.shared.start()
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // 替身窗口在进后台时被拆掉，回前台要重新挂上。
                MockExternalDisplay.shared.bootstrap()
            case .background:
                // SwiftUI 没有 `sceneDidDisconnect` 的等价物，用进后台近似。
                // 真实项目若有必须在 scene 断开时释放的资源，这里要另行设计。
                MockExternalDisplay.shared.reset()

                // 空鼠必须在这里停：CoreMotion 的数据流在后台会继续跑并持续耗电，
                // 而"瞄准"这件事只在应用可见时才有意义 —— 没人看着的屏幕不需要指针。
                AirMouse.shared.stop()
            default:
                break
            }
        }
    }
}
