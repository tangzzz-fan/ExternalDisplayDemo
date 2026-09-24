import CoreGraphics
import Foundation

/// 调试用：从启动参数预置 `RemoteControl` 的视口状态。
///
/// ## 为什么必须有它
/// `simctl` **没有触摸注入 API** —— 手机端触控板上的拖拽、捏合无法在自动化里复现。
/// 于是「手势 → 状态」这半条链路只能靠手点；如果「状态 → 渲染」也依赖手点，
/// 那"逐状态截图核对几何"这件事就根本做不了，星海的相机推进、内容的下拉位移
/// 全都只能靠肉眼看一遍了事。
///
/// 这里把状态直接写进去，让后半个链路可以脚本化：
/// 每个 `pull` 值启动一次、截一张图，五张图并排就能核对几何对不对。
///
/// 与 `MockExternalDisplay` / `MockAirMouseSource` 同一约定：只在带启动参数时生效，
/// 不参与真机链路。**它伪造的是输入，不是度量** —— 和 `MockAirMouseSource` 一样，
/// 不编造任何"看起来像真实数据"的读数。
///
/// ## 用法
/// ```
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay -remoteState pull=0.5
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay \
///     -remoteState scroll=0.3,pull=0.25,zoom=1.5
/// xcrun simctl launch <device> <bundle-id> -mockExternalDisplay -remoteState pointer=0.3:0.35
/// ```
///
/// 也支持 `-remoteState pull=0.5` 这种不带 `=` 的写法（与 `-mockExternalDisplayAspect`
/// 的解析保持一致）。
enum MockRemoteState {

    static var isEnabled: Bool {
        rawValue != nil
    }

    /// 取出 `-remoteState` 后面的原始字符串。
    static var rawValue: String? {
        let flag = "-remoteState"
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

    /// 解析结果。
    struct State: Equatable {
        var scroll: CGFloat?
        var pull: CGFloat?
        var zoom: CGFloat?
        var pointer: CGPoint?
    }

    /// 解析 `key=value` 列表，逗号分隔。无法识别的键直接忽略 ——
    /// 打错字时宁可少设一个状态，也不要让整个应用起不来。
    static func parse(_ raw: String) -> State {
        var state = State()

        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "scroll":
                state.scroll = CGFloat(Double(value) ?? 0)
            case "pull":
                state.pull = CGFloat(Double(value) ?? 0)
            case "zoom":
                state.zoom = CGFloat(Double(value) ?? 1)
            case "pointer":
                // `pointer=x:y` —— 用冒号而不是逗号，因为逗号已经是键值对之间的分隔符，
                // 复用会让 `pointer=0.3,0.35` 被切成两个残缺的键值对。
                // 冒号也与 `-mockExternalDisplayAspect=4:3` 的写法一致。
                let components = value.split(separator: ":").compactMap { Double($0) }
                if components.count == 2 {
                    state.pointer = CGPoint(x: components[0], y: components[1])
                }
            default:
                continue
            }
        }

        return state
    }

    /// 把启动参数里的状态写进 `RemoteControl`。
    ///
    /// 顺序有讲究：先 `pull` 再 `scroll`。`pull(to:)` 会清掉滚动，
    /// 反过来调用则不会 —— 想要"滚动到中段**同时**下拉"这种组合态时，
    /// 这个顺序才成立。
    ///
    /// 默认值写成 `nil` 再在函数体里解析，而不是 `= .shared`：
    /// 默认参数表达式在**调用方**的上下文求值，而 `.shared` 是 `@MainActor` 隔离的，
    /// 直接写在参数上会触发「main actor-isolated property can not be referenced
    /// from a nonisolated context」告警。
    @MainActor
    static func applyIfNeeded(to target: RemoteControl? = nil) {
        guard let raw = rawValue else { return }
        let remote = target ?? .shared
        let state = parse(raw)

        if let pull = state.pull {
            remote.pull(to: pull)
        }
        if let scroll = state.scroll {
            remote.scroll(to: scroll)
        }
        if let zoom = state.zoom {
            remote.setZoom(zoom)
        }
        if let pointer = state.pointer {
            remote.movePointer(to: pointer, source: .touch)
        }
    }
}
