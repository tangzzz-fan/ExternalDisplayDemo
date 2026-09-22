import UIKit
import Observation

/// 外接屏连接状态的中心记录点。
///
/// ## 为什么不监听 `UIScreen`
/// iOS 16 起 `UIScreen.screens`、`UIScreen.didConnectNotification`、
/// `UIScreen.didDisconnectNotification` 全部被废弃（SDK 中标注
/// `API_DEPRECATED(ios(3.2, 16.0))`），官方指引用 scene 体系替代。
/// 系统只会在**应用声明了 external display role 之后**才为外接屏建立
/// 独立的 `UISceneSession`，并回调对应 scene delegate。
///
/// ## 数据来源的单一性
/// 本类的所有写入都来自 `ExternalDisplaySceneDelegate` 的挂载/卸载回调
/// （外加 `Debug/MockExternalDisplay.swift` 的模拟挂载），
/// 因此这里的 `attachments` 与系统实际状态不会出现分叉。
@MainActor
@Observable
final class ExternalDisplayMonitor {

    static let shared = ExternalDisplayMonitor()

    /// 外接屏来源，用于区分真实硬件与模拟器 mock。
    enum Source: String {
        case physical
        case mock
    }

    struct Attachment: Identifiable, Hashable {
        let id: String
        /// 外接屏的像素分辨率描述。iOS 没有公开的屏幕名称 API
        /// （`UIScreen.displayName` 只在 macOS 的 `NSScreen` 上存在），
        /// 所以用分辨率 + scale 作为标识。
        let resolution: String
        let pixelSize: CGSize
        let nativeScale: CGFloat
        let source: Source
    }

    private(set) var attachments: [Attachment] = []

    var isConnected: Bool { !attachments.isEmpty }

    var statusText: String {
        isConnected ? "已连接 \(attachments.count) 块外接屏" : "未检测到外接屏"
    }

    private static let mockID = "mock-external-display"

    private init() {}

    // MARK: - 真实外接屏（仅由 ExternalDisplaySceneDelegate 调用）

    func attach(_ windowScene: UIWindowScene) {
        let screen = windowScene.screen
        let attachment = Attachment(
            id: windowScene.session.persistentIdentifier,
            resolution: Self.describe(screen.nativeBounds.size, scale: screen.nativeScale),
            pixelSize: screen.nativeBounds.size,
            nativeScale: screen.nativeScale,
            source: .physical
        )
        guard !attachments.contains(where: { $0.id == attachment.id }) else { return }
        attachments.append(attachment)
    }

    func detach(_ sessionID: String) {
        attachments.removeAll { $0.id == sessionID }
    }

    // MARK: - 模拟外接屏（仅由 MockExternalDisplay 调用）

    func attachMock(pixelSize: CGSize, nativeScale: CGFloat) {
        let attachment = Attachment(
            id: Self.mockID,
            resolution: Self.describe(pixelSize, scale: nativeScale),
            pixelSize: pixelSize,
            nativeScale: nativeScale,
            source: .mock
        )
        attachments.removeAll { $0.id == Self.mockID }
        attachments.append(attachment)
    }

    func detachMock() {
        attachments.removeAll { $0.id == Self.mockID }
    }

    // MARK: - Helpers

    private static func describe(_ size: CGSize, scale: CGFloat) -> String {
        "\(Int(size.width)) × \(Int(size.height)) px @\(String(format: "%.1f", scale))x"
    }
}
