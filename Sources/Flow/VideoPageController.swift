import Foundation
import WebKit

@MainActor
final class VideoPageController: NSObject {

    enum Event {
        case ready
        case metadata(duration: Double, pixelSize: CGSize)
        case playing
        case started(mediaTime: Double)
        case ended
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?

    private weak var webView: WKWebView?
    private var didLoad = false
    private var isReady = false
    private var readyWait: CheckedContinuation<Void, Never>?

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func waitUntilReady(timeout: Duration = .seconds(6)) async -> Bool {
        if isReady { return true }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if isReady {
                continuation.resume()
                return
            }
            readyWait = continuation

            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                self.completeReadyWait()
            }
        }

        return isReady
    }

    private func completeReadyWait() {
        guard let wait = readyWait else { return }
        readyWait = nil
        wait.resume()
    }

    func load() {
        guard !didLoad else { return }
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "VideoPage") else {
            onEvent?(.failed("找不到 VideoPage/index.html"))
            return
        }
        didLoad = true
        webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func play() {
        evaluate("window.__page && window.__page.play();")
    }

    func pause() {
        evaluate("window.__page && window.__page.pause();")
    }

    func rewind() {
        evaluate("window.__page && window.__page.rewind();")
    }

    func reset() {
        didLoad = false
        isReady = false
        webView?.stopLoading()
    }

    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script) { _, error in
            if let error {
                #if DEBUG
                print("[VideoPage] js error: \(error.localizedDescription)")
                #endif
            }
        }
    }

    nonisolated func handle(body: [String: Any]) {
        let name = body["event"] as? String ?? ""
        let duration = (body["duration"] as? NSNumber)?.doubleValue ?? 0
        let width = (body["width"] as? NSNumber)?.doubleValue ?? 0
        let height = (body["height"] as? NSNumber)?.doubleValue ?? 0
        let message = body["message"] as? String ?? ""
        let code = (body["code"] as? NSNumber)?.intValue ?? -1

        MainActor.assumeIsolated {
            switch name {
            case "ready":
                isReady = true
                completeReadyWait()
                onEvent?(.ready)
            case "loadedmetadata":
                onEvent?(.metadata(duration: duration, pixelSize: CGSize(width: width, height: height)))
            case "playing":
                onEvent?(.playing)
            case "started":
                onEvent?(.started(mediaTime: (body["mediaTime"] as? NSNumber)?.doubleValue ?? 0))
            case "ended":
                onEvent?(.ended)
            case "error":
                onEvent?(.failed("播放器报错（code \(code)）"))
            case "playfailed":
                onEvent?(.failed("自动播放被拒绝：\(message)"))
            default:
                break
            }
        }
    }
}

extension VideoPageController: WKScriptMessageHandler {

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any] else { return }
            handle(body: body)
        }
    }
}
