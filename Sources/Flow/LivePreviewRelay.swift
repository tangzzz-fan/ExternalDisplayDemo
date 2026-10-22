import AVFoundation
import CoreMedia
import Foundation

/// 把录制中的画面实时送到外接屏。
///
/// ReplayKit 的视频回调在它自己的线程上，`AVSampleBufferDisplayLayer` 又要挂在
/// 外接屏那一层的 UI 上，两者之间就靠这个中继对接：
///
/// ```
/// ReplayKit ──video buffer──▶ LivePreviewRelay ──copy──▶ 主队列 ──▶ display layer
///                                    │
///                                    └──▶ RecordingWriter（原 buffer，不经过这里）
/// ```
///
/// 之所以要给外接屏单独做一份 copy：显示层要求把 `DisplayImmediately` 写进
/// sample attachment 才能不等时基、来一帧画一帧，而同一份 buffer 还要交给
/// `AVAssetWriterInput`。copy 只复制外层包装、共享同一个 `CVImageBuffer`，
/// 逐帧开销可以忽略，却把两条下游彻底隔开。
final class LivePreviewRelay: @unchecked Sendable {

    static let shared = LivePreviewRelay()

    private let lock = NSLock()
    private weak var layer: AVSampleBufferDisplayLayer?
    private var inFlight = 0

    /// 主线程卡顿时最多积压三帧，再多就丢掉旧的 —— 实时预览宁可丢帧也不能延迟。
    private let maxInFlight = 3

    private init() {}

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        self.layer = layer
        inFlight = 0
        lock.unlock()

        layer.flush()
    }

    func detach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        if self.layer === layer {
            self.layer = nil
        }
        lock.unlock()
    }

    func submit(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let accepted = inFlight < maxInFlight
        if accepted { inFlight += 1 }
        lock.unlock()

        guard accepted else { return }

        guard let preview = Self.makePreviewBuffer(from: sampleBuffer) else {
            releaseSlot()
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.lock.lock()
            let target = self.layer
            self.inFlight = max(0, self.inFlight - 1)
            self.lock.unlock()

            guard let target else { return }
            Self.enqueue(preview, to: target)
        }
    }

    private func releaseSlot() {
        lock.lock()
        inFlight = max(0, inFlight - 1)
        lock.unlock()
    }

    private static func enqueue(_ buffer: CMSampleBuffer, to layer: AVSampleBufferDisplayLayer) {
        if layer.status == .failed || layer.requiresFlushToResumeDecoding {
            layer.flush()
        }
        layer.enqueue(buffer)
    }

    /// 复制一层包装、共享像素缓冲，并打上"立即显示"标记。
    private static func makePreviewBuffer(from sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        )
        if !timing.duration.isNumeric || timing.duration <= .zero {
            timing.duration = CMTime(value: 1, timescale: 60)
        }

        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &copy
        )
        guard status == noErr, let copy else { return nil }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return copy }

        let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            entry,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )

        return copy
    }
}
