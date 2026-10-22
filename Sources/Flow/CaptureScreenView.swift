import SwiftUI
import WebKit

struct VideoPageView: UIViewRepresentable {

    let controller: VideoPageController

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(controller, name: "page")
        // 远程页面没有原生钩子，事件与全屏都靠这份注入脚本。
        // 所有 frame 都注入：站点把播放器放进 iframe 时主 frame 那份抓不到 `<video>`。
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: VideoPageController.bridgeScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = controller
        webView.isOpaque = false
        webView.backgroundColor = .black
        // 页面本身要能滚（站点正文），全屏播放时由注入样式关掉 overflow。
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        controller.attach(webView)
        controller.load()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "page")
        uiView.stopLoading()
    }
}

/// 手机端的全屏站点页。
///
/// 这里**没有**「开始录制」按钮：入口在页面上那个播放键（一个真的播放键，
/// 不是一个伪装成播放键的原生按钮）。点击 → `playrequest` → `DemoFlow.beginCapture()`
/// → 系统录屏授权 → 采集就绪 → 页面收起站点进全屏播放。
///
/// 反过来（先播再申请）会丢掉开头几百毫秒，而录屏那一侧的东西就在那几百毫秒里。
struct CaptureScreenView: View {

    let flow: DemoFlow

    var body: some View {
        ZStack(alignment: .top) {
            VideoPageView(controller: flow.page)
                .ignoresSafeArea()

            // 录制中：整屏接管成长按中止。播放前不能盖，否则播放键点不到。
            if flow.isCapturing {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onLongPressGesture(minimumDuration: 0.7) {
                        flow.abort()
                    }
            }

            chrome
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            // 录制中这一屏是要进成片的，所以除视频以外什么都不画 ——
            // 返回/计时这类控件只在「还没开始录」时出现。中止靠长按。
            if !flow.isCapturing {
                HStack(spacing: 10) {
                    Button {
                        flow.abort()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(.ultraThinMaterial, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }

            Spacer(minLength: 0)

            if let errorText = flow.errorText, !flow.isCapturing {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(Color(red: 1, green: 0.7, blue: 0.68))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
        }
        .allowsHitTesting(true)
    }
}

#Preview {
    CaptureScreenView(flow: DemoFlow.shared)
}
