# 外接屏内容是怎么截图的

> **先说结论：没有「截外接屏」这回事。**
>
> 外接屏的内容之所以能进截图，唯一原因是**我们在模拟器上把它渲染进了手机屏上的一个替身窗口**。
> `xcrun simctl io screenshot` 抓的**始终是手机整屏**，外接屏那块区域只是这张整屏里的一小块矩形，
> 剩下三步都是「把那一小块抠出来、放大、逐像素读」。
>
> 换句话说：**没有搬移，就没有截图。** 这是 `-mockExternalDisplay` 除了「能调试」之外的第二个存在理由。

---

## TL;DR：四段链路

| # | 环节 | 谁干的 | 产物 | 为什么必须有它 |
| --- | --- | --- | --- | --- |
| 1 | **搬移** | `MockExternalDisplay`（App 内） | 手机屏上一个 16:9 的替身窗口，里面挂**同一份** `ExternalDisplayRootView` | 截图 API 只认手机屏，外接屏内容默认不在其中 |
| 2 | **抓屏** | `xcrun simctl io <device> screenshot` | 1206 × 2622 px 整块手机屏 | 系统级抓屏，不需要设备上有任何配合代码 |
| 3 | **裁切** | `.scratch/tools/crop` | 约 1146 × 670 px 的窗口区域 | 整屏里外接屏只占 362 × 203 pt，圆角/列间缝/星点全被压没了 |
| 4 | **判读** | `.scratch/tools/probe` | 沿一行/一列的颜色分段 | 「边界落在第几行」本身就是本工程的判据，肉眼在缩略图上不可靠 |

```
① 搬移                     ② 抓屏                  ③ 裁切            ④ 判读
┌─────────────┐   ┌──────────────────────┐   ┌────────────┐   ┌──────────────┐
│ 外接屏 UI    │   │ 手机整屏 PNG          │   │ 窗口区域    │   │ y 382..392   │
│ 挂进替身窗口 │──▶│ 1206×2622 px          │──▶│ 1146×670   │──▶│  #CD7222 橙边 │
│ (手机 scene) │   │ 外接屏只占其中一块     │   │  (×1 或 ×N) │   │  边界在此    │
└─────────────┘   └──────────────────────┘   └────────────┘   └──────────────┘
```

---

## 一、为什么必须先「搬」：截图 API 只认手机屏

真机路径下，外接屏那份 UI 是渲染在**它自己的 `UIScreen`** 上的：

```swift
// Sources/ExternalDisplay/ExternalDisplaySceneDelegate.swift:40-48
let window = UIWindow(windowScene: windowScene)          // ← windowScene 属于外接屏
window.rootViewController = UIHostingController(rootView: ExternalDisplayRootView())
window.isHidden = false
```

这块内容与手机屏的内容**是两个独立的渲染面**，而两条截图命令抓的都是「设备主屏」：

| 命令 | 抓的是 | 外接屏内容在不在里面 |
| --- | --- | --- |
| `xcrun simctl io <device> screenshot` | 模拟器手机屏 | ✗ |
| `xcrun devicectl device capture screenshot --device <UDID>` | 真机手机屏 | ✗ |

模拟器更彻底 —— **它根本不支持外接屏**，`windowExternalDisplayNonInteractive` 的 scene 永远不会被创建
（`MockExternalDisplay.swift:8-11`）。所以模拟器上没有「搬不搬」的选择，只有「搬出来才看得见」。

