# 瀑布流 + 下拉露背景墙 + 星海假 3D

分支：`feat/waterfall-starfield`
日期：2026-09-24
基线：`001f42f 图片转2D 接入`

## 缘起

两个问题起头：

1. 当前项目的滚动用的是 UIKit 的 `UIScrollView` 还是 SwiftUI 的内容？
2. 想做一个瀑布流，支持滑动；当第一屏内容**下拉到屏幕中间**时呈现"背景墙"效果，
   背景墙上是劳斯莱斯星空顶式的假 3D 星海动画。

第 1 问的答案直接决定了第 2 问怎么做，所以先答它。

---

## 一、当前项目的滚动是什么实现

| 位置 | 实现 | 说明 |
| --- | --- | --- |
| 手机端主界面 | SwiftUI `Form` | `PhoneRootView`，内部是 SwiftUI 的 List/ScrollView 体系 |
| 手机端遥控台 | `.safeAreaInset(edge: .bottom)` | 挂在滚动区域**之外**，避免手势竞争 |
| **外接屏内容** | **手写 `.offset` + `clipShape`** | 不是 `ScrollView`，滚动位置来自 `RemoteControl.scroll` |

**全项目没有任何 `UIScrollView` 参与滚动。** UIKit 只出现在宿主层：
`MockExternalDisplay` 的 `PassthroughWindow`、`ExternalDisplaySceneDelegate` 的
`UIWindow` / `UIHostingController`。

外接屏侧的"滚动"实际上是这样一行：

```swift
.offset(y: plan.scroll.contentOffset(scroll: remote.scroll, pull: pull))
```

### 为什么外接屏不能用 ScrollView

外接屏的 role 是 `windowExternalDisplayNonInteractive`，**收不到任何触摸事件**：

- 真机：`ExternalDisplaySceneDelegate` 里 `window.isUserInteractionEnabled = false`，
  系统本来也不向该 role 投递触摸；
- 模拟器 mock：`PassthroughWindow.hitTest` 恒返回 `nil`，触摸全部落到下层窗口；
- iOS 27 的 SwiftUI accessory 更是在 API 层面就叫 `ExternalNonInteractiveAccessory`。

手势到不了那棵视图树，所以挂一个 `ScrollView` 会得到一个永远不动、也没人能滚的视图。

**这反而是这次改造的有利条件**：滚动位置已经是一个可编程的归一化标量，
瀑布流、下拉、星海推进都能挂在同一个标量上，不用和 UIKit 的 `contentOffset` 打架。

---

## 二、scroll / pull 双维度模型

### 问题

需求里"下拉露出背景墙"和原有的"上下滚动"是两件事，而原来的 `scroll` 被 clamp 在
`0...1`，**表达不了负值**。

但它们其实是**同一条数轴上的两段**：手指一直在往一个方向拖，只是越过顶部之后语义变了。
所以内部只留一个权威标量：

```
position > 0  →  正常滚动进度（0 = 顶部，1 = 底部）
position < 0  →  顶部下拉的超出行程
```

对外仍然暴露 `scroll` 与 `pull` 两个属性，因为渲染侧关心的是两件不同的事
（内容位移 / 背景墙露出量），但**唯一权威只有 `position`**。

> 若把它拆成两个可独立写的存储属性，下拉时被阻尼吃掉的那部分行程，
> 在回拉时会变成凭空多出来的滚动 —— 手指一松内容就跳。

### 手感曲线

```swift
// PullCurve
static let rawLimit: CGFloat = 0.9      // 拖 0.9 个板高 = pull 1
static let exponent: CGFloat = 1.7

static func progress(raw: CGFloat) -> CGFloat {
    guard raw > 0 else { return 0 }
    let t = min(raw / rawLimit, 1)
    return 1 - pow(1 - t, exponent)
}
```

`1 - (1 - t)^e` 在 `t = 0` 处的导数是 `e`（≈1.7），起手轻快；越接近 1 导数越小，末段发沉。
这正是 iOS 弹性滚动的观感。

**曲线在 `t = 1` 处恰好取到 1，不是渐近逼近** —— 这一点很关键：
若用 `1 - 1/(t·k + 1)` 那类渐近式，`pull` 永远到不了 1，
「内容顶边落在屏幕中线」这个几何承诺就永远差一截。

逆函数 `rawValue(forProgress:)` 供滑杆、按钮与调试预置使用。两者往返必须恒等 ——
滑杆拖到底必须落在承诺位置上，这条写进了断言。

### 不需要新手势

