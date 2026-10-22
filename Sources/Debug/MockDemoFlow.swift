import Foundation

@MainActor
enum MockDemoFlow {

    static var rawValue: String? {
        let flag = "-mockFlow"
        let arguments = ProcessInfo.processInfo.arguments

        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix(flag + "=") {
                return String(argument.dropFirst(flag.count + 1))
            } else if argument == flag, index + 1 < arguments.count {
                return arguments[index + 1]
            }
        }
        return nil
    }

    static func applyIfNeeded() {
        guard let raw = rawValue else { return }

        let flow = DemoFlow.shared
        let remote = RemoteControl.shared
        remote.movePointer(to: GlassesLauncherLayout.standard.buttonCenter)

        switch raw {
        case "activate":
            flow.activate(at: remote.pointer)
        case "run":
            flow.activate(at: remote.pointer)
            Task {
                // 等页面把事件接好再点 —— 固定 sleep 会和 WKWebView 的加载竞速，
                // 早一步点就是「点了没反应」。
                _ = await flow.page.waitUntilReady()
                try? await Task.sleep(for: .milliseconds(400))
                // 走真人那条路：点页面上的播放键，而不是直接调 beginCapture。
                #if DEBUG
                flow.page.simulatePlayTap()
                #endif
            }
        default:
            break
        }
    }
}
