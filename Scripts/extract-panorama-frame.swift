// 一次性离线工具：从 360 视频里抽一帧等距柱状（equirect）静帧。
//
// 用法：
//   xcrun swift Scripts/extract-panorama-frame.swift <in.mp4> <out.jpg> [秒]
//
// 为什么不用 ffmpeg：本机没装，而本工程要能"零外部依赖地重建"
// （与 fetch-panorama-assets.sh 的取向一致）。AVAssetImageGenerator 是
// Apple 原生、macOS 与 iOS 同源，抽出来的帧与将来 App 侧解码走同一套
// 色彩与方向处理 —— 这一点比 ffmpeg 更贴合本票要验的东西。
//
// 本工具**不进 App**：产物是一张 jpg，落在 .scratch/panorama-assets/ 里
// （已 gitignore；由 project.yml 作为可选 folder 资源打进 bundle）。
// 与票 05 的口径一致：实时取帧那一层不在本票范围内。

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("错误：" + message + "\n").utf8))
    exit(1)
}

private func note(_ message: String) {
    print(message)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    fail("用法：extract-panorama-frame.swift <in.mp4> <out.jpg> [秒]")
}

let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let seconds = arguments.count > 3 ? (Double(arguments[3]) ?? 0) : 0

guard FileManager.default.fileExists(atPath: input.path) else {
    fail("找不到输入视频：\(input.path)")
}

let asset = AVURLAsset(url: input)

guard let track = asset.tracks(withMediaType: .video).first else {
    fail("这条视频里没有视频轨")
}

// 显示尺寸 = 自然尺寸套上 preferredTransform。360 素材常用旋转元数据来表达
// 朝向，直接读 naturalSize 会把 1920×3840 这类倒装的当成竖幅。
let transformed = track.naturalSize.applying(track.preferredTransform)
let displaySize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
let duration = CMTimeGetSeconds(asset.duration)

note("输入   \(input.lastPathComponent)")
note("自然    \(Int(track.naturalSize.width)) × \(Int(track.naturalSize.height))")
note("显示    \(Int(displaySize.width)) × \(Int(displaySize.height))")
note("时长    \(String(format: "%.1f", duration)) s")

let aspect = displaySize.height > 0 ? displaySize.width / displaySize.height : 0
note("比例    \(String(format: "%.4f", aspect))")

// 等距柱状的**定义**就是 2:1（经度 360°、纬度 180° 等比展开）。
// 不是 2:1 就不是 equirect，贴到 EquirectProjection 上会被拉伸 ——
// 而拉伸在截图上只像"素材有点扁"，很难归因，所以这里硬拦。
if abs(aspect - 2) > 0.01 {
    fail("这条视频不是等距柱状（期望 2:1，实际 \(String(format: "%.4f", aspect))）")
}

let generator = AVAssetImageGenerator(asset: asset)
// 素材的朝向元数据要一并应用，否则抽出来的帧会横过来。
generator.appliesPreferredTrackTransform = true
// 允许的容差归零，保证抽的是**指定时刻**那一帧而不是附近的关键帧 ——
// 截图矩阵要靠"同一时刻两次抽出来逐像素一致"做基线。
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
// 不缩放：抽原分辨率。
generator.maximumSize = displaySize

let time = CMTime(seconds: min(max(seconds, 0), max(duration - 0.05, 0)), preferredTimescale: 600)

var actual = CMTime.zero
let image: CGImage
do {
    image = try generator.copyCGImage(at: time, actualTime: &actual)
} catch {
    fail("抽帧失败：\(error)")
}

note("抽帧    \(String(format: "%.3f", CMTimeGetSeconds(actual))) s → \(image.width) × \(image.height)")

let frameAspect = CGFloat(image.width) / CGFloat(image.height)
if abs(frameAspect - 2) > 0.01 {
    fail("抽出来的帧不是 2:1（\(image.width) × \(image.height)）—— 几何会拉伸")
}

try? FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

guard let destination = CGImageDestinationCreateWithURL(
    output as CFURL,
    UTType.jpeg.identifier as CFString,
    1,
    nil
) else {
    fail("建不了输出：\(output.path)")
}

CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)

guard CGImageDestinationFinalize(destination) else {
    fail("写文件失败：\(output.path)")
}

let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
let bytes = (attributes?[.size] as? Int) ?? 0
note("输出    \(output.path)（\(String(format: "%.1f", Double(bytes) / 1_048_576)) MB）")
note("✓ 产物是 2:1 等距柱状帧")