下拉是同一个 `DragGesture` 的延续：`scroll` 到 0 之后自动转成 `pull`。
调用方（`RemoteControlPad`）不需要判断边界。

---

## 三、瀑布流：为什么 LazyVGrid 不行

`LazyVGrid` 是**等高网格** —— 同一行的所有 cell 高度取该行最高的那个，
剩下的用空白补齐。那是「网格」不是「瀑布流」：瀑布流要求每一列的项独立堆叠、
互不对齐，才能形成错落的竖列。SwiftUI 没有内置这个布局。

### 纯函数布局

核心是一个可脱离 UI 断言的纯函数：

```swift
static func make(items: [WaterfallItem], metrics: WaterfallMetrics) -> WaterfallLayout
```

贪心分列：每一项都放进当前**最矮**的列。复杂度 `O(n·k)`，k 是 3 或 4，实质是常数。

**平手时取下标小的列** —— 保证同一份输入永远得到同一份输出。
布局抖动会让逐状态截图对比完全失去意义，而截图是本项目唯一可行的验证手段。

### 高度用权重而不是点数

外接屏可能是 1080p / 4K / 模拟器的 letterbox 小窗口。绝对点数在其中之一上必然溢出或过疏。
所以 `WaterfallItem` 存的是**权重**，实际高度 = `权重 × unitHeight`，
而 `unitHeight = 画面短边 × 0.20`。

### 列数按宽高比选

```swift
static func columnCount(for viewport: CGSize) -> Int {
    guard viewport.height > 0 else { return 3 }
    return viewport.width / viewport.height > 1.6 ? 4 : 3
}
```

横屏宽幅（16:9 及以上）用 4 列更饱满；letterbox 小窗口退到 3 列，
否则列宽会窄到放不下卡片里的文字。

### 卡片配色

随机色相**不是**均匀洒满色轮 —— 那样必然抽到荧光绿、屎黄、脏紫这些在暗底上很难看的区间。
改用「锚点 + 抖动」：

```swift
/// 挑过的色相锚点，刻意绕开 0.12...0.35（黄绿区间）
private static let hueAnchors: [CGFloat] = [
    0.55, 0.62, 0.72, 0.80, 0.88, 0.93, 0.97, 0.05, 0.09
]
```

饱和度 0.30...0.62、明度 0.22...0.42 —— 暗调区间，保证卡片上的白字可读。

---

## 四、下拉几何

```
contentOffsetY = pullOffset(pull) - scrollOffset(scroll)
maxPullDistance = 视口高 × 0.5
```

`pull = 1` 时内容顶边正好落在屏幕中线，上半屏完整露出背景墙。

三个附加视觉信号：

| 信号 | 实现 | 目的 |
| --- | --- | --- |
| 顶边圆角 | `cornerRadius = base × 0.03 × pull` | 从"铺满视口"过渡到"浮在星海上的卡片" |
| 阴影 | 半径与不透明度都乘 `pull` | 同上，加强浮起感 |
| 容器不透明底色 | `Color(red: 0.004, ...)` | 透光的话星海会从卡片缝隙透上来，"墙"立不住 |

### 一条容易被忽略的推导约束

`pull = 1` 时可见的内容高度只剩半个视口，而内容顶部第一个元素上方还有 `inset` 的内边距。
所以 hero 的高度必须满足：

```
inset + heroHeight <= 视口高 × 0.5
```

违反它的表现是"下拉到底之后标题被屏幕下沿切掉半截"——**看起来像渲染 bug，
查错方向很容易跑偏**。所以做成函数而不是写注释：

```swift
static func maxLeadingElementHeight(viewport: CGSize, inset: CGFloat) -> CGFloat {
    viewport.height * pullDistanceRatio - inset
}
```

实测这个上限在三种视口下**都是生效的那个**（理想占比 0.56 从未达到）：

| 视口 | 理想 hero 高 | 上限 | 实际采用 |
| --- | --- | --- | --- |
| 1920×1080 | 604.8 | 464.4 | 464.4 |
| 1024×768 | 430.1 | 330.2 | 330.2 |
| 355×200 | 112.0 | 86.0 | 86.0 |

---

## 五、星海：假 3D 的成立条件

### 为什么是「压缩过的透视」

教科书式的透视除法 `scale = focal / depth` 把深度差放大成巨大的尺度差：
本例里 `depth` 从 0.34 到 1.14，`scale` 就从 2.65 跨到 0.79 ——
近处的星被推到画面外，远处的星全挤在中心，**整片星海变成一个隧道，而不是穹顶**。

但完全不做透视（纯分层平移）又只剩平移视差，近处的星不会变大、远处的不变淡，
脑子立刻判定这是张平面图。

