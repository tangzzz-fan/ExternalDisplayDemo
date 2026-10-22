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
                try? await Task.sleep(for: .seconds(1.5))
                await flow.beginCapture()
            }
        default:
            break
        }
    }
}
