import UIKit
import SwiftUI

/// 手机端主界面。
///
/// 直接继承 `UIHostingController` 而不是用容器 VC + 子 VC：
/// 后者需要手工处理子视图铺满与安全区，而外部屏接入这件事和布局无关，
/// 没必要把风险引进来。
///
/// 单独包这一层的目的只有一个 —— 提供一个明确的宿主来注册 **scene accessory**：
/// iOS 27 起，`windowExternalDisplayNonInteractive` 的 scene 不再由系统自动连接，
/// 应用必须先在一个「主界面里的 view controller」上调用 `registerSceneAccessory(_:)`，
/// 系统才会在外接屏可用时建立该 scene。
///
/// 注册语义是「随宿主 view controller 的呈现状态生效」：
/// 宿主在屏幕上、`registration.isEnabled` 为 true、且有可用外接屏时，系统才连接 scene。
final class PhoneRootViewController: UIHostingController<PhoneRootView> {

    /// iOS 27+ 的 `UISceneAccessoryRegistration` 句柄。
    ///
    /// 用 `Any?` 承接是因为该类型标注了 `API_AVAILABLE(ios(27.0))`，
    /// 而本 target 的 deployment target 是 17.0，直接写类型名会要求
    /// 整个属性做可用性标注。句柄**必须强引用住**，否则注册会立刻失效。
    private var sceneAccessoryRegistration: Any?

    init() {
        super.init(rootView: PhoneRootView())
    }

    @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        if #available(iOS 27.0, *) {
            registerExternalDisplayAccessory()
        }
    }

    // MARK: - Scene accessory（iOS 27+）

    @available(iOS 27.0, *)
    private func registerExternalDisplayAccessory() {
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

    // 本 demo 里这是常驻的根 view controller，不需要主动 unregister。
    // 若外接屏内容只在某个子页面提供，应在该页面退出时调用
    // `unregisterSceneAccessory(_:)`，系统会同步断开对应 scene。
}
