import AVFoundation
import SwiftUI

struct RecordedVideoView: UIViewRepresentable {

    let url: URL

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.load(url: url)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.load(url: url)
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: ()) {
        uiView.unload()
    }
}

final class PlayerContainerView: UIView {

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var loadedURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        // fill：录进来的帧比例未必等于眼镜屏（手机屏 2.17 : 1，眼镜屏 1.78 : 1），
        // 这里按"铺满、超出裁掉"处理，不留黑边。要改回保比例就换 `.resizeAspect`。
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = UIColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    func load(url: URL) {
        guard url != loadedURL else { return }
        loadedURL = url

        unload()

        let player = AVQueuePlayer()
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))

        playerLayer.player = player
        self.player = player
        self.looper = looper

        player.play()
    }

    func unload() {
        player?.pause()
        looper?.disableLooping()
        playerLayer.player = nil
        player = nil
        looper = nil
    }
}
