import CoreGraphics
import Foundation

/// 全景详情页的**帧源**档位。
///
/// ## 名字为什么从"素材"扩成"帧源"
/// 前两档（网格 / 真实素材）都是"一张不动的图"；票 `05` 加进来的两档
/// 把这一层的意思挑明了：它回答的是**"这一帧的像素从哪来"**，
/// 而不是"用了哪份素材"。帧源与几何必须解耦 —— 换帧源不该动一个点。
///
/// ## 四档各自的用途
/// | 档 | 像素来源 | 验什么 |
/// |---|---|---|
/// | `grid` | 程序化经纬网 | **数值**：经度 90° 落在哪一列，网格能直接读出来 |
/// | `real` | 取回的实景照片 | **观感**：形变像不像、360° 接缝看不看得出来 |
/// | `frame` | 360 视频抽出的静帧 | **链路**：真实相机出来的等距柱状帧，几何是否仍逐点一致 |
/// | `animated` | 程序化逐帧纹理 | **解耦**：帧变了，几何摆位不动 |
///
/// 网格始终不退场：一张实景照片里没有"经度 90° 在哪一列"这种可读信息，
/// 所以"数"永远只能由网格给（spec §4.6、票 `05`）。
enum PanoramaAssetSource: String, CaseIterable, Sendable {

    /// 程序化经纬网。**默认档** —— 它与几何逐点对应，是截图判读的主判据。
    case grid

    /// 真实素材（`Scripts/fetch-panorama-assets.sh` 取回的那批）。
    case real

    /// 从 360 视频里抽出的**静态帧**（`Scripts/extract-panorama-frame.swift` 的离线产物）。
    ///
    /// 与 `real` 的差别不在"真不真"，而在**它是相机出来的**：`real` 那批是
    /// 公开授权的照片，抽帧这条走的是"视频 → 帧"这条真实工程里会用到的路径
    /// （只是本票把"实时"换成了"离线一次性"）。
    case frame

    /// 程序化**逐帧纹理**：内容随时间变、几何线一个点不动。
    ///
    /// 它存在的唯一理由是票 `05` 那条判据 —— "帧源与几何解耦"。
    /// 拿两张不同时刻的截图并排：会动的东西动了，经纬线还在原处。
    case animated

    var title: String {
        switch self {
        case .grid: return "程序化网格"
        case .real: return "真实素材"
        case .frame: return "视频抽帧"
        case .animated: return "动画纹理"
        }
    }

    /// 这一档是不是**只对 equirect 成立**。
    ///
    /// 柱面（A 类）没有经纬网、也没有等距柱状帧 —— 它与这三档都不同源。
    /// 判据留在渲染侧（`cylindricalImage` 只认 `.real`），这里只把口径写明，
    /// 免得有人以为"四档对两类都成立"。
    var appliesToCylindrical: Bool { self == .real }
}

/// 一条可以**直接选**的全景素材。
///
/// ## 为什么它带 `itemID` 而不只是一个文件名
/// 素材条上"看哪一张"与瀑布流上"看哪张卡的全景页"最后落到**同一个动作**：
/// `RemoteControl.openDetail(item:)`。把那张卡的 id 一并算出来，点击处就只是
/// 一次直传 —— 否则渲染侧还得在点击那一刻反查"这个文件对应哪张卡"，
/// 而那一刻恰好是手感最要紧的地方，不该做一次查表。
///
/// ## 条的实体是"素材"不是"卡片"
/// 5 条 = 5 个文件。柱面有 5 张卡（`fileName` 按 `index % pool.count` 铺）
/// 但只有 2 个文件，所以条子按文件列、`itemID` 取该文件的**首个**卡片。
/// 这条映射收在 `canonicalItemID(fileIndex:projection:in:)` 里 ——
/// 不抽出来的话，"条子第几条对应哪张卡"会变成只有跑起来才知道的事，
/// 而截图矩阵是靠命令行 `strip=<index>` 驱动那个下标去截的。
struct PanoramaAsset: Equatable, Sendable, Identifiable {

    /// bundle 里的文件名，同时是这张素材的唯一标识。
    let fileName: String

    /// 它自己的投影档 —— 决定点进去之后走球面还是柱面几何。
    let projection: PanoramaProjection

    /// 这条素材在瀑布流里对应的**首张**卡片。
    let itemID: Int

    var id: String { fileName }

