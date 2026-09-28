import CoreGraphics
import Foundation

/// 全景内容的投影档位。
///
/// ## 为什么 demo 里它是"标记"而不是"识别"
/// demo 没有真实相册 —— 36 张卡是固定种子的渐变占位（见 `WaterfallItem.demoItems`）。
/// 所以「对全景图片分类」这件事只能做成**标记 + 筛选**：先给卡片打一个投影标记，
/// 再让手机端按标记过滤出「只看全景」。
///
/// 真实工程里这一位由相册自己给出（`PHAsset.mediaSubtypes` 含 `photoPanorama`，
/// 见 jove-view 的 `PhotoKitLibrary`），届时把 `tier(forRoll:)` 换成读资源元数据即可，
/// 下游（角标、筛选、详情页路由）一行都不用改。
///
/// ## 两类为什么必须分开
/// 柱面（iPhone 全景）与 equirect（360°）的**像素排布方式不同**：
/// 前者贴到球面上会在垂直方向被拉伸畸变，后者本来就是球面展开。
/// 混做一套几何必翻车 —— 所以这里先分档，几何在详情页按档分流。
enum PanoramaProjection: String, CaseIterable, Sendable {

    /// iPhone 拍的「全景」：柱面扫掠（非 equirect），比例通常 1:3 ~ 1:5。
    ///
    /// 它的正确几何是**平面横滑**（iOS 照片 App 即如此），
    /// 正好等于既有 `PhotoDetailGeometry(.fill)` 的"铺满 + 可左右拖"，
    /// 所以走它时**不新增几何**，只把 yaw 接到横向 pan 上。
    case cylindrical

    /// 360° 等距柱状（equirect）照片，比例固定 **2:1**。
    ///
    /// 它的正确几何是**球体内表面**，需要 `EquirectProjection`（本线唯一的新几何）。
    case equirect
}

extension PanoramaProjection {

    /// 该投影下"正前方"对应的 `yaw`（度）。
    ///
    /// 两类全景的**像素排布不同，所以"正面"落在不同的数上** —— 这是进页面时
    /// 默认朝向的依据，也是「视角归零」该回到哪里的依据（票 `09`）。
    ///
    /// | 档 | 正前方 | 依据 |
    /// |---|---|---|
    /// | equirect | **180°** | 等距柱状把相机的正前方缝在贴图水平中点，而 0° 是接缝 |
    /// | 柱面 | **0°** | `CylindricalPan` 的 0 就是居中（`progress = yaw/180`） |
    ///
    /// 两者都不是"随手取个好看的数"：退回同一个常数会让 equirect 打开就正对
    /// 接缝（0° 经线），那是整幅图里**最不该当默认**的一条线。
    var frontYaw: CGFloat {
        switch self {
        case .equirect: return 180
        case .cylindrical: return 0
        }
    }
}

extension PanoramaProjection {

    /// 均匀随机数 → 投影档位（`nil` = 普通照片）。
    ///
    /// 与 `WaterfallItem.photoAspectRatio(forRoll:)` 同构：把"档位映射"抽成静态函数，
    /// 「某个随机数该落进哪一档」这件事本身才能被断言 —— 而它错了在截图上
    /// 几乎看不出来，只会表现为"全景怎么这么少"。
    ///
    /// 比例是**拍脑袋的演示值**（真实相册里全景是极少数），只要求有 3~4 张
    /// equirect 能进截图矩阵。它走独立的随机序列，改它**不会**动到
    /// `.scratch/verify/main.swift` §14 的指纹。
    static func tier(forRoll roll: CGFloat) -> PanoramaProjection? {
        guard roll.isFinite else { return nil }
        if roll < 0.80 { return nil }
        if roll < 0.92 { return .cylindrical }
        return .equirect
    }
}

/// 幕墙的内容筛选档。
///
/// ## 为什么归"显示什么"这半边
/// `RemoteControl` 管"怎么看"（滚动 / 缩放 / 光标），`DisplayContentStore` 管
/// "显示什么"（图案、标题、动画）—— 筛选改的是**内容集合**，所以它归后者。
/// 这与 `README` 第三节那张职责表一致，也让"切筛选"不去碰任何视口状态，
/// 于是 `RemoteControl.position` 在筛选前后**原样不动**（关掉筛选回到原样、
/// 滚动位置不跳的根据）。
enum PanoramaFilter: String, CaseIterable, Identifiable, Sendable {

    case all
    case panoramaOnly

    var id: String { rawValue }

    /// 某一项在当前档位下是否可见。
    func accepts(_ item: WaterfallItem) -> Bool {
        switch self {
        case .all:
            return true
        case .panoramaOnly:
            return item.projection != nil
        }
    }

    /// 按档位过滤列表。
    ///
    /// 纯函数、保持原顺序：`WaterfallLayout.make` 是贪心分列，
    /// 输入顺序变了列分配就变 —— 筛选必须是"删掉一些项"，不是"重排"。
    func apply(to items: [WaterfallItem]) -> [WaterfallItem] {
        items.filter(accepts)
    }
}
