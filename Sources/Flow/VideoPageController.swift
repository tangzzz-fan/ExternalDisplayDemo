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
        /// 站点上的播放键被点了。要不要真的开始录屏由 `DemoFlow` 决定。
        case playRequested
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?

    /// 当前页面是远程网站还是打包在 app 里的本地演示页。
    ///
    /// 这个区分不是洁癖：远程页面里 `<video>` 的音轨由 WebKit 在**别的进程**渲染，
    /// ReplayKit 采不到；本地那份 `video.mp4` 又和它不是同一个素材，
    /// 拿它出声只会音画全错。所以音频那条路只对本地页成立。
    let isRemote = true

    /// 远程页面地址。取自站点自己的移动版，不带跟踪参数。
    static let remoteURL = URL(string: "https://www.bilibili.com/video/BV1xrnz6gEVD/")!

    /// 注入到远程页面的桥。
    ///
    /// 站点自己的播放器不会给原生发任何事件，所以这里做三件事：
    /// - 盯住 `<video>`，把 `play` / `playing` / `ended` / `loadedmetadata` / `error`
    ///   翻成原生事件（站点是 SPA，元素后插入，所以要 MutationObserver + 定时扫描）；
    /// - 提供 `__edBridge.enter/exit`，靠给 `<html>` 挂 class 把视频提到顶层铺满 ——
    ///   站点的播放器 UI 不会跟着走，但录制只要画面；
    /// - 用 `requestVideoFrameCallback` 把 mediaTime 记下来，供以后对齐音画。
    ///
    /// 一个已知的坑：`play` 事件里**不能**去 `pause()` 再等原生启动采集。
    /// 站点播放器会把"被外部暂停"当成用户操作，再调 `play()` 不一定接得上，
    /// 所以这里不拦，接受成片开头少掉采集启动的那零点几秒。
    static let bridgeScript = #"""
    (function () {
      if (window.__edBridge) { return; }

      function post(name, payload) {
        try {
          window.webkit.messageHandlers.page.postMessage(Object.assign({ event: name }, payload || {}));
        } catch (e) {}
      }

      var cls = 'ed-fullscreen';

      var style = document.createElement('style');
      style.textContent = [
        'html.' + cls + ', html.' + cls + ' body { overflow: hidden !important; background: #000 !important; }',
        'html.' + cls + ' video { position: fixed !important; left: 0 !important; top: 0 !important;',
        ' width: 100vw !important; height: 100vh !important; max-width: none !important;',
        ' max-height: none !important; object-fit: cover !important;',
        ' background: #000 !important; z-index: 2147483647 !important; }'
      ].join('\n');
      (document.head || document.documentElement).appendChild(style);

      var bound = new WeakSet();

      function watchFrames(video) {
        if (!video.requestVideoFrameCallback) { return; }
        video.requestVideoFrameCallback(function (now, metadata) {
          if (metadata && typeof metadata.mediaTime === 'number') {
            window.__edMediaTime = metadata.mediaTime;
          }
          watchFrames(video);
        });
      }

      function bind(video) {
        if (!video || bound.has(video)) { return; }
        bound.add(video);

        video.addEventListener('loadedmetadata', function () {
          post('loadedmetadata', {
            duration: video.duration || 0,
            width: video.videoWidth || 0,
            height: video.videoHeight || 0
          });
        });

        video.addEventListener('play', function () {
          post('playrequest', { mediaTime: video.currentTime || 0 });
        });

        video.addEventListener('playing', function () { post('playing'); });

        video.addEventListener('ended', function () { post('ended'); });

        video.addEventListener('error', function () {
          post('error', { code: video.error ? video.error.code : -1 });
        });

        watchFrames(video);
      }

      function scan() {
        var list = document.querySelectorAll('video');
        for (var i = 0; i < list.length; i++) { bind(list[i]); }
      }

      // 站点在 WebView 里会弹「未能成功跳转客户端 / 下载 App」的引导层。
      // 它不是错误，但会盖住视频、也会被录进成片，所以这里按文案定位后整层隐藏。
      // 找不到关闭按钮就直接藏 —— 反正这块内容对录制没有价值。
      function dismissGuides() {
        var nodes = document.querySelectorAll('div, section');
        for (var i = 0; i < nodes.length; i++) {
          var el = nodes[i];
          if (el.childElementCount > 8) { continue; }

          var text = el.textContent || '';
          if (text.indexOf('未能成功跳转') < 0 && text.indexOf('下载哔哩哔哩') < 0) { continue; }

          var box = el.closest('[class*="mask"], [class*="modal"], [class*="dialog"], '
            + '[class*="guide"], [class*="openapp"]') || el.parentElement || el;
          var close = box.querySelector('[class*="close"], [class*="Close"], [class*="cancel"]');
          if (close) { close.click(); }
          box.style.display = 'none';
          return;
        }
      }

      window.__edBridge = {
        enter: function () { document.documentElement.classList.add(cls); scan(); },
        exit: function () { document.documentElement.classList.remove(cls); },
        // 站点的 `<video>` 是后插入的，点一次找不到就退回去重试，别一次不成就放弃。
        play: function (attempt) {
          var video = document.querySelector('video');
          if (video) {
            video.play().catch(function () {});
            return;
          }
          if ((attempt || 0) < 24) {
            setTimeout(function () { window.__edBridge.play((attempt || 0) + 1); }, 500);
          }
        }
      };

      var ticks = 0;
      window.__edTick = function () {
        scan();
        if (ticks < 60) { dismissGuides(); ticks += 1; }
      };

      new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
      setInterval(window.__edTick, 600);
      window.__edTick();
      post('ready');
    })();
    """#

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
        didLoad = true

        guard isRemote else {
            guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "VideoPage") else {
                onEvent?(.failed("找不到 VideoPage/index.html"))
                return
            }
            webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }

        var request = URLRequest(url: Self.remoteURL)
        request.timeoutInterval = 20
        // 用 Safari 的移动版 UA：WKWebView 默认 UA 会被站点当成"内置浏览器"，
        // 更容易撞上下载 App 的引导层。
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        webView?.load(request)
    }

    /// 采集已经在跑：把页面切成全屏。
    ///
    /// 远程页面没有 `beginPlayback()` 这种钩子，全屏靠注入的 `__edBridge.enter()`
    /// 给 `<html>` 挂一个 class，由注入的样式把 `<video>` 提到顶层铺满视口。
    func beginPresentation() {
        evaluate("window.__edBridge && window.__edBridge.enter();")
    }

    /// 退出全屏，把页面还给用户。
    func endPresentation() {
        evaluate("window.__edBridge && window.__edBridge.exit();")
    }

    /// 启动失败：把页面还给用户，并说明原因。
    func fail(_ message: String) {
        endPresentation()
        guard let data = try? JSONSerialization.data(
            withJSONObject: message,
            options: [.fragmentsAllowed]
        ), let literal = String(data: data, encoding: .utf8) else { return }
        evaluate("window.__page && window.__page.fail(\(literal));")
    }

    func reset() {
        endPresentation()
        didLoad = false
        isReady = false
        webView?.stopLoading()
    }

    #if DEBUG
    /// 调试用：替真人点一下页面上的播放键。
    ///
    /// `simctl` 没有触摸注入 API，`-mockFlow run` 要走**和真人完全一样**的
    /// JS → 原生 → 授权 → 播放链路，就只能从这里点。
    func simulatePlayTap() {
        evaluate("window.__edBridge && window.__edBridge.play();")
    }
    #endif

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
            case "playrequest":
                onEvent?(.playRequested)
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

extension VideoPageController: WKNavigationDelegate {

    /// 远程页面没有 `ready` 这个自报事件，只能以导航完成近似。
    ///
    /// SPA 的 `<video>` 往往在这之后才挂上来，所以这里放行的是"页面到了"，
    /// 不代表"视频能播了"；真的能播由注入脚本的 `loadedmetadata` 说明。
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            isReady = true
            completeReadyWait()
            onEvent?(.ready)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            onEvent?(.failed("页面加载失败：\(error.localizedDescription)"))
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated {
            onEvent?(.failed("无法打开页面：\(error.localizedDescription)"))
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
