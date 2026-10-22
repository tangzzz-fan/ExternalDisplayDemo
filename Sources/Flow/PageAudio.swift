import AVFoundation
import Foundation

/// 页面音频的进程内播放器。
///
/// WKWebView 的媒体音是 WebKit 在别的进程里渲染的，ReplayKit 的 `.audioApp`
/// 采不到它 —— 实测成片有音轨、长度对得上，但整条是 −91 dB。
///
/// 所以页面那边把 `<video>` 静音，只留画面；声音由这里用 `AVPlayer` 在 app 进程内
/// 播同一份 mp4（不挂 layer，只出声）。进程内的音频会走 app 的 `AVAudioSession`，
/// 这才在 ReplayKit 的采集范围内。
///
/// 起点由页面报上来：首帧绘制时 `requestVideoFrameCallback` 给出 `mediaTime`，
/// 按它 seek 之后再播，音画才不会差出一截。
@MainActor
final class PageAudio {

    private var player: AVPlayer?

    func start(url: URL?, from seconds: Double) {
        guard let url else { return }

        stop()

        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = false
        self.player = player

        // 起点几乎为 0 时不 seek：seek 本身要几十毫秒，反而把声音拖后。
        if seconds > 0.3 {
            player.seek(
                to: CMTime(seconds: seconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        player.play()
    }

    func stop() {
        player?.pause()
        player = nil
    }
}
