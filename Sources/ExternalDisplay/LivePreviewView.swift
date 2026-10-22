import AVFoundation
import SwiftUI

/// 外接屏上的实时画面。渲染的是录制管线里逐帧送来的 `CMSampleBuffer`，
/// 不是先落盘再读回来 —— 所以手机屏在播什么，这里同一帧就能看到。
struct LivePreviewView: UIViewRepresentable {

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        LivePreviewRelay.shared.attach(view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewContainerView, coordinator: ()) {
        LivePreviewRelay.shared.detach(uiView.displayLayer)
    }
}

final class PreviewContainerView: UIView {

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
