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
///
/// 它需要主屏的 `UIWindowScene`（替身窗口要挂上去），而 SwiftUI 没有对应的环境值 ——
/// 但 `UIApplication.shared.connectedScenes` 随时可查，所以不需要为此在视图树里
/// 保留一个宿主 VC。见 `mainWindowScene`。
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

    /// 替身窗口假装的屏幕缩放比（模拟一块 3x 的外接屏）。
    private static let scale: CGFloat = 3

    /// 底部常驻遥控台**实际**占用的高度（点）。
    ///
    /// 由 `RemoteControlDock` 自己上报，而不是写死一个常数。
    /// 遥控台收起时只有一条读数栏（约 50pt），展开后是三四百点，
    /// 而且**空鼠栏比触控板栏还高**（多一块手势面）—— 任何写死的值都必然过时：
    /// 这个数曾经是 96，空鼠栏加上手势面之后「触控板 / 空鼠」切换器就被窗口盖住了。
    @ObservationIgnored private(set) var dockHeight: CGFloat = 96

    private init() {}

    /// 遥控台上报自身高度。高度变化会重新摆放替身窗口。
    ///
    /// 高度在**点**上，与 `windowScene.coordinateSpace.bounds` 同一坐标系，可以直接比。
    func reserveBottom(_ height: CGFloat) {
        guard height > 0, abs(height - dockHeight) > 0.5 else { return }
        dockHeight = height
        layout()
    }

    // MARK: - Lifecycle

    /// 由入口在启动与回前台时调用；未开 `-mockExternalDisplay` 时是 no-op。
    ///
    /// 主屏 scene 在这里自己查：SwiftUI 没有 windowScene 的环境值，但 `UIApplication`
    /// 随时可查，所以不必往视图树里塞一个宿主 VC 专门去「登记」一个出来。
    func bootstrap() {
        guard Self.isEnabled else { return }
        guard let scene = Self.mainWindowScene else { return }
        self.windowScene = scene
        if !isVisible { isVisible = true }  // didSet → install()
    }

    /// 主屏（`windowApplication` role）的 `UIWindowScene`。
    static var mainWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication }
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

        let mockWindow = PassthroughWindow(windowScene: windowScene)
        mockWindow.windowLevel = .normal + 1
        mockWindow.backgroundColor = .black
        mockWindow.layer.cornerRadius = 20
        mockWindow.layer.borderWidth = 4
        mockWindow.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.8).cgColor
        mockWindow.clipsToBounds = true
        mockWindow.rootViewController = UIHostingController(rootView: ExternalDisplayRootView())
        mockWindow.isHidden = false
        window = mockWindow

        layout()
    }

    /// 按当前视口与遥控台高度重新摆放替身窗口，并同步上报给监视器。
    ///
    /// 抽成独立方法是因为它有两个触发源：窗口刚装好时，以及遥控台高度变化时。
    private func layout() {
        guard let window, let windowScene else { return }

        let container = windowScene.coordinateSpace.bounds
        guard container.width > 0, container.height > 0 else { return }

        let aspect = Self.parseAspect() ?? 16.0 / 9.0
        let rect = Self.letterboxedRect(
            in: container.insetBy(dx: 20, dy: 60),
            aspect: aspect,
            reservedBottom: dockHeight
        )
        window.frame = rect

        ExternalDisplayMonitor.shared.attachMock(
            pixelSize: CGSize(width: rect.width * Self.scale, height: rect.height * Self.scale),
            nativeScale: Self.scale
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
    ///
    /// **高度由调用方传进来**（= 遥控台上报的实际高度），不再写死常数 ——
    /// 写死过一次 96，空鼠栏加上手势面之后就被盖住了。
    ///
    /// 注意窗口是**宽度受限**的：16:9 在 362pt 宽的可视区里只有 204pt 高，
    /// 远小于可用的竖向空间。所以预留量只影响窗口的**纵向位置**，不影响尺寸 ——
    /// 遥控台变高时窗口整体上移，下方留出的空白是"不遮挡"的必然代价。
    private static func letterboxedRect(
        in container: CGRect,
        aspect: CGFloat,
        reservedBottom: CGFloat
    ) -> CGRect {
        guard container.width > 0, container.height > 0, aspect > 0 else { return container }

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