所以把两个用途**分别压缩**：

```swift
let rawScale = focal / depth
let positionScale = pow(rawScale, 0.35)   // 0.82...1.35 —— 位置位移
let sizeScale     = pow(rawScale, 0.60)   // 0.76...1.79 —— 尺寸
```

尺寸的指数比位置大，因为"远小近大"是大脑判断深度最强的单一线索。
两者共用同一个 `rawScale`，所以仍然严格单调、物理自洽，
只是把动态范围收窄到「穹顶」而不是「隧道」的量级。

### 相机推进刻意很小

劳斯莱斯的星空顶是「一片静止的穹顶 + 极缓慢的视角变化」，不是穿梭飞行。
`dollyDepth` 只取 `0.26` —— 推太深会变成星际穿越，那种急速拉丝的观感和"星空顶"是两回事。

### 视差只由空鼠驱动

```swift
private var parallaxTilt: CGPoint {
    guard remote.pointerSource == .airMouse, let pointer = remote.pointer else { return .zero }
    return CGPoint(x: (pointer.x - 0.5) * 2, y: (pointer.y - 0.5) * 2)
}
```

空鼠的物理动作就是"抬手转动手机"，那正是视差的来源。
触控板上手指的位置和"视角"没有任何物理关系 —— 拿它做视差会让星海在滚动时跟着乱晃。
好处是零成本：光标本来就在传，不需要为视差再开一路传感器。

---

## 六、劳斯莱斯质感六要素

随机白点不等于星空顶。真正决定"像不像"的是这六条：

1. **穹顶底色**：中心偏上稍亮的深蓝 → 边缘全黑。纯黑背景会让星点看起来贴在玻璃上。
2. **亮度幂律分布**：`brightness = 0.50 + pow(U, 1.7) × 0.50`。
   均匀随机会让整片星海"一样亮"，那是噪点不是星空。
3. **独立闪烁**：每颗星的相位与频率都不同。
   **同步呼吸是"假"的第一来源** —— 真实的星空不会整片一起眨眼。
4. **十字光芒**：最亮的那约 3% 才有。用**一条闭合路径 + 一次径向渐变**画完四个方向，
   而不是四条各带线性渐变的描边（后者要 4 次绘制，且接缝处有亮度断层）。
5. **尺寸与亮度正相关**：挡掉"半径 4pt 却只有三成不透明度的灰斑"这种像污渍的组合。
6. **深度衰减**：`1 - normalized × 0.40`，下限 0.60。再暗下去远处的星整片消失，
   星海会显得比实际稀疏。

---

## 七、性能预算

| 项 | 量 | 说明 |
| --- | --- | --- |
| 星点总数 | 600 | 在 letterbox 上肉眼确认"够密"之后定下 |
| 亮星（走径向渐变光晕） | 约 12.5%（75 颗） | 每帧约 10 万像素渐变填充，相对 4K 的 830 万可忽略 |
| 带十字光芒 | 约 3%（18 颗） | |
| 暗点绘制调用 | **60 次/帧** | 按 (尺寸档 5 × 不透明度档 6 × 色温档 2) 合并 Path |
| 未露出时 | **0 帧** | `TimelineView(paused: pull <= 0.002)` |

暗点分批是这里唯一真正影响帧预算的优化：600 颗星里九成以上是暗点，
逐颗 `fill` 就是每帧 550 次绘制调用，而它们全是同一种东西。
合并成几十条 Path 之后每帧只剩几十次。

---

## 八、实测

| 项 | 方法 | 结果 |
| --- | --- | --- |
| 纯函数断言 | `swiftc` 独立编译 + 运行 | **85 条全过**（见下） |
| 构建 | `xcodebuild`（模拟器，deployment target 17.0） | 零错误零告警 |
| 下拉几何 | 逐 pull 状态启动截图（0 / 0.25 / 0.5 / 0.75 / 1） | `pull = 1` 时内容顶边落在中线 ✔ |
| 瀑布流 | 同上截图 | 四列错落，列首对齐，无溢出 ✔ |
| 滚动 | `scroll = 0.5 / 1` 截图 | 内容正常上移，背景墙被完全盖住 ✔ |
| 星海密度 | 投影器统计 + 放大截图 | 600 颗全部在视口内，露出半屏时 319 颗 ✔ |

### 纯函数断言覆盖

