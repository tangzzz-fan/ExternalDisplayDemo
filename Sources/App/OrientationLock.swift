import UIKit

/// 录制期间把界面的可用方向钉住。
///
/// SwiftUI 的 `App` 没有"支持哪些方向"的声明口 —— `Info.plist` 只能写死一组，
/// 想按状态变化就必须回到 `UIApplicationDelegate`。
///
/// 为什么非要锁：`RecordingWriter` 按**第一帧**的尺寸建 `AVAssetWriter`，
/// 之后每一帧都要求同尺寸。录制中途转屏时 ReplayKit 送来的画面宽高互换，
/// `append` 会直接失败，整段录制作废，报错只有一句"视频帧写入被拒绝"。
///
/// 不录制时返回 `.allButUpsideDown` —— iPhone 上的倒竖屏系统本来也不会给。
final class OrientationLock: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        DemoFlow.shared.lockedOrientationMask ?? .allButUpsideDown
    }
}
