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

    /// 停止采集的兜底等待。
    ///
    /// 正常几十毫秒就回调；但不回调时不能把界面卡死在「正在生成录制文件」——
    /// 已经交给 writer 的采样照样能收尾成文件。
    private static let stopTimeout: TimeInterval = 5

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
                let gate = OnceGate { continuation.resume(with: $0) }

                DispatchQueue.main.asyncAfter(deadline: .now() + Self.startTimeout) {
                    guard gate.finish(.failure(Failure.startFailed("启动超时，未收到系统回调"))) else { return }
                    writer.cancel()
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
                    guard gate.finish(outcome) else {
                        recorder.stopCapture { _ in }
                        return
                    }
                    if case .failure = outcome { writer.cancel() }
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
        do {
            try activateAudioSession()
        } catch {
            #if DEBUG
            print("[Capture] 采集启动后没能恢复 .playback 会话：\(error.localizedDescription)")
            #endif
        }
    }

    func stop() async throws -> URL {
        guard let writer, isRunning else { throw Failure.notRunning }

        isRunning = false
        self.writer = nil

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = OnceGate { _ in continuation.resume() }

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopTimeout) {
                guard gate.finish(.success(())) else { return }
                #if DEBUG
                print("[Capture] stopCapture 超过 \(Self.stopTimeout) 秒未回调，按已到的采样收尾")
                #endif
            }

            RPScreenRecorder.shared().stopCapture { _ in gate.finish(.success(())) }
        }

        defer { deactivateAudioSession() }
        return try await writer.finish()
    }

    func cancel() {
        // 不拿 `isRunning` 当门：`beginCapture()` 在启动成功后仍可能立刻把这次录制
        // 收回（启动期间用户点了「返回按钮页」），那时 `isRunning` 已经是 true，
        // 而重复调解一次 `stopCapture` 本身是无害的。
        writer?.cancel()
        writer = nil
        isRunning = false
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

/// 一次性闸门：谁先到谁放行，后到的静默失败。
///
/// ReplayKit 的启动/停止各有一个「系统回调」和一个「本地超时」，两边都可能先到，
/// 而 `CheckedContinuation` 只许 resume 一次 —— 这个类型就是那条判据。
private final class OnceGate: @unchecked Sendable {

    private let lock = NSLock()
    private var resume: ((Result<Void, Error>) -> Void)?

    init(_ resume: @escaping (Result<Void, Error>) -> Void) {
        self.resume = resume
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        let pending = resume
        resume = nil
        lock.unlock()

        guard let pending else { return false }
        pending(result)
        return true
    }
}