```
1. 瀑布流布局      · 全项分配 / 无重复 / 贪心性质 / 列宽严丝合缝 / 可滚动
2. 确定性          · 同输入同布局 / 同种子同卡片
3. 下拉几何        · maxPullDistance / 位移方向 / 圆角
3b. hero 高度约束  · 三种视口下都完整落在可见区
4. 手感曲线        · 端点 / 单调 / 起手导数 / 末段导数 / 逆函数往返恒等
5. 星海投影        · 近大远小 / 近亮远暗 / 相机推进 / 剔除 / 视差方向
6. 星表分布        · 幂律 / 投影后不透明度中位数 / 亮星占比 / 光芒占比 / 暖度均值
7. 铺满度          · 三种视口的可见比例与跨度
8. 露出区域星数    · 下拉到 1 时上半屏的实际星数
```

脚本在 `.scratch/verify/`（已 gitignore）。它之所以能跑，是因为
`WaterfallLayout` / `DisplayScrollGeometry` / `StarfieldModel` 三个文件
**只依赖 `CoreGraphics` 和 `Foundation`**，不认识 SwiftUI —— 这是刻意设计的。

### 验证盲区

`simctl` **没有触摸注入 API**，手机端的拖拽/捏合无法在自动化里复现。
所以「手势 → 状态」这半条链路只能靠手点。为了让「状态 → 渲染」那半条可脚本化，
新增了 `MockRemoteState`（`Sources/Debug/`）：

```bash
xcrun simctl launch <device> <bundle> -mockExternalDisplay -remoteState pull=0.5
xcrun simctl launch <device> <bundle> -mockExternalDisplay -remoteState scroll=0.3,pull=0.25,zoom=1.5
```

与 `MockExternalDisplay` / `MockAirMouseSource` 同一约定：只在带启动参数时生效。
**它伪造的是输入，不是度量** —— 不编造任何"看起来像真实数据"的读数。

---

## 九、踩坑

### 1. 内容整体被上移（重复踩了 README 第 10 条）

**现象**：`pull = 0` 时 hero 完全看不见，瀑布流从第 3 行开始。

**原因**：内容容器刻意不受视口高度约束（它要能滚动），于是 ZStack 的尺寸被撑到内容总高；
而 `.frame(width:height:)` 默认是**居中**对齐，ZStack 比 frame 大时会被往上顶掉半个差值。

**修复**：`.frame(..., alignment: .topLeading)`。

这与当初 `scrollColumn` 踩的是同一个坑。当时的修复只加在了内层容器上，
这次把外层约束拆掉，同一个 bug 就换了个位置复现 —— 教训是**这个坑与具体层级无关，
只与"是否有子视图会超出父视图"有关**。

### 2. hero 标题被屏幕下沿切掉半截

见第四节。根因是布局没有遵守一条可推导的几何约束，修法是让代码自己满足它。

### 3. 星点画成方块，看起来像像素噪点

**原因**：为了省性能，暗点用 `fill` 小矩形代替圆，理由是"等价于点且更便宜"。
实测不成立：1.5pt 的方块在 3x 屏上是 4~5 个物理像素，放大后能明确看出是方的。

**修复**：合并 Path 之后画圆的代价已经可以忽略，没有任何理由再牺牲形状。

### 4. 星海稀疏得像几颗孤星

两个独立原因叠加：

- **完整透视除法**把近处的星推出了画面（见第五节）；
- **三个衰减系数相乘**（亮度 × 深度衰减 × 闪烁）把中位数不透明度压到 0.45 附近，
  在近黑底上就是一片灰点。

**修复**：位置/尺寸分别压缩透视指数；对最终不透明度取 `0.72` 次幂做感知提亮。
后者不是"调好看"的玄学 —— 亮底暗前景与暗底亮前景本来就需要不同的 gamma，
线性叠加出来的中间调在感知上是偏暗的。

修复后投影后不透明度中位数从 0.45 升到 0.65，这条已固化成断言防回归。

---

## 十、已知限制

1. **没有虚拟化**。外接屏用不了 `ScrollView`，也就没有 `Lazy*` 容器的按需创建，
   36 张卡片全部一次性建出来。这个量级没问题，**上百张得自己写回收池**。
2. **`pull` 只能在顶部触发**。这是刻意的 —— 下拉的语义就是"已经到顶了还继续拽"。
   滚动到中段时下拉无效。
3. **iOS 17~26 的旧路径未实测**。本机只有 iOS 27 运行时，
   旧路径（`ExternalDisplaySceneDelegate`）沿用同一份 `ExternalDisplayRootView`，
   但真机外接屏上的观感未验证。
4. **真机 4K 帧率未测**。性能预算是按绘制调用数与填充像素估算的，不是实测值。