    /// 条子上显示的短名。由文件名推出，见 `PanoramaAssetCatalog.displayName(forFileName:)`。
    var displayName: String { PanoramaAssetCatalog.displayName(forFileName: fileName) }
}

/// 全景素材的查表：`item.id` → 素材文件名。
///
/// ## 为什么是"同投影内的序号"而不是"按 id 取模"
/// 按 id 取模看着更短，但演示集里 equirect 是 `[8, 14, 16]` —— 三个 id 对
/// 三张素材取模会撞成两张（`8 % 3 = 2`、`14 % 3 = 2`），于是"三张全景卡"
/// 里有两张长得一模一样。截图矩阵里这会被误读成"素材没换"。
/// 取**同投影内的出现序号**才能保证一一铺开，且它不依赖 id 的具体数值 ——
/// 换种子、改卡数都不会让映射塌掉。
///
/// ## 查的是哪里的文件
/// `Scripts/fetch-panorama-assets.sh` 把素材落进 `.scratch/panorama-assets/`（不入库），
/// `project.yml` 把那个目录作为**可选** folder 资源打进 bundle。
/// 所以：有素材就按 `real` 档显示真实照片，没有就 `url(forFileName:)` 返回 `nil`、
/// 调用方回落网格 —— "素材缺失不崩、不空屏"这条判据就是靠这个 `nil` 成立的。
enum PanoramaAssetCatalog {

    /// bundle 里的素材目录名。必须与 `project.yml` 那条资源的路径末段一致。
    static let directoryName = "panorama-assets"

    /// B 类：equirect 照片。三张都是正好 2:1（脚本硬校验守着）。
    static let equirectFiles = [
        "equirect-nationalgalerie.jpg",
        "equirect-duisburg-hochofen.jpg",
        "equirect-alma.jpg"
    ]

    /// A 类：柱面宽幅。比例 3:1 ~ 4:1，**不是** equirect。
    static let cylindricalFiles = [
        "cylindrical-eso-adaptive-optics.jpg",
        "cylindrical-hindelang.jpg"
    ]

    /// C 类：从 360 视频里抽出的一帧（离线产物，见 `Scripts/extract-panorama-frame.swift`）。
    ///
    /// ## 它为什么不在 `equirectFiles` 里
    /// 那一列是**素材条**的清单（票 `07`）。往里加一项，条子就从 5 条变成 6 条，
    /// 已有的截图基线整体挪位 —— 而"让用户挑素材"与"验证帧源与几何解耦"
    /// 是两件事，不该互相牵连。所以抽帧走**单独一个文件名**，
    /// 由 `PanoramaAssetSource.frame` 直接取，不参与素材条的铺位计算。
    ///
    /// 文件缺失时 `url(forFileName:)` 返回 `nil`，渲染侧回落网格 ——
    /// 与其余素材同一套退路（没跑过抽帧工具的机器上就是这样）。
    static let videoFrameFile = "equirect-360frame-stennis.jpg"

    static func files(for projection: PanoramaProjection) -> [String] {
        switch projection {
        case .equirect: return equirectFiles
        case .cylindrical: return cylindricalFiles
        }
    }

    /// 某张卡在**同投影类型**里的出现序号（从 0 起）。
    ///
    /// 找不到（id 不在集里、或投影对不上）时返回 `nil` —— 调用方据此回落到网格，
    /// 而不是猜一个素材给它。
    static func ordinal(of id: Int, projection: PanoramaProjection, in items: [WaterfallItem]) -> Int? {
        var seen = 0
        for item in items where item.projection == projection {
            if item.id == id { return seen }
            seen += 1
        }
        return nil
    }

    /// 某张卡该用哪个素材文件。普通照片（`projection == nil`）不适用。
    static func fileName(forItemID id: Int, projection: PanoramaProjection, in items: [WaterfallItem]) -> String? {
        let pool = files(for: projection)
        guard !pool.isEmpty else { return nil }
        guard let index = ordinal(of: id, projection: projection, in: items) else { return nil }
        return pool[index % pool.count]
    }

