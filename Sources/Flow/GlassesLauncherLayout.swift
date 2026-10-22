import CoreGraphics

struct GlassesLauncherLayout {

    static let standard = GlassesLauncherLayout()

    let normalizedRect = CGRect(x: 0.19, y: 0.44, width: 0.62, height: 0.2)

    var buttonCenter: CGPoint {
        CGPoint(x: normalizedRect.midX, y: normalizedRect.midY)
    }

    func rect(in viewport: CGSize) -> CGRect {
        CGRect(
            x: normalizedRect.minX * viewport.width,
            y: normalizedRect.minY * viewport.height,
            width: normalizedRect.width * viewport.width,
            height: normalizedRect.height * viewport.height
        )
    }

    func hitTest(_ point: CGPoint?) -> Bool {
        guard let point else { return false }
        return normalizedRect.contains(point)
    }
}
