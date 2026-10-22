import AVFoundation
import Foundation
import QuartzCore

/// 模拟器上的替身录制源。
///
/// 模拟器里 ReplayKit 报 `isAvailable == true` 但回调永远不来，实时预览就没法验证。
/// 这里用 `AVAssetReader` 按真实时间节拍把同一段视频逐帧解码出来，走的是**和真机
/// 完全一样**的下游：`CMSampleBuffer` → `LivePreviewRelay` → 显示层。
///
/// 它只负责喂预览，不参与录制文件 —— 录制结果仍由 `DemoFlow` 复制原始 mp4，
/// 这样模拟录制出来的片子带声音，演示流程不会因为替身而缺一条音轨。
@MainActor
final class SimulatedCapture {

    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    func start(url: URL) {
        guard task == nil else { return }
        task = Task.detached(priority: .userInitiated) {
            await Self.pump(url: url)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func pump(url: URL) async {
        let asset = AVURLAsset(url: url)

        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else { return }
        reader.add(output)
        guard reader.startReading() else { return }

        let origin = CACurrentMediaTime()

        while !Task.isCancelled, let buffer = output.copyNextSampleBuffer() {
            let target = origin + CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            let wait = target - CACurrentMediaTime()
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            LivePreviewRelay.shared.submit(buffer)
        }

        reader.cancelReading()
    }
}