`-mockExternalDisplay` 因此在手机屏的 scene 上再叠一个窗口，把**同一份视图**挂进去
（不是仿制视图 —— 见 [`mock-external-display.md` 第五节](mock-external-display.md#五真正的关键复用同一份视图)）：

```swift
// Sources/Debug/MockExternalDisplay.swift:100-109
let mockWindow = PassthroughWindow(windowScene: windowScene)
mockWindow.windowLevel = .normal + 1
mockWindow.layer.cornerRadius = 20
mockWindow.layer.borderWidth = 4
mockWindow.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.8).cgColor
mockWindow.rootViewController = UIHostingController(rootView: ExternalDisplayRootView())
```

⭐ **那圈 4pt 橙色边框不只是装饰** —— 它是这套截图流程里**唯一的定位锚点**：
整屏截图里唯一的 `systemOrange`，探针一扫就知道窗口边界在哪（见第五节）。

> **本工程没有实现「应用内快照」。** 没有 `UIGraphicsImageRenderer`、没有
> `drawHierarchy(in:afterScreenUpdates:)`、没有 `snapshotView` —— 全仓库检索为零。
> 真机 + 真外接屏时，那块内容在本工程里**没有截图手段**，这是已知空缺（第八节）。

---

## 二、抓屏：命令与产物

```bash
DEV=65E2C3C1-9BDA-49A7-907F-C05AF893D6B6      # 模拟器 UDID
BID=com.jove.externaldisplaydemo

xcrun simctl install $DEV .scratch/DerivedData/Build/Products/Debug-iphonesimulator/ExternalDisplayDemo.app
xcrun simctl launch --terminate-running-process $DEV $BID \
    -mockExternalDisplay -dockState=expanded -remoteState lateral=1
sleep 3
xcrun simctl io $DEV screenshot .scratch/shots/x.png
```

产物固定是 **1206 × 2622 px**（iPhone 17 Pro，402 × 874 pt @ 3x）。三个细节：

- **`--terminate-running-process` 不能省。** 不加的话 app 已在前台，`launch` 只是把它调到前台，
  **启动参数一个字都不会生效** —— 症状是「截图内容和上一次一模一样」，很容易误判成「改动没生效」。
- **`sleep 3` 不是保守，是必要。** 星海走 `TimelineView(.animation)`，首帧要等
  `CADisplayLink` 起来；截图太早会拍到还没点亮的星海。
- **一行只能预设一个状态。** 想拍 N 个状态就启动 N 次（第七节给了批量脚本）。

### 状态怎么进得去

触摸注入没有 API，所以「状态 → 渲染」这半条链路靠**启动参数伪造输入**：

| 参数 | 伪造什么 | 例子 |
| --- | --- | --- |
| `-mockExternalDisplay` | 外接屏存在 | （必给） |
| `-remoteState` | 共享交互状态 | `scroll=0.3,pull=0.25,lateral=1,bottom=1,zoom=1.5,pointer=0.3:0.35,selected=7` |
| `-dockState` | 遥控台的展开状态与输入方式 | `expanded,airMouse` / `expanded,trackpad` |
| `-mockExternalDisplayAspect` | 替身窗口的宽高比 | `4:3` |

三者同一约定：**只在带启动参数时生效，不参与真机链路；伪造的是输入，不是度量。**

---

## 三、定位替身窗口：公式法

替身窗口的位置由 `MockExternalDisplay.letterboxedRect(in:aspect:reservedBottom:)` 算出，
输入只有三个：`container`（scene 的 bounds）、`aspect`（默认 16:9）、`dockHeight`（遥控台实测上报）。

代入本机（402 × 874 pt，`dockState=expanded` 时 `dockHeight ≈ 416 pt`）：

```
container.insetBy(dx: 20, dy: 60)              → x:20  y:60  w:362  h:754
available.height = 754 − 416 = 338
宽度受限（362/338 = 1.07 < 16:9）→ height = 362 ÷ (16/9) = 203.6

窗口 frame（点） = (20, 60 + (338 − 203.6)/2, 362, 203.6)
                = (20, 127.3, 362, 203.6)
像素（×3）      = (60, 382, 1086, 610)
```

**实测复核（探针扫该次截图）**：

| 边 | 实测像素 | 换算点 | 与公式 |
| --- | --- | --- | --- |
| 左（橙边起点） | 60 | 20.0 | `insetBy(dx: 20)` ✓ |
| 右（橙边终点） | 1145 | 381.7 | `20 + 362 = 382` ✓ |
| 上（橙边起点） | 382 | 127.3 | `60 + 67.3` ✓ |
| 下（橙边终点） | 991 | 330.3 | `127.3 + 203.3` ✓ |
| 尺寸 | **1086 × 610 px** | 362 × 203.3 pt | ✓ |

> **免费的自检**：替身窗口在 `layout()` 里上报给 `ExternalDisplayMonitor` 的像素尺寸是
> `rect.size × scale` —— 也就是 **1086 × 610 px**。这个数字会**渲染在画面里**
> （hero 副标题那行「1086 × 610 px」）。所以只要它和实测裁切区一致，
> 「窗口位置算对了」与「上报的分辨率没撒谎」两件事就同时被确认了。

⚠️ **公式法依赖 `dockHeight`，而它是运行时上报的。** 遥控台展开/收起、切到空鼠栏（多一块手势面）
都会改变它 —— 曾经写死 96 就出过事。所以**批量截图时优先用下面的实测法**。

---

## 四、定位替身窗口：实测法（推荐）

橙边是整屏里唯一的 `systemOrange`（实测 `#CD7222`，受 0.8 alpha 影响）。扫一条穿过窗口的
列/行，一眼就能读出四条边的像素坐标：

```bash
P=.scratch/tools/probe
S=.scratch/shots/x.png

PROBE_TOL=1 $P $S column 603 200 800    # → y 382...392  #CD7222  ← 上边
PROBE_TOL=1 $P $S column 603 950 1120   # → y 980...991  #CD7222  ← 下边
PROBE_TOL=1 $P $S row    600   0 120    # → x  60...71   #CE7324  ← 左边
PROBE_TOL=1 $P $S row    600 1080 1206  # → x 1080...1145 #BBB..→#F18028 ← 右边
```

得到包围盒 `x 60..1145, y 382..991` 后，外扩 `m` pt 的裁切矩形是：

```
x = (20 − m) × 3     y = (127.3 − m) × 3
w = (362 + 2m) × 3   h = (203.3 + 2m) × 3
```

取 `m = 10`（留出圆角与外发光）：

```bash
.scratch/tools/crop $S .scratch/shots/x-crop.png 30 352 1146 670 1
```

**为什么要留余量**：窗口有 20pt 圆角、幕墙有浮起投影，贴着边框裁会把四角切掉 ——
而「四角圆角是否按侧数正确」恰好是要核对的东西之一。

> 手机端背景是 `#F2F2F7`（浅色），替身窗口之外全是它。
> 这个色**不能**当边界判据 —— 它和窗口内的浅色卡片可能撞色；橙边才是唯一可靠的锚点。

---

## 五、判读：像素探针与容差陷阱

```bash
swiftc -O .scratch/tools/probe.swift -o .scratch/tools/probe

probe <png> row    <y> [x0] [x1]     # 沿一行扫
probe <png> column <x> [y0] [y1]     # 沿一列扫
probe <png> px     <x> <y>           # 读单点
```

输出把颜色相近的连续像素**归并成段**：`y 382...392  (11 px)  205,114,34  #CD7222`。

### ⚠️ `PROBE_TOL=1` 是核边界的**前提**，不是可选项

默认归并阈值是 **6**，对渐变/抗锯齿是合适的。但本工程有一处关键跳变**恰好落在阈值里**：

| 面 | 颜色 | |
| --- | --- | --- |
| 替身窗口底色（`.black`） | `#000001` | 差 **1~2 个单位** |
| 幕墙底板（半透 0.58 叠在黑上） | `#020205` | |

用默认阈值扫 `bottom=1`（上拉到底），**墙的下沿会连它背后那片纯黑一起被归并掉**，
输出看起来就是「墙根本没动」。当时据此差点得出「纵向几何算错了」的错误结论 ——
真相只是量错了：

| 状态 | 实测 | 理论 | |
| --- | --- | --- | --- |
| `bottom=1` 墙下沿距内容顶 | 95.0 pt | 97.8 pt | ✓（残差 2.8pt ≈ 4pt 边框 + 抗锯齿） |
| `lateral=1` 墙左沿距内容左 | 52.7 pt | 54.4 pt | ✓（同上） |

**规则：凡是核「半透面 vs 纯黑底」的边界，一律 `PROBE_TOL=1`。**
这个坑已经写进 `probe.swift` 的注释里（`:63-69`），免得下次再踩。

### 本工程的特征色对照

| 区域 | 颜色 | 说明 |
| --- | --- | --- |
| 手机端背景 | `#F2F2F7` | 窗口之外 |
| 替身窗口边框 | `#CD7222` | `systemOrange` @0.8，**定位锚点** |
| 替身窗口底色 | `#000001` | `.black` |
| 幕墙底板 | `#020205` | 半透 0.58 叠在黑上 → 需 `TOL=1` 才能与上一行分开 |
| 卡片 / hero | 渐变，各卡色相不同 | 卡片标题栏为深色 |
| 星海 | 近黑 + 白/蓝星点 | 星点是唯一的亮像素 |

---

## 六、一轮完整流程（可复制）

```bash
cd /Users/jove/Developments/ExternaldisplayDemo
DEV=65E2C3C1-9BDA-49A7-907F-C05AF893D6B6
BID=com.jove.externaldisplaydemo
APP=.scratch/DerivedData/Build/Products/Debug-iphonesimulator/ExternalDisplayDemo.app

# 0. 工具（.scratch 已 gitignore，换机器要重建）
swiftc -O .scratch/tools/crop.swift  -o .scratch/tools/crop
swiftc -O .scratch/tools/probe.swift -o .scratch/tools/probe

# 1. 构建 + 安装 + 冷启动
xcodebuild -project ExternalDisplayDemo.xcodeproj -scheme ExternalDisplayDemo \
    -configuration Debug -destination "platform=iOS Simulator,id=$DEV" \
    -derivedDataPath .scratch/DerivedData build 2>&1 | tail -5
xcrun simctl install $DEV "$APP"

# 2. 逐状态截图
mkdir -p .scratch/shots
for spec in "g0:" "gLatR:lateral=1" "gLatL:lateral=-1" "gBot:bottom=1" "gPull:pull=1"; do
  name="${spec%%:*}"; state="${spec#*:}"
  if [ -n "$state" ]; then
    xcrun simctl launch --terminate-running-process $DEV $BID \
        -mockExternalDisplay -dockState=expanded -remoteState "$state" >/dev/null 2>&1
  else
    xcrun simctl launch --terminate-running-process $DEV $BID \
        -mockExternalDisplay -dockState=expanded >/dev/null 2>&1
  fi
  sleep 3
  xcrun simctl io $DEV screenshot ".scratch/shots/$name.png" >/dev/null 2>&1
  echo "shot $name [${state:-静止}]"
done

# 3. 裁切
for n in g0 gLatR gLatL gBot gPull; do
  .scratch/tools/crop ".scratch/shots/$n.png" ".scratch/shots/c-$n.png" 30 352 1146 670 1 >/dev/null
done

# 4. 判读（核边界必须 TOL=1）
PROBE_TOL=1 .scratch/tools/probe .scratch/shots/gBot.png column 603 380 1080
```

**两个踩过的坑**：

- **zsh 不做无引号参数分词。** 写 `for p in "603 900" ...; do probe x px $p; done` 会把
  `603 900` 当成**一个**参数传进去 → 报「未知模式」。要逐条显式调用，或用 `${=p}` 强制分词。
- **改完代码截图「看起来没变化」时，先排除「构建没生效」。** 比对模拟器容器内的二进制与
  构建产物的 md5，比看截图猜可靠得多：
  ```bash
  xcrun simctl get_app_container $DEV $BID app   # 容器路径
  md5 <容器>/ExternalDisplayDemo .scratch/DerivedData/Build/Products/Debug-iphonesimulator/ExternalDisplayDemo.app/ExternalDisplayDemo
  ```

---

## 七、能截到什么、截不到什么

| | 内容 | 为什么 |
| --- | --- | --- |
| ✅ | 任何由 `RemoteControl` 状态驱动的渲染 | 状态可预置 → 渲染可复现 → 可截图 |
| ✅ | 幕墙位移（四向）、圆角、半透材质、星海、光标、选中/悬浮态、返回按钮 | 同上 |
| ✅ | 布局变更的前后对比 | 同一 `-remoteState` 下两次构建各截一张 |
| ❌ | **触摸输入**（「手指按住 → 产生什么动作」） | `simctl` 无触摸注入 API；本机 Xcode 精简安装，模拟器 GUI 也起不来。这半条只能手点，或喂事件给纯状态机断言 |
| ❌ | **真机 + 真外接屏的内容** | 渲染在另一块 `UIScreen` 上，两条截图命令都只抓手机屏；本工程未实现应用内快照 |
| ❌ | **真实外接屏的分辨率/色彩表现** | 替身窗口的 `scale` 是**硬编码 3**（`MockExternalDisplay.swift:42`），上报的分辨率是伪造的 |
| ❌ | **外接屏上的实际帧率** | 替身窗口与手机 UI 共用同一个渲染面，测不出真实外接屏的预算 |

---

## 八、这套方案的边界与遗留

1. **替身窗口是手机 scene 上的普通 window**，与手机端 UI 抢同一块屏。
   所以遥控台必须主动上报自己的高度（`reserveBottom(_:)`），窗口据此避让 ——
   写死常数已经出过一次事（切到空鼠栏时切换器被盖住）。
2. **`.scratch/` 已 gitignore**，`crop` / `probe` **不在仓库里**。
   换机器或清理后按第六节第 0 步重建；工具源码很短，见 `.scratch/tools/*.swift`。
3. **如果将来要截真机外接屏**，只有一条路：在应用内对**外接屏那个 window** 做
   `drawHierarchy(in:afterScreenUpdates:)` 再导出。这条路本工程没走 ——
   它要求 app 侧有截图入口，而外接屏窗口的持有者是 `ExternalDisplaySceneDelegate`
   或 scene accessory，两条路径的持有者不同，需要先统一。

---

## 相关文档

- [`mock-external-display.md`](mock-external-display.md) —— 替身窗口本身怎么挂（本文的前置）
- [`scroll-feel.md`](scroll-feel.md) —— 纵向滚动的手感来源
- [`specs/glass-wall-gesture.md`](specs/glass-wall-gesture.md) —— 幕墙手势的需求与决策
- [`devnotes/2026-09-24-glass-wall-material-back.md`](devnotes/2026-09-24-glass-wall-material-back.md)
  —— 用了本文的探针做像素级复核，含 `PROBE_TOL` 那次误判的完整记录
