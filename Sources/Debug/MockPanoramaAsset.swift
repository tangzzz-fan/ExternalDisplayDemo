import Foundation

/// 调试用：`-panoramaAsset=grid|real|frame|animated` —— 全景页用哪一套帧源。
///
/// ## 为什么没并进 `-remoteState`
/// 那边写的是 `RemoteControl` 的状态（"怎么看"）；这个是渲染侧的一次性内容选择
/// （"看什么"）。按 `README` 第三节那张职责表，它该跟 `DisplayContentStore` 走 ——
/// 而它是启动期常量、不进通信链路，所以单独一个标志就够了，
/// 不必为它给共享状态加一个属性。
///
/// 与 `MockRemoteState` / `MockAirMouseSource` 同一约定：只在带启动参数时生效，
/// 不参与真机链路。**它伪造的是来源，不是度量**。
///
/// ## 用法
/// ```
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay \
///     -remoteState pano=8 -panoramaAsset=real
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay \
///     -remoteState pano=8 -panoramaAsset=frame
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay \
///     -remoteState pano=8,phase=0.25 -panoramaAsset=animated
/// ```
///
/// 默认 `grid`：程序化经纬网与几何逐点对应，是截图判读的主判据。
/// 素材缺失时（没跑过 `Scripts/fetch-panorama-assets.sh` / `extract-panorama-frame.swift`）
/// `real` 与 `frame` 档会静默回落网格 —— 那是设计好的退路，不是错误。
///
/// 四档各自验什么见 `PanoramaAssetSource` 的说明；`animated` 要配 `phase=`
/// 才截得出可复现的一帧（见 `MockRemoteState`）。
enum MockPanoramaAsset {

    static var source: PanoramaAssetSource {
        guard let raw = rawValue, let parsed = PanoramaAssetSource(rawValue: raw) else { return .grid }
        return parsed
    }

    static var rawValue: String? {
        let flag = "-panoramaAsset"
        let arguments = ProcessInfo.processInfo.arguments

        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix(flag + "=") {
                return String(argument.dropFirst(flag.count + 1))
            } else if argument == flag, index + 1 < arguments.count {
                return arguments[index + 1]
            }
        }
        return nil
    }
}
