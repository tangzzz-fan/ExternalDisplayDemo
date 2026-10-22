import AVFoundation
import Foundation
import Observation
import UIKit

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

    /// 录制期间锁死的方向；`nil` 表示不限制。
    ///
    /// 不是为了体验，是硬约束：`RecordingWriter` 拿**第一帧**的尺寸建 `AVAssetWriter`，
    /// 之后每一帧都必须同尺寸。录制中途转屏会让 ReplayKit 送来的画面宽高互换，
    /// 后续 `append` 直接失败 —— 整段录制作废，而报错只有"视频帧写入被拒绝"一句。
    private(set) var lockedOrientationMask: UIInterfaceOrientationMask?

    let page = VideoPageController()

    @ObservationIgnored private let capture = ScreenCapture()
    @ObservationIgnored private let simulated = SimulatedCapture()
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

        // 页面是远程站点，加载比本地 HTML 慢得多，别用 6 秒那个默认值。
        guard await page.waitUntilReady(timeout: .seconds(15)) else {
            failCapture("页面 15 秒内没有加载完")
            return
        }

        // 「点播放 = 切全屏」的落点：竖屏加载页面，用户一按站点的播放键，
        // 这里就转横屏、接着把页面切成全屏。两步都必须排在 `capture.start()` 之前：
        // 转屏是因为 ReplayKit 的缓冲尺寸在启动那一刻定死；全屏是因为录屏授权弹窗
        // 可能要等好几秒，那几秒里若还是竖屏的站点页，会被原样录进成片开头。
        statusText = "正在切换到全屏"
        let turned = await rotateToLandscape()
        lockedOrientationMask = turned ? .landscape : .portrait
        page.beginPresentation()

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

        scheduleDeadlineStop()
    }

    /// 启动失败：页面要从全屏退回站点页，手机状态栏与错误条共用同一句话。
    private func failCapture(_ message: String) {
        errorText = message
        statusText = "录屏启动失败"
        page.endPresentation()
    }

    /// 页面还没报出素材时长时的兜底上限。
    ///
    /// 只兜「`loadedmetadata` 永远不来」这种病态情况，所以取一个明显长于素材的值；
    /// 用它当正常时长会把 20 秒的片子截在 12 秒（旧值就是 12）。
    private static let unknownDurationLimit: Double = 60

    /// 单次录制的硬上限。
    ///
    /// 本地素材 20 秒，靠 `ended` 收工没有问题；换成远程站点之后视频可能是几十分钟 ——
    /// 一次点击就录到存储写满、界面也回不来。这里按时长和上限取小，到点就收尾。
    private static let maxCaptureLength: Double = 30

    private func scheduleDeadlineStop() {
        deadlineTask?.cancel()
        let byContent = videoDuration > 0 ? videoDuration + 1.2 : Self.unknownDurationLimit
        let limit = min(byContent, Self.maxCaptureLength)
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
        if isCapturing, !isSimulatedCapture {
            capture.cancel()
        }

        isCapturing = false
        isSimulatedCapture = false
        captureStartedAt = nil
        unlockOrientation()
        page.reset()

        isPagePresented = false
        phase = .launcher
        statusText = "已中止，回到按钮页"
    }

    func restart() {
        guard phase == .playback else { return }
        unlockOrientation()
        recordedURL = nil
        recordedDuration = 0
        phase = .launcher
        statusText = "把光标移到按钮上，轻点手机屏幕"
    }

    /// 把界面转到横屏，并且**等到真的转完**才返回。
    ///
    /// `requestGeometryUpdate` 在真机上会偶发被静默丢弃 —— 既不转、`errorHandler`
    /// 也不回调（旧记录里探针确认过 mask 与 supported 全对，仍然不转）。
    /// 所以不能"发完就等"，只能轮询窗口方向确认，且失败一次要重试。
    ///
    /// 两轮都没成也照样返回 false：卡在这里转不出去，比录成竖的更糟。
    /// 此时调用方按竖屏继续，至于"为什么没转"留给控制台。
    @discardableResult
    private func rotateToLandscape() async -> Bool {
        guard let scene = UIWindowScene.main else { return false }
        if scene.interfaceOrientation.isLandscape { return true }

        for _ in 0..<2 {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                #if DEBUG
                print("[Flow] requestGeometryUpdate 被拒: \(error.localizedDescription)")
                #endif
            }

            if await waitUntilLandscape(scene) { return true }
        }

        #if DEBUG
        print("[Flow] 两轮都没转到横屏，按竖屏继续录制")
        #endif
        return false
    }

    private func waitUntilLandscape(_ scene: UIWindowScene) async -> Bool {
        for _ in 0..<18 {
            if scene.interfaceOrientation.isLandscape { return true }
            try? await Task.sleep(for: .milliseconds(70))
        }
        return scene.interfaceOrientation.isLandscape
    }

    private func unlockOrientation() {
        lockedOrientationMask = nil
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
        unlockOrientation()
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
            // 这里**刻意不出声**：站点音轨由 WebKit 在别的进程渲染，ReplayKit 采不到；
            // 而本地那份 `video.mp4` 与远程素材不是同一个东西，播它只会音画全错。
            // 宁可静音，不要错位。见 docs/tech-debt.md TD-001。
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
            page.endPresentation()
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
