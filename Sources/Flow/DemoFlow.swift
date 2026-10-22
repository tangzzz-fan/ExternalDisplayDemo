import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class DemoFlow {

    static let shared = DemoFlow()

    enum Phase: Equatable {
        case launcher
        case capture
        case playback
    }

    private(set) var phase: Phase = .launcher
    private(set) var isCapturing = false
    private(set) var isSimulatedCapture = false
    private(set) var captureStartedAt: Date?
    private(set) var recordedURL: URL?
    private(set) var recordedDuration: Double = 0
    private(set) var videoDuration: Double = 0
    private(set) var statusText = "把光标移到按钮上，轻点手机屏幕"
    private(set) var errorText: String?

    var isPagePresented = false

    let page = VideoPageController()

    @ObservationIgnored private let capture = ScreenCapture()
    @ObservationIgnored private let simulated = SimulatedCapture()
    @ObservationIgnored private let pageAudio = PageAudio()
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?

    private init() {
        page.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    func activate(at pointer: CGPoint?) {
        guard phase == .launcher else { return }

        guard GlassesLauncherLayout.standard.hitTest(pointer) else {
            statusText = pointer == nil ? "先移动光标到按钮上" : "光标不在按钮上"
            return
        }

        errorText = nil
        phase = .capture
        statusText = "页面已打开，点视频上的播放键"
        isPagePresented = true
    }

    func beginCapture() async {
        guard phase == .capture, !isCapturing else { return }

        errorText = nil
        statusText = "等待页面就绪"

        guard await page.waitUntilReady() else {
            failCapture("HTML 页面没有在 6 秒内就绪")
            return
        }

        statusText = "正在启动录屏"

        if ScreenCapture.isSupported {
            do {
                try await capture.start()
                isSimulatedCapture = false
            } catch {
                failCapture(error.localizedDescription)
                return
            }
        } else {
            isSimulatedCapture = true
            if let url = Self.bundledVideoURL() {
                simulated.start(url: url)
            }
        }

        // 启动期间用户可能按了「返回按钮页」。那时 `isCapturing` 还是 false，
        // `abort()` 不会去收采样流 —— 这里补上，否则会留下一个没人接管的录制。
        guard phase == .capture else {
            capture.cancel()
            simulated.stop()
            return
        }

        isCapturing = true
        captureStartedAt = .now
        statusText = isSimulatedCapture ? "模拟录制（本机无 ReplayKit）" : "录制中"

        page.beginPlayback()

        scheduleDeadlineStop()
    }

    /// 启动失败：页面按钮要还回去，手机状态栏与错误条共用同一句话。
    private func failCapture(_ message: String) {
        errorText = message
        statusText = "录屏启动失败"
        page.fail(message)
    }

    /// 页面还没报出素材时长时的兜底上限。
    ///
    /// 只兜「`loadedmetadata` 永远不来」这种病态情况，所以取一个明显长于素材的值；
    /// 用它当正常时长会把 20 秒的片子截在 12 秒（旧值就是 12）。
    private static let unknownDurationLimit: Double = 60

    private func scheduleDeadlineStop() {
        deadlineTask?.cancel()
        let limit = videoDuration > 0 ? videoDuration + 1.2 : Self.unknownDurationLimit
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            await self?.finishCapture()
        }
    }

    func abort() {
        finishTask?.cancel()
        finishTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        simulated.stop()
        pageAudio.stop()

        if isCapturing, !isSimulatedCapture {
            capture.cancel()
        }

        isCapturing = false
        isSimulatedCapture = false
        captureStartedAt = nil
        page.reset()

        isPagePresented = false
        phase = .launcher
        statusText = "已中止，回到按钮页"
    }

    func restart() {
        guard phase == .playback else { return }
        recordedURL = nil
        recordedDuration = 0
        phase = .launcher
        statusText = "把光标移到按钮上，轻点手机屏幕"
    }

    static func secondsText(_ seconds: Double) -> String {
        String(format: "%.1f 秒", seconds)
    }

    private static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration)
        return duration?.seconds ?? 0
    }

    private func finishCapture() async {
        guard phase == .capture, isCapturing else { return }

        deadlineTask?.cancel()
        deadlineTask = nil
        simulated.stop()
        pageAudio.stop()
        isCapturing = false
        statusText = "正在生成录制文件"

        do {
            let url = isSimulatedCapture ? try Self.stageBundledVideo() : try await capture.stop()
            let duration = await Self.duration(of: url)
            recordedURL = url
            recordedDuration = duration
            errorText = nil
            phase = .playback
            statusText = "录制完成 \(Self.secondsText(duration))，已在眼镜屏播放"
        } catch {
            recordedURL = nil
            recordedDuration = 0
            errorText = error.localizedDescription
            phase = .launcher
            statusText = "录制失败"
        }

        isSimulatedCapture = false
        captureStartedAt = nil
        page.reset()
        isPagePresented = false
    }

    private func handle(_ event: VideoPageController.Event) {
        switch event {
        case .ready:
            if phase == .capture, !isCapturing {
                statusText = "页面已加载，点播放键开始录制"
            }
        case .metadata(let duration, _):
            videoDuration = duration
            // 时长到位后重排收工时间：开录时若还没拿到时长，deadline 是按兜底值排的。
            if phase == .capture, isCapturing {
                scheduleDeadlineStop()
            }
        case .playing:
            if isCapturing {
                statusText = isSimulatedCapture ? "模拟录制（本机无 ReplayKit）" : "录制中"
            }
        case .started(let mediaTime):
            guard phase == .capture, isCapturing else { return }
            #if DEBUG
            print(String(format: "[Flow] started mediaTime=%.3f", mediaTime))
            #endif
            pageAudio.start(url: Self.bundledVideoURL(), from: mediaTime)
        case .ended:
            guard phase == .capture, isCapturing else { return }
            finishTask = Task { await finishCapture() }
        case .playRequested:
            // 站点上的播放键 = 这次演示的入口。录屏授权由 `capture.start()` 触发。
            guard phase == .capture, !isCapturing else { return }
            Task { await beginCapture() }
        case .failed(let message):
            errorText = message
            statusText = "页面出错"
            page.fail(message)
        }
    }

    private static func bundledVideoURL() -> URL? {
        Bundle.main.url(forResource: "video", withExtension: "mp4", subdirectory: "VideoPage")
    }

    private static func stageBundledVideo() throws -> URL {
        guard let source = bundledVideoURL() else {
            throw RecordingWriter.Failure.noVideoSample
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("simulated-recording.mp4")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
