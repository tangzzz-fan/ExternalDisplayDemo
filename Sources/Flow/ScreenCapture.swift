import AVFoundation
import Foundation
import ReplayKit

@MainActor
final class ScreenCapture {

    enum Failure: LocalizedError {
        case unavailable
        case notRunning
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: "当前设备不支持 ReplayKit 录屏"
            case .notRunning: "没有正在进行的录制"
            case .startFailed(let message): "录屏启动失败：\(message)"
            }
        }
    }

    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return RPScreenRecorder.shared().isAvailable
        #endif
    }

    /// 系统首次弹出「允许屏幕捕捉」确认框时，等用户点完可能远超十秒。
    private static let startTimeout: TimeInterval = 30

    private var writer: RecordingWriter?

    private(set) var isRunning = false

    func start() async throws {
        guard Self.isSupported else { throw Failure.unavailable }
        guard !isRunning else { return }

        try activateAudioSession()

        let writer = RecordingWriter(url: Self.makeOutputURL())
        let recorder = RPScreenRecorder.shared()
        recorder.isMicrophoneEnabled = false

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let result = StartResult(continuation: continuation, writer: writer)

                DispatchQueue.main.asyncAfter(deadline: .now() + Self.startTimeout) {
                    guard result.finish(.failure(Failure.startFailed("启动超时，未收到系统回调"))) else { return }
                    recorder.stopCapture { _ in }
                }

                recorder.startCapture { sampleBuffer, type, error in
                    if let error {
                        #if DEBUG
                        print("[Capture] sample error: \(error.localizedDescription)")
                        #endif
                        return
                    }
                    writer.append(sampleBuffer, type: type)
                    if type == .video {
                        LivePreviewRelay.shared.submit(sampleBuffer)
                    }
                } completionHandler: { error in
                    let outcome: Result<Void, Error> = error.map {
                        .failure(Failure.startFailed($0.localizedDescription))
                    } ?? .success(())

                    // 已经超时判过失败了：这次迟到的成功要把录制收回去，否则会留下一个
                    // 没人接管的采样流。
                    if !result.finish(outcome) {
                        recorder.stopCapture { _ in }
                    }
                }
            }
        } catch {
            deactivateAudioSession()
            throw error
        }

        self.writer = writer
        isRunning = true

        // ReplayKit 起采集时会重配音频会话，把 app 先前的 .playback 顶掉。
        // 之后 WKWebView 的媒体音会落到 ambient 上（手机一开静音就彻底没声），
        // 而 .audioApp 送来的采样全是 0 —— 成片有音轨但整条静音。
        // 采集已经起来了，这里再把会话要回来。
        try? activateAudioSession()
    }

    func stop() async throws -> URL {
        guard let writer, isRunning else { throw Failure.notRunning }

        isRunning = false
        self.writer = nil

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RPScreenRecorder.shared().stopCapture { _ in continuation.resume() }
        }

        defer { deactivateAudioSession() }
        return try await writer.finish()
    }

    func cancel() {
        guard isRunning else { return }
        isRunning = false
        writer?.cancel()
        writer = nil
        RPScreenRecorder.shared().stopCapture { _ in }
        deactivateAudioSession()
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback, options: [])
        try session.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private static func makeOutputURL() -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directory.appendingPathComponent("recording-\(formatter.string(from: Date())).mp4")
    }
}

private final class FrameTally: @unchecked Sendable {

    private let lock = NSLock()
    private var count = 0

    func tick() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class StartResult: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private let writer: RecordingWriter

    init(continuation: CheckedContinuation<Void, Error>, writer: RecordingWriter) {
        self.continuation = continuation
        self.writer = writer
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()

        guard let pending else { return false }

        if case .failure = result {
            writer.cancel()
        }
        pending.resume(with: result)
        return true
    }
}
