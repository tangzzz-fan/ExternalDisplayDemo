import Foundation

/// 从启动参数预置遥控台的**展开状态与输入方式**。
///
/// ## 为什么需要它
/// 遥控台默认收起、默认停在「触控板」那一栏，而这两件事都只能靠手指点 ——
/// `xcrun simctl` 没有触摸注入 API，模拟器 GUI 也没有可脚本化的设备窗口。
/// 于是「空鼠栏的布局对不对」在自动化里**完全看不到**，
/// 只能靠人手动展开、切栏、再截图。
///
/// 这个开关把"点两下"变成启动参数，于是空鼠栏也能进入逐状态截图流程。
///
/// ```bash
/// xcrun simctl launch <device> <bundle> -dockState=expanded,airMouse
/// xcrun simctl launch <device> <bundle> -dockState=expanded
/// ```
///
/// 与 `MockRemoteState` / `MockExternalDisplay` 同一约定：
/// **只在带启动参数时生效**，不参与真机链路；伪造的是**输入**，不是度量。
enum MockDockState {

    static var isEnabled: Bool { rawValue != nil }

    static var rawValue: String? {
        let flag = "-dockState"
        let arguments = ProcessInfo.processInfo.arguments
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix(flag + "=") {
                return String(argument.dropFirst(flag.count + 1))
            }
            if argument == flag, index + 1 < arguments.count {
                return arguments[index + 1]
            }
        }
        return nil
    }

    struct State: Equatable {

        /// 遥控台是否展开。
        var isExpanded = false

        /// 选中的输入方式；`nil` 表示不改，沿用默认的触控板。
        ///
        /// 用字符串而不是直接引用 `RemoteControlDock.ControlMode`：
        /// 解析发生在 Debug 层，不该反向依赖 App 层的类型。
        var modeRaw: String?
    }

    /// 解析 `expanded` / `airMouse` / `trackpad` 这几个逗号分隔的记号。
    ///
    /// 只认 `expanded` 这一个正向记号，不认 `collapsed` ——
    /// 默认就是收起，再给一个"让它保持默认"的记号没有意义。
    static func parse(_ raw: String) -> State {
        var state = State()
        for token in raw.split(separator: ",") {
            switch token.trimmingCharacters(in: .whitespaces) {
            case "expanded":
                state.isExpanded = true
            case "airMouse":
                state.modeRaw = "airMouse"
            case "trackpad":
                state.modeRaw = "trackpad"
            default:
                break
            }
        }
        return state
    }

    /// 当前应当应用的预置；没有启动参数时返回 `nil`。
    static var current: State? {
        rawValue.map(parse)
    }
}
