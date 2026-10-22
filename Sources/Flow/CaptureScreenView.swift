import SwiftUI
import WebKit

struct VideoPageView: UIViewRepresentable {

    let controller: VideoPageController

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(controller, name: "page")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        controller.attach(webView)
        controller.load()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "page")
        uiView.stopLoading()
    }
}

struct CaptureScreenView: View {

    let flow: DemoFlow

    @State private var isStarting = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoPageView(controller: flow.page)
                .ignoresSafeArea()

            if flow.isCapturing {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onLongPressGesture(minimumDuration: 0.7) {
                        flow.abort()
                    }
            } else {
                startOverlay
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
    }

    private var startOverlay: some View {
        VStack {
            Spacer()

            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text("HTML 页面已在手机端就位")
                        .font(.headline)
                    Text("点开始后，屏幕内容会被 ReplayKit 原样录制")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    isStarting = true
                    Task {
                        await flow.beginCapture()
                        isStarting = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle")
                        Text(isStarting ? "正在启动…" : "开始录制")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.red.opacity(isStarting ? 0.4 : 0.92), in: Capsule())
                    .foregroundStyle(.white)
                }
                .disabled(isStarting)

                if let errorText = flow.errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                HStack {
                    Text("录制中长按屏幕任意处可中止")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Button("返回按钮页") { flow.abort() }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(22)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 420)
            .allowsHitTesting(false)
        }
    }
}
