import Foundation
import ImageIO
import UIKit

/// 全景素材的解码与缓存。
///
/// ## 为什么必须有缓存
/// `UIImage(contentsOfFile:)` **每次调用都重新解码**：一张 3840×1920 的 JPEG
/// 解一次是几十毫秒量级，而渲染侧每帧都会重算 body（拖动视角时 60 Hz）。
/// 没有这一层，转一下头就是每帧一次全尺寸解码 —— 外接屏直接掉成幻灯片，
/// 而且它在截图里完全看不出来（静态一帧照样正确）。
///
/// 用 `NSCache` 而不是 `[String: UIImage]`：它线程安全，且**会在内存压力下
/// 自动清理**。素材解码后每张约 30 MB 位图，这种对象留着自己管不如交给系统。
///
/// ## 为什么是独立类型，不并进 `PanoramaAssetCatalog`
/// 那个类型要能进 `.scratch/verify/main.swift` 的 `swiftc` 命令 ——
/// 而那条命令产出的是 **macOS** 命令行二进制，`import UIKit` 在那里不存在。
/// 所以「查表」（纯逻辑、可断言）与「解码」（UIKit、只做 IO）分成两个类型：
/// 前者进断言脚本，后者不进。
enum PanoramaImageStore {

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // 素材一共 5 张（A 类 2 + B 类 3），留一点余量即可。
        // 不设上限的话，位图会一直堆到系统发内存警告。
        cache.countLimit = 8
        return cache
    }()

    /// 缩略图缓存，**第二只**。
    ///
    /// ## 为什么不和全尺寸那张共用一只
    /// 两条路径的读取频率与体量差一个数量级，混在一只缓存里会互相驱逐：
    /// 素材条每帧问 5 次缩略图，而每张缩略图只有几十 KB —— 共用时它们会把
    /// 那几张 30 MB 的全尺寸位图挤出去，于是**每帧重新解码 3840×1920 的 JPEG**。
    /// 症状是全景页掉成幻灯片，而缩略图那一侧看起来一切正常。
    ///
    /// ## 键里带尺寸
    /// 同一个文件在 1080p（槽宽 335）与模拟器 letterbox（槽宽 62）上要的
    /// 降采样尺寸差五倍。不把尺寸编进键里的话，先起的那一档会把结果留给另一档，
    /// 表现为"缩略图糊成一片"或"缩略图完全没降采样、还是原图的大小"。
    private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 16
        return cache
    }()

    /// 按文件名取图。文件不在或解码失败时返回 `nil`（调用方回落网格）。
    static func image(named name: String) -> UIImage? {
        let key = name as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = PanoramaAssetCatalog.url(forFileName: name) else { return nil }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// 降采样缩略图，供素材条使用。
    ///
    /// ## 为什么必须走 `CGImageSource` 而不是把原图缩小
    /// `UIImage(contentsOfFile:)` 是**先全解再缩小**：素材条有 5 个槽位，
    /// 每次求值都要 5 张 3840×1920 的全尺寸解码（每张约 30 MB 位图），
    /// 而槽位实际只需要三百来点宽。`CGImageSourceCreateThumbnailAtIndex`
    /// 在**解码阶段**就按 `maxPixelSize` 出图，解码量降两个数量级。
    ///
    /// ## 素材缺失时的行为
    /// 返回 `nil` —— 与全尺寸那条一样，调用方回落占位底。
    /// 这里刻意**不**编一张灰图出来：素材是可选资源，
    /// "没有素材"与"素材是一张灰图"在截图上是两件事，前者要能一眼看出来。
    static func thumbnail(named name: String, maxPixelSize: CGFloat) -> UIImage? {
        guard maxPixelSize > 0 else { return nil }
        guard let url = PanoramaAssetCatalog.url(forFileName: name) else { return nil }

        let pixelSize = Int(maxPixelSize.rounded(.up))
        let key = "\(name)@\(pixelSize)" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            // 带上 EXIF 的旋转：素材里有竖幅来源的照片，不吃这一条会横过来。
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let image = UIImage(cgImage: cgImage)
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    /// 按卡片取图。`projection` 为 `nil`、或素材查不到时返回 `nil`。
    ///
    /// 不看 `-panoramaAsset` ——「这一页要不要用真实素材」是渲染层的选择，
    /// 这里只负责"给我名字我就解给你"。分开之后，缓存对两条路径都生效。
    static func image(for item: WaterfallItem, in items: [WaterfallItem]) -> UIImage? {
        guard let projection = item.projection else { return nil }
        guard let name = PanoramaAssetCatalog.fileName(
            forItemID: item.id,
            projection: projection,
            in: items
        ) else { return nil }
        return image(named: name)
    }
}
