import UIKit

/// 仅用于承载 scene 生命周期。
///
/// 所有 scene 配置（手机屏 / 外接屏）都已在 `Support/Info.plist` 的
/// `UIApplicationSceneManifest` 中声明，因此这里**不需要**实现
/// `application(_:configurationForConnecting:options:)`。
///
/// 若改为代码方式动态提供配置，记得仍然要在 Info.plist 里保留
/// `UIApplicationSupportsMultipleScenes = YES` 与 external display role 的声明，
/// 否则系统根本不会把外接屏事件交付给应用。
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {}
