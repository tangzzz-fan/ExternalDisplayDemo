import AVFoundation
import Foundation
import ReplayKit

final class RecordingWriter: @unchecked Sendable {

    enum Failure: LocalizedError {
        case noVideoSample
        case writerUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .noVideoSample: "没有收到任何画面，录制未产生文件"
            case .writerUnavailable(let message): "写入失败：\(message)"
            }
        }
    }

    let url: URL

    private let queue = DispatchQueue(label: "com.jove.externaldisplaydemo.recording-writer")

    private var pending: [(buffer: CMSampleBuffer, type: RPSampleBufferType)] = []
    private var videoQueue: [CMSampleBuffer] = []
    private var audioQueue: [CMSampleBuffer] = []
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStart: CMTime?
    private var decisionScheduled = false
    private var isClosed = false
    private var failure: Error?

    init(url: URL) {
        self.url = url
        try? FileManager.default.removeItem(at: url)
    }

    func append(_ buffer: CMSampleBuffer, type: RPSampleBufferType) {
        queue.async { [self] in
            guard !isClosed, failure == nil else { return }

            if writer == nil {
                pending.append((buffer, type))
                if pending.count > 240 { pending.removeFirst() }
                scheduleDecision()
                return
            }

            write(buffer, type: type)
        }
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if writer == nil {
                    decide()
                }
                isClosed = true

                if let failure {
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(throwing: failure)
                    return
                }

                guard let writer, writer.status == .writing || writer.status == .completed else {
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(throwing: Failure.noVideoSample)
                    return
                }

                drainUntilEmpty()

                videoInput?.markAsFinished()
                audioInput?.markAsFinished()

                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume(returning: self.url)
                    } else {
                        try? FileManager.default.removeItem(at: self.url)
                        continuation.resume(
                            throwing: Failure.writerUnavailable(
                                writer.error?.localizedDescription ?? "status \(writer.status.rawValue)"
                            )
                        )
                    }
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            isClosed = true
            writer?.cancelWriting()
            writer = nil
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func scheduleDecision() {
        guard !decisionScheduled else { return }
        guard pending.contains(where: { $0.type == .video }) else { return }

        decisionScheduled = true
        decide()
    }

    private func decide() {
        guard writer == nil, !isClosed, failure == nil else { return }
        guard let videoIndex = pending.firstIndex(where: { $0.type == .video }) else { return }

        let videoBuffer = pending[videoIndex].buffer
        guard let format = CMSampleBufferGetFormatDescription(videoBuffer) else {
            failure = Failure.noVideoSample
            return
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width > 0, dimensions.height > 0 else {
            failure = Failure.noVideoSample
            return
        }

        do {
            try makeWriter(width: Int(dimensions.width), height: Int(dimensions.height))
        } catch {
            failure = error
            return
        }

        let startTime = CMSampleBufferGetPresentationTimeStamp(videoBuffer)
        sessionStart = startTime
        writer?.startSession(atSourceTime: startTime)

        let buffered = pending
        pending.removeAll()
        for item in buffered {
            write(item.buffer, type: item.type)
        }
    }

    private func makeWriter(width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, width * height * 4),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoExpectedSourceFrameRateKey: 60
            ]
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw Failure.writerUnavailable("无法添加视频轨道")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ])
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) {
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw Failure.writerUnavailable(writer.error?.localizedDescription ?? "startWriting 被拒绝")
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
    }

    private func write(_ buffer: CMSampleBuffer, type: RPSampleBufferType) {
        guard let sessionStart else { return }
        guard CMSampleBufferGetPresentationTimeStamp(buffer) >= sessionStart else { return }

        switch type {
        case .video:
            videoQueue.append(buffer)
        case .audioApp, .audioMic:
            guard audioInput != nil else { return }
            audioQueue.append(buffer)
        @unknown default:
            return
        }

        drain()
    }

    private func drain() {
        if let videoInput {
            while videoInput.isReadyForMoreMediaData, !videoQueue.isEmpty {
                if !videoInput.append(videoQueue.removeFirst()) {
                    failure = Failure.writerUnavailable(
                        writer?.error?.localizedDescription ?? "视频帧写入被拒绝"
                    )
                    return
                }
            }
        }

        if let audioInput {
            while audioInput.isReadyForMoreMediaData, !audioQueue.isEmpty {
                if !audioInput.append(audioQueue.removeFirst()) {
                    failure = Failure.writerUnavailable(
                        writer?.error?.localizedDescription ?? "音频帧写入被拒绝"
                    )
                    return
                }
            }
        }
    }

    private func drainUntilEmpty() {
        let deadline = Date().addingTimeInterval(5)

        while !videoQueue.isEmpty || !audioQueue.isEmpty {
            drain()
            if failure != nil { return }
            guard Date() < deadline else { return }
            usleep(2_000)
        }
    }
}
