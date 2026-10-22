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
        statusText = "页面已打开，等待开始录制"
        isPagePresented = true
    }

    func beginCapture() async {
        guard phase == .capture, !isCapturing else { return }

        errorText = nil
        statusText = "等待页面就绪"

        guard await page.waitUntilReady() else {
            errorText = "HTML 页面没有在 6 秒内就绪"
            statusText = "页面未就绪"
            return
        }

        statusText = "正在启动录屏"

        if ScreenCapture.isSupported {
            do {
                try await capture.start()
                isSimulatedCapture = false
            } catch {
                errorText = error.localizedDescription
                statusText = "录屏启动失败"
                return
            }
        } else {
            isSimulatedCapture = true
            if let url = Self.bundledVideoURL() {
                simulated.start(url: url)
            }
        }

        isCapturing = true
        captureStartedAt = .now
        statusText = isSimulatedCapture ? "模拟录制（本机无 ReplayKit）" : "录制中"

        page.rewind()
        page.play()

        scheduleDeadlineStop()
    }

    private func scheduleDeadlineStop() {
        deadlineTask?.cancel()
        let duration = videoDuration > 0 ? videoDuration : 12
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 1.2))
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
                statusText = "页面已加载，等待开始录制"
            }
        case .metadata(let duration, _):
            videoDuration = duration
        case .playing:
            if isCapturing {
                statusText = isSimulatedCapture ? "模拟录制（本机无 ReplayKit）" : "录制中"
            }
        case .started(let mediaTime):
            guard phase == .capture, isCapturing else { return }
            pageAudio.start(url: Self.bundledVideoURL(), from: mediaTime)
        case .ended:
            guard phase == .capture, isCapturing else { return }
            finishTask = Task { await finishCapture() }
        case .failed(let message):
            errorText = message
            statusText = "页面出错"
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
