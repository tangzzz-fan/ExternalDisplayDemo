import Foundation
import Observation
import SwiftUI
import UIKit

/// 模拟器/无外接屏硬件时的替身。
///
/// iOS 模拟器**不支持**连接外部显示器，`windowExternalDisplayNonInteractive`
/// 的 scene 永远不会被创建。为了仍然能调试外接屏那份 UI，这里在手机屏所在的
/// `windowScene` 上再叠一个 16:9 的 letterbox 窗口，里面挂载与外接屏**完全相同**
/// 的 `ExternalDisplayRootView`，并把自己登记成一个 `source == .mock` 的 attachment。
///
/// 这层只在 `-mockExternalDisplay` 启动参数存在时生效，完全不参与真机链路；
/// 手机端界面里会多出一个开关，方便随时收起它去做表单操作。
@MainActor
@Observable
final class MockExternalDisplay {

    static let shared = MockExternalDisplay()

    /// 启动参数 `-mockExternalDisplay`。
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-mockExternalDisplay")
    }

    /// 绑定到手机端的调试开关；置 true 即挂载模拟外接屏，置 false 即收起。
    var isVisible: Bool = false {
        didSet {
            guard oldValue != isVisible else { return }
            isVisible ? install() : uninstall()
        }
    }

    @ObservationIgnored private weak var windowScene: UIWindowScene?
    @ObservationIgnored private var window: UIWindow?

    private init() {}

    // MARK: - Lifecycle

    func bootstrap(on windowScene: UIWindowScene) {
        guard Self.isEnabled else { return }
        self.windowScene = windowScene
        if !isVisible { isVisible = true }  // didSet → install()
    }

    /// 手机 scene 断开时调用，保证不留悬挂的 window。
    func reset() {
        window?.isHidden = true
        window = nil
        windowScene = nil
        ExternalDisplayMonitor.shared.detachMock()
        if isVisible { isVisible = false }
    }

    // MARK: - Install / Uninstall

    private func install() {
        guard window == nil, let windowScene else { return }

        let container = windowScene.coordinateSpace.bounds
        guard container.width > 0, container.height > 0 else { return }

        // 模拟一块 3x 的外接屏，像素尺寸由 letterbox 尺寸推出来
        let scale: CGFloat = 3
        let aspect = Self.parseAspect() ?? 16.0 / 9.0
        let rect = Self.letterboxedRect(in: container.insetBy(dx: 20, dy: 60), aspect: aspect)

        let mockWindow = PassthroughWindow(windowScene: windowScene)
        mockWindow.frame = rect
        mockWindow.windowLevel = .normal + 1
        mockWindow.backgroundColor = .black
        mockWindow.layer.cornerRadius = 20
        mockWindow.layer.borderWidth = 4
        mockWindow.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.8).cgColor
        mockWindow.clipsToBounds = true
        mockWindow.rootViewController = UIHostingController(rootView: ExternalDisplayRootView())
        mockWindow.isHidden = false
        window = mockWindow

        ExternalDisplayMonitor.shared.attachMock(
            pixelSize: CGSize(width: rect.width * scale, height: rect.height * scale),
            nativeScale: scale
        )
    }

    private func uninstall() {
        window?.isHidden = true
        window = nil
        ExternalDisplayMonitor.shared.detachMock()
    }

    // MARK: - Helpers

    /// 在容器内按给定宽高比居中摆放，多出来的方向留黑边。
    ///
    /// 底部预留 `reservedBottom`：手机屏底部常驻着遥控台（`RemoteControlDock`），
    /// 而替身窗口浮在 `.normal + 1` 层、永远盖在主窗口之上，不主动避开的话
    /// 展开遥控台时两者会在屏幕中段互相遮挡。
    private static func letterboxedRect(in container: CGRect, aspect: CGFloat) -> CGRect {
        guard container.width > 0, container.height > 0, aspect > 0 else { return container }

        let reservedBottom: CGFloat = 96
        let available = CGRect(
            x: container.minX,
            y: container.minY,
            width: container.width,
            height: max(container.height - reservedBottom, 0)
        )
        guard available.height > 0 else { return container }

        if available.width / available.height > aspect {
            let width = available.height * aspect
            return CGRect(x: available.midX - width / 2, y: available.minY, width: width, height: available.height)
        } else {
            let height = available.width / aspect
            return CGRect(x: available.minX, y: available.midY - height / 2, width: available.width, height: height)
        }
    }

    /// 支持 `-mockExternalDisplayAspect=4:3` 与 `-mockExternalDisplayAspect 4:3` 两种写法。
    private static func parseAspect() -> CGFloat? {
        let flag = "-mockExternalDisplayAspect"
        let arguments = ProcessInfo.processInfo.arguments
        var raw: String?

        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix(flag + "=") {
                raw = String(argument.dropFirst(flag.count + 1))
            } else if argument == flag, index + 1 < arguments.count {
                raw = arguments[index + 1]
            }
        }

        guard let raw else { return nil }
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return CGFloat(parts[0] / parts[1])
    }
}

/// 不吞掉触摸事件，否则手机端 UI 会被这个覆盖窗口挡住。
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