    /// 素材在 bundle 里的实际位置；文件不存在返回 `nil`。
    ///
    /// 判的是**文件真的在不在**，而不是"bundle 里该有这么个目录" ——
    /// 素材是可选资源，没跑过获取脚本的机器上那个目录根本不存在，
    /// 这时返回一个不存在的 URL，`UIImage(contentsOfFile:)` 只会给一张空白，
    /// 表现为"全景页一片黑"且不报错，是最难归因的一种表现。
    static func url(forFileName name: String) -> URL? {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent(directoryName) else { return nil }
        let url = base.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 素材条的可选清单

    /// 条子上列出来的全部素材：equirect 3 条在前、柱面 2 条在后。
    ///
    /// ## 顺序是固定的，且不依赖 id 的数值
    /// 先按 `stripOrder` 分组、组内保持 `equirectFiles` / `cylindricalFiles`
    /// 的书写次序，于是下标 `0/1/2` 恒为 equirect、`3/4` 恒为柱面。调试预置
    /// （`-remoteState strip=2`）是靠这个下标去截图的，顺序一漂，
    /// "第 2 条"就变成另一张素材，而截图看上去仍然"有个环亮着"。
    ///
    /// 顺序**刻意写死**而不走 `PanoramaProjection.allCases`：那一条跟的是
    /// 枚举成员的声明次序，而枚举声明是先柱面后 equirect（`cylindrical` 是
    /// 既有几何的入口，先写的）。直接拿它当清单顺序，会让"第 0 条"变成柱面 ——
    /// 一个纯属偶然的次序被当成了约定，将来谁调一下枚举顺序就悄悄换了默认素材。
    static let stripOrder: [PanoramaProjection] = [.equirect, .cylindrical]

    /// ## 查不到就整条丢弃，而不是留一个空位
    /// 某条素材在演示集里没有对应卡片时（改种子、改卡数都可能发生），
    /// 留空位会让后面所有槽位的下标与截图脚本里的数字错开一位。
    /// 丢弃则下标仍然连续，"第几条是哪个文件"这条对应关系不变。
    ///
    /// `items` 必须是**全集**，不是筛选后的可见集：条子列的是素材，
    /// 与幕墙上此刻摆哪些卡无关（见票 `07` 的回归判据）。
    static func assets(in items: [WaterfallItem]) -> [PanoramaAsset] {
        var assets: [PanoramaAsset] = []

        for projection in stripOrder {
            for (index, fileName) in files(for: projection).enumerated() {
                guard let itemID = canonicalItemID(
                    fileIndex: index,
                    projection: projection,
                    in: items
                ) else { continue }
                assets.append(
                    PanoramaAsset(fileName: fileName, projection: projection, itemID: itemID)
                )
            }
        }

        return assets
    }

    /// 某个素材文件在瀑布流里**对应的第一张卡**。
    ///
    /// 判据是"铺位相同" —— `fileName(forItemID:projection:in:)` 按
    /// `ordinal % pool.count` 铺，所以文件 `j` 对应序号满足 `ordinal % count == j`
    /// 的那些卡，取其中序号最小的那张。直接拿 `fileName` 比对而不是自己重算取模：
    /// 铺法将来要改（比如按素材宽高比排序）时，这里跟着自动对，不会各说各话。
    ///
    /// 越界（`fileIndex` 不在池子里）返回 `nil` —— 与其余查表同一条规矩：
    /// 查不到就说查不到，不猜一张卡给调用方。
    static func canonicalItemID(
        fileIndex: Int,
        projection: PanoramaProjection,
        in items: [WaterfallItem]
    ) -> Int? {
        let pool = files(for: projection)
        guard fileIndex >= 0, fileIndex < pool.count else { return nil }
        let target = pool[fileIndex]

        for item in items where item.projection == projection {
            if fileName(forItemID: item.id, projection: projection, in: items) == target {
                return item.id
            }
        }
        return nil
    }

    /// 条子上的短名：`equirect-nationalgalerie.jpg` → `nationalgalerie`。
    ///
    /// 去掉投影前缀与扩展名、把连字符换成空格。**不**加"全景"之类的后缀 ——
    /// 条子上的 5 条全是全景，每一条都写一遍反而挤掉了真正能区分它们的那几个词。
    ///
    /// 做成纯函数是为了它可断言：名字错了在截图上只是"文字不太对"，
    /// 很容易被当成排版问题放过去，而它其实是查表查错了。
    static func displayName(forFileName name: String) -> String {
        var stem = name
        for prefix in ["equirect-", "cylindrical-"] where stem.hasPrefix(prefix) {
            stem = String(stem.dropFirst(prefix.count))
        }
        if let dot = stem.lastIndex(of: ".") {
            stem = String(stem[stem.startIndex..<dot])
        }
        return stem.replacingOccurrences(of: "-", with: " ")
    }
}
