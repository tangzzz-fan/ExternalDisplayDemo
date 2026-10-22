# ExternalDisplayDemo

验证「iOS 17 起接入外部显示器（external display）」的最小可运行工程。

只做三件事：**屏幕怎么连上**、**手机端手势怎么驱动它**、**怎么把手机屏录下来再放回去**
（手机端播 HTML → ReplayKit 采集 → 外接屏实时预览 / 回放成片）。外接屏上没有业务内容 ——
一块图案画布、一个光标环、一行读数、三段演示页。要往里加东西的，先读第七节。

- Deployment target：**iOS 17.0**
- Bundle ID：`com.jove.externaldisplaydemo`
- 手机端与外接屏均为 SwiftUI，接入层为 UIKit（scene + window）
- 28 个源文件

---

## 一、结论先行：external display 的 API 现状

接入 external display 只有一条正确路径 —— **scene**。`UIScreen` 那一套已经全部废弃：

| 能力 | API | 可用区间 | 状态 |
| --- | --- | --- | --- |
| 屏幕列表 | `UIScreen.screens` | iOS 3.2 – 16.0 | ❌ iOS 16 弃用 |
| 接入 / 拔出通知 | `UIScreen.didConnectNotification` / `didDisconnectNotification` | iOS 3.2 – 16.0 | ❌ iOS 16 弃用 |
| 主屏 | `UIScreen.main` | iOS 2.0 – 26.0 | ❌ iOS 26 弃用 |
| **外接屏 scene role** | `UISceneSession.Role.windowExternalDisplayNonInteractive` | **iOS 16.0+** | ✅ 唯一正解 |
| 旧 role | `.windowExternalDisplay` | iOS 13.0 – 16.0 | ❌ 已废弃，被上面那个取代 |
| 屏幕信息（外接屏） | `windowScene.screen.nativeBounds` / `.nativeScale` | iOS 13+ | ⚠️ 只有 iOS 17~26 路径可达；iOS 27 的 SwiftUI accessory 内容没有 `windowScene`，只能自己量 |
| 自动连接 scene | 仅在 Info.plist 声明 role | iOS 16 – 26 | ⚠️ **iOS 27 起失效** |
| **主动注册 scene** | SwiftUI：`View.sceneAccessory { ExternalNonInteractiveAccessory { … } }`（本工程用这条）<br>UIKit：`UIViewController.registerSceneAccessory(_:)` + `UISceneAccessory` | **iOS 27.0+** | ✅ **iOS 27 起必须注册**（二选一） |

### 最关键的一条

> Apple 文档 *Presenting content on a connected display*：
> "Beginning in iOS 27, your app receives a scene with the `windowExternalDisplayNonInteractive`
> role only after it registers a scene accessory. In earlier releases, the system connected this
> scene automatically."

也就是：

- **iOS 17 ~ 26**：Info.plist 里声明了 role，插上屏系统就自动送 scene 过来。
- **iOS 27 起**：光声明 plist 不够，必须注册 scene accessory（SwiftUI 声明式或 UIKit 主动调），否则系统根本不会连这个 scene。

**失败表现**：外接屏上只是把手机画面镜像过去（竖屏 letterbox 在大屏中央），**没有报错、没有日志**。
这类"静默失败"是排查 external display 时最耗时的一种，所以本工程把两条路径都实现了。

---

## 二、三步接法

### 1. Info.plist 声明 scene manifest

`Support/Info.plist`：

```
UIApplicationSceneManifest
├── UIApplicationSupportsMultipleScenes = YES      ← 必须，否则不分配外接屏 session
└── UISceneConfigurations
    ├── UIWindowSceneSessionRoleApplication                          → 空壳条目（可有可无，见下）
    └── UIWindowSceneSessionRoleExternalDisplayNonInteractive        → ExternalDisplaySceneDelegate
                                                                       （仅 iOS 17~26 生效）
```

三个易错点：

- **真正必需的是 external role 那一条**，它是 iOS 17~26「plist 自动连接外接屏」的唯一声明处。
  但它**只够 iOS 17~26 用** —— iOS 27 起还必须做第 3 步的 accessory 注册，光有声明只会镜像。
  application role 那条只是本项目保留下来的惰性占位：
  **实测（iOS 27）删掉它、甚至把整块 `UISceneConfigurations` 删掉，SwiftUI 都照常启动**，
  详见第六节。
- `UISceneDelegateClassName` 必须**模块限定**：`$(PRODUCT_MODULE_NAME).ExternalDisplaySceneDelegate`。
  写错的表现和上面一样 —— 静默镜像。用 `plutil -p` 检查构建产物里的 Info.plist 确认展开正确。
- **不要**设置 `UIRequiresFullScreen = YES`。iPhone 上这个键会让应用直接失去外部显示器能力。

### 2. 实现外接屏 scene delegate（**仅 iOS 17~26 会走到**）

见 `Sources/ExternalDisplay/ExternalDisplaySceneDelegate.swift`：

```swift
func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
           options connectionOptions: UIScene.ConnectionOptions) {
    guard session.role == .windowExternalDisplayNonInteractive,
          let windowScene = scene as? UIWindowScene else { return }

    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = UIHostingController(rootView: ExternalDisplayRootView())
    window.isHidden = false          // 不要 makeKeyAndVisible()
    self.window = window
}

func sceneDidDisconnect(_ scene: UIScene) { window = nil }
```

为什么不用 `makeKeyAndVisible()`：外接屏窗口不该从手机屏抢走 key 状态，
否则手机端第一响应者 / 键盘焦点可能被打断。只设 `isHidden = false` 即可显示。

> **iOS 27 起这个方法不会被调用** —— 那条路在第 3 步，由 scene accessory 交给 SwiftUI
> 直接呈现，不经过任何 scene delegate。两步**互不冲突**：各管一个系统版本区间，
> 渲染的是同一份 `ExternalDisplayRootView`（所以它自己量分辨率，见第 3 步）。

### 3. iOS 27+：注册 scene accessory

本工程走 **SwiftUI 原生**那条，见 `Sources/ExternalDisplay/ExternalDisplayAccessory.swift`
（`.externalDisplaySceneAccessory()` 挂在 `WindowGroup` 的根视图上）：

```swift
if #available(iOS 27.0, *) {
    content.sceneAccessory {
        ExternalNonInteractiveAccessory {
            ExternalDisplayRootView(onMetricsChange: report)
        }
        .onAvailabilityChange { isAvailable in
            ExternalDisplayMonitor.shared.setAccessoryAvailable(isAvailable)
        }
    }
} else {
    content      // iOS 17~26：由 Info.plist 的 external role 自动连接
}
```

要点：

- **不需要宿主 VC**。UIKit 那条路（`UIViewController.registerSceneAccessory(_:)`）的语义是
  「随该 VC 的呈现状态生效」，于是必须凑一个真实存在于视图层级里的控制器；
  声明式写法由系统决定何时呈现，没有这个前置条件。
- **不需要自己强引用注册句柄**（UIKit 那条路返回的 `UISceneAccessoryRegistration` 一松手就失效）。
- `sceneAccessory` 标了 `@available(iOS 27.0, *)`，而本 target 的 deployment target 是 17.0，
  所以必须包在 `if #available` 里。
- `onAvailabilityChange` 是**唯一**能在无硬件时确认「注册被系统接受」的可观测信号：
  没有外接屏时它会被回调一次 `false`（本工程在 DEBUG 下把它打到了控制台）。
- 纯 SwiftUI 路径拿不到 `windowScene`（没有 scene delegate 就没有），所以分辨率由外接屏那份
  内容自己量（视口点数 × `displayScale`）后回报给 `ExternalDisplayMonitor`。

<details>
<summary>UIKit 那条路的等价写法（本工程不用，留作对照）</summary>

```swift
if #available(iOS 27.0, *) {
    let configuration = UISceneConfiguration(
        name: ExternalDisplaySceneDelegate.configurationName,
        sessionRole: .windowExternalDisplayNonInteractive
    )
    configuration.delegateClass = ExternalDisplaySceneDelegate.self

    let accessory = UISceneAccessory.externalNonInteractive(sceneConfiguration: configuration)
    sceneAccessoryRegistration = registerSceneAccessory(accessory)   // 句柄必须强引用住
}
```

它的额外能力：能拿到 `windowScene.screen.nativeBounds` 这类屏参、能自定义
`UIWindowSceneDelegate`、要传业务上下文可以用
`externalNonInteractive(sceneConfiguration:userInfo:)` 并在 delegate 里读
`connectionOptions.sceneAccessoryUserInfo`；要临时关掉可调 `unregisterSceneAccessory(_:)`
或把 `registration.isEnabled` 置 false。**需要这些就用它**。

</details>

---

## 三、工程结构

```
ExternaldisplayDemo/
├── project.yml                                    XcodeGen 配置（XcodeGen 2.46+）
├── Support/Info.plist                             scene manifest 在这里
├── Resources/VideoPage/                           demo 站点：文字 + 视频，播放键触发录屏
├── docs/
│   ├── recording-pipeline.md                      ★ 录屏链路（HTML → 采集 → 落盘/预览）的坑
│   ├── mock-external-display.md                   -mockExternalDisplay 的原理
│   ├── external-display-screenshot.md             外接屏内容怎么截图（搬移→抓屏→裁切→探针）
│   ├── scroll-feel.md                             上下滑动为什么跟手（体感角度）
│   ├── porting-to-jove-view.md                    全景线迁到 jove-view 的完整手册（历史，对应已归档代码）
│   ├── devnotes/                                  分支级实验记录
│   └── legacy/                                    已删除业务的文档归档，见第八节
└── Sources/
    ├── App/
    │   ├── ExternalDisplayDemoApp.swift           @main（SwiftUI App）+ accessory 声明
    │   ├── PhoneRootView.swift                    状态栏 + 整块手势面
    │   ├── GesturePad.swift                       ★ 手势采集面
    │   └── TouchSurface.swift                     ★ UIKit 触摸层（唯一能读到手指数量的地方）
    ├── Core/
    │   ├── ExternalDisplayMonitor.swift           连接状态记录（@Observable，三个数据源）
    │   ├── DisplayContentStore.swift              共享内容状态（「显示什么」）
    │   ├── RemoteControl.swift                    共享交互状态（「怎么看」）
    │   └── PadGesture.swift                       ★ 手势状态机（纯逻辑，可独立断言）
    ├── ExternalDisplay/
    │   ├── ExternalDisplayAccessory.swift         ★ iOS 27 的 scene accessory 声明（纯 SwiftUI）
    │   ├── ExternalDisplaySceneDelegate.swift     ★ iOS 17~26 的接入落点
    │   ├── ExternalDisplayRootView.swift          外接屏根视图（纯输出，无手势，自测量分辨率）
    │   ├── DisplayPatternCanvas.swift             逐帧渲染验证
    │   ├── DisplayScrollGeometry.swift            滚动 / 过卷几何 + 手感曲线（纯计算）
    │   ├── GlassesLauncherCard.swift              按钮页：标题 / 按钮 / 状态与错误
    │   ├── LivePreviewView.swift                  ★ AVSampleBufferDisplayLayer 承载实时帧
    │   └── RecordedVideoView.swift                ★ AVPlayerLooper 循环回放成片
    ├── Flow/                                      ★ 录屏链路，见 docs/recording-pipeline.md
    │   ├── DemoFlow.swift                         三段状态机（launcher / capture / playback）
    │   ├── CaptureScreenView.swift                手机端全屏站点页（播放键在页面里，无原生按钮）
    │   ├── VideoPageController.swift              页面事件桥（ready / playrequest / started / ended）
    │   ├── ScreenCapture.swift                    ReplayKit 采集（真机）
    │   ├── SimulatedCapture.swift                 模拟器的替身帧源（只喂预览，不产出文件）
    │   ├── RecordingWriter.swift                  采样 → mp4（AVAssetWriter）
    │   ├── LivePreviewRelay.swift                 采样 → 外接屏显示层（跨线程中继）
    │   ├── PageAudio.swift                        进程内播声音（WKWebView 的音 ReplayKit 采不到）
    │   └── GlassesLauncherLayout.swift            按钮命中判定（归一化矩形，手机侧算）
    └── Debug/
        ├── MockExternalDisplay.swift              模拟器替身（不参与真机链路）
        ├── MockRemoteState.swift                  从启动参数预置视口状态，供截图验证
        └── MockDemoFlow.swift                     从启动参数跑一遍演示流程，供截图验证
```

`DisplayScrollGeometry` 与 `PadGesture` **只依赖 `CoreGraphics` / `Foundation`**，
不认识 SwiftUI —— 这是刻意设计的：`simctl` 没有触摸注入 API，
「手势 → 状态」只能手点，但「状态 → 位移」这半条可以真正断言。

数据流：手机端手势面 → `RemoteControl` → 外接屏 `ExternalDisplayRootView` 自动重绘。
两侧是**同一进程内的两个 UIScene，共享内存**，不需要任何跨进程通道。

内容与交互拆成两份状态，各自职责单一；录屏这条链路另有一份自己的流程状态：

| 状态 | 回答的问题 | 写入方 | 读取方 |
| --- | --- | --- | --- |
| `DisplayContentStore` | 外接屏**显示什么** | 入口 / 调试参数 | `ExternalDisplayRootView` |
| `RemoteControl` | 外接屏**怎么看**（滚动 / 过卷 / 缩放 / 光标） | `GesturePad` | `ExternalDisplayRootView` |
| `DemoFlow` | 演到**哪一步**、成片在哪 | 手机端手势面 / 页面事件 | `ExternalDisplayRootView`、`PhoneRootView` |

---

## 四、交互：外接屏收不到触摸，怎么办

**结论：外接屏自己不能滚动，也不接受任何手势。** 两个独立原因，任一条都足以让它失效：

1. **role 本身就是非交互的**。`windowExternalDisplayNonInteractive` 明确不接收触摸，
   `ExternalDisplaySceneDelegate` 里的 `window.isUserInteractionEnabled = false` 只是把语义写出来。
2. **模拟器 mock 同样收不到**。`PassthroughWindow.hitTest` 恒返回 `nil`，触摸全部穿透到下层窗口。

所以在外接屏的视图树里加 `ScrollView` 或 `.gesture` 是**无效的** —— 手势根本到不了那里。
外接屏是纯输出设备，一切输入都必须从手机侧中继。

```
   手机端手势                   共享状态                    外接屏渲染
GesturePad           ──写──▶   RemoteControl    ──读──▶  ExternalDisplayRootView
  TouchSurface（UIKit）         scroll / pull /          .offset(y:)
  MagnifyGesture                bottomPull / zoom        .scaleEffect()
                                pointer / tapCount       laser cursor
```

| 手势 | 手机端采集 | 外接屏响应 |
| --- | --- | --- |
| **单指移动** | `TouchSurface`，落点即时映射 | 橙色光标环跟手移动，**画面不动** |
| **双指上下滑动** | 同上，取两指**质心**的逐帧位移 | 画布按主轴位移：滚动 / 下拉 / 上拉 |
| 继续下拉 / 上拉 | 越过两端后转成 `pull` / `bottomPull` | 画布整体下移 / 上移，露出底层 |
| 单指轻点 | 位移未越过 slop（8pt）且**全程只有一根手指** | 涟漪 |
| 双指捏合 | `MagnifyGesture` | 画布 `.scaleEffect(zoom)` |

> **主轴锁定**：首次越过 slop 的那一帧定下本次会话的轴（横 / 竖），另一轴整段不出动作。
> 横向这条轴在外接屏上**没有落点**（屏幕背后没有第二层内容可露），所以横滑不产生任何位移。
> 指数中途变化（双指 ↔ 单指）会重设基准并当帧零位移，否则质心那一跳会被当成一次大位移。

> 触控板把**单指留给光标、双指留给滚动** —— 两种意图各占一种指数，不靠位移方向去猜。

### 触摸层：`TouchSurface` 读手指，`PadGesture` 判意图

```
按下 ──┬─ 位移没越过 slop（8pt）就抬起 ──▶ 轻点：点击确认
       └─ 位移越过 slop ──────────────▶ 拖动：开始滚动
```

采集由 `TouchSurface` 那块**透明的 UIKit 视图**做，判定逻辑全在 `PadGesture` 这个**纯状态机**里。

#### 为什么手势层落在 UIKit

SwiftUI 在 iOS 17 上**拿不到手指数量**：

| 手势 | 拿得到 | 拿不到 |
| --- | --- | --- |
| `DragGesture` | 第 1 指的累计位移 + 落点 | **手指数量** |
| `MagnifyGesture` | 两指间距比 | 质心平移 |
| `SpatialEventGesture` | 多指事件流 | **要 iOS 18+**，本工程 target 17.0 |

而"单指移光标 / 双指滚画面"唯一的分辨依据就是手指数量，所以这一层只能自己读
`touchesBegan/Moved/Ended`。

`TouchCaptureView.isMultipleTouchEnabled` 是那块视图里**最要命的一行**：
默认 `false` 时 UIKit 只投递第一根手指，症状与 SwiftUI 的 `DragGesture` 一模一样，
而且不会报任何错 —— 少了它，整个文件白写。

上报用 `event.allTouches` 而不是回调参数里的那个集合：参数只带**本次变化**的手指，
而状态机要的是"现在一共几根"。

#### 五个容易写错的点

- **slop 内的位移必须被吃掉，不能补发**。不补发是"起手不跳"的前提。
- **逐帧增量用相邻两个锚点之差**。拿"从按下到现在的总位移"当增量，滚动速度会随拖拽时长线性放大。
- **指数一变，那一帧整个吃掉**。两指变一指时锚点会从**质心跳到剩下那根手指**（实测 +40pt）。
- **多指会话整段关掉光标与轻点**，判据是"本会话出现过的**最多**指数"而不是当前指数。
- **只取纵向分量，但横向分量不拦截**。斜着划照样能滚，只是横向那段不产生位移。

还有一条防误触：轻点要求按下时长 ≤ 0.4s。

其余实现要点：

- **存归一化值，不存像素位移**。外接屏可能是 1080p / 4K / 模拟器里 362×203pt 的 letterbox
  小窗口，尺寸差一个数量级。`RemoteControl.scroll` 存 `0...1` 的进度，外接屏侧用
  `ScrollMetrics` 按自身内容高度换算实际位移，同一份手机端状态在哪块屏上都成立。
- **滚动与下拉是同一个标量的两段**：`position < 0` 是下拉、`0...1` 是滚动、`> 1` 是上拉。
  拆成三个可独立写的存储属性的话，过卷时被阻尼吃掉的那部分行程，在回拉时会变成
  凭空多出来的滚动 —— 手指一松内容就跳。
- **`.frame()` 不指定对齐会居中**。内容比视口高时，`.frame(width:height:)` 默认居中会
  把内容上移半个差值 —— 表现是「滚动起点就少了一截」。必须写 `alignment: .topLeading`。

---

## 五、运行

### 生成工程

```sh
xcodegen generate
open ExternalDisplayDemo.xcodeproj
```

**新增 / 删除源文件后必须先 `xcodegen generate`**，否则文件不进编译集，
而 `xcodebuild` 依然报 `BUILD SUCCEEDED` —— 是静默跳过的假阳性。
判据：查 `DerivedData/**/Objects-normal/*.o` 里有没有那个文件。

### 模拟器（无需硬件）

模拟器**不支持**外接显示器，`windowExternalDisplayNonInteractive` 的 scene 永远不会被创建。
因此工程内置了 `-mockExternalDisplay` 启动参数（已挂在 scheme 里，默认关闭，勾上即可）：

它会在手机屏 scene 上叠一个 16:9 的 letterbox 窗口，挂载**与外接屏完全相同**的
`ExternalDisplayRootView`，同时登记为 `source == .mock` 的 attachment。
手机端状态栏右侧会多出一个按钮，可随时收起它。

该窗口是 `PassthroughWindow`（`hitTest` 恒返回 `nil`），触摸会穿透到下层窗口，
所以**不收起它也能正常操作手势面**。

可选参数：`-mockExternalDisplayAspect=4:3`（或写成 `-mockExternalDisplayAspect 4:3`）改宽高比。

### 真机

| 方式 | 说明 |
| --- | --- |
| USB-C / Lightning 转 HDMI·DP 适配器 | 最确定的路径。四路都支持 4K60 |
| AirPlay 到 Apple TV / 支持 AirPlay 的电视 | 应用声明并注册了 role 之后，外接屏 scene 会**顶替**系统镜像 |
| iPad 台前调度 + M1 及以上 + 外键鼠 | 走的是 interactive 路径，本 demo 未覆盖 |

#### 覆盖安装会黑屏（必须知道）

改掉某个 role 的 `UISceneDelegateClassName`（尤其是删掉那个委托类）之后覆盖安装：
系统恢复上一次安装持久化下来的 `UISceneSession`，里面**存着旧委托类**；旧类已经不在
二进制里 → 该 role 拿不到可用委托 → **启动屏白屏转纯黑屏**，进程存活、不崩溃、**零日志**。
**覆盖安装不会自愈，必须卸载重装。**

级联效应：手机端 app scene 挂掉会掐死外接屏那条路（根视图不出现 → 没有 accessory →
iOS 27 系统根本不给外接屏 scene → 只剩镜像）。所以「外接屏白转黑」和「手机白转黑」
很可能是**同一个根因**，先看手机屏。

---

## 六、踩坑清单

1. **`UIRequiresFullScreen = YES`** → iPhone 直接失去外部显示器能力。
2. **`UIApplicationSupportsMultipleScenes` 忘了开** → 系统不分配外接屏 session。
3. **`UISceneDelegateClassName` 没写模块前缀** → 静默镜像，无任何日志。用 `plutil -p` 验证。
4. **iOS 27+ 只声明 plist 不注册 accessory** → 静默镜像。
5. **用 `UIScreen.screens` / `didConnectNotification`** → 在 iOS 16+ 上编译告警、行为不可靠；
   iOS 26 起连 `UIScreen.main` 也弃用了。屏幕信息一律从 `windowScene.screen` 取。
6. **外接屏窗口调 `makeKeyAndVisible()`** → 抢走手机屏的 key 状态。
7. **忘了在 `sceneDidDisconnect` 释放 window** → 残留无人持有的渲染面。
8. 模拟器里 `UIScreen.screens` 永远只有主屏 —— 这是模拟器限制，不是代码问题。
9. **在外接屏视图上加 `ScrollView` / `.gesture`** → 永远不触发。role 非交互，手势到不了
   那棵视图树；必须从手机侧中继（见第四节）。
10. **滚动内容的 `.frame` 没写 `alignment: .topLeading`** → 内容比视口高时会被居中，
    表现是「滚动起点凭空少了一截」，且滚到底也差一截。
11. **把带手势采集的视图放进 `Form` / `ScrollView`** → 与外层滚动视图的竖向 pan 手势竞争。
    SwiftUI 的 `DragGesture` 没 API 能压过祖先 `ScrollView`；
    换成 UIKit 触摸层更糟 —— 祖先的 pan 识别器会给采集视图发 `touchesCancelled`
    （表现是拖动中途突然停住）。必须挂到滚动区域之外。
12. **让浮层窗口与底部常驻 UI 抢位置** → 替身窗口在 `.normal + 1` 层永远盖住主窗口。
    本工程已把底部面板收掉，只留整块手势面，这条对现在的布局不成立；换回
    「表单 + 底部遥控台」结构时它立刻回来。
13. ~~**SwiftUI `App` 生命周期下，把 `UIWindowSceneSessionRoleApplication` 从
    `UISceneConfigurations` 里删掉** → app scene 连不上，纯黑屏、零日志。~~
    **这条已实测推翻**：`UISceneConfigurations` 整块在 SwiftUI 生命周期下都不是必需的，
    application role 的空壳条目可有可无。当时看到的黑屏是第 14 条那类持久化会话问题。
14. **改掉某个 role 的 `UISceneDelegateClassName` 之后覆盖安装** → 黑屏，卸载重装才恢复
    （见第五节）。
15. **`TouchCaptureView` 忘了 `isMultipleTouchEnabled = true`** → UIKit 默认只投递
    **第一根**手指，双指滑动永远进不来。症状与「根本没写手势」一模一样，且不报任何错。
16. **读取触摸时用回调参数而不是 `event.allTouches`** → 回调参数只带**本次变化**的手指。
    第二根手指落下时参数里只有它自己，状态机会误判成单指。
17. **指数变化时不重设锚点** → 两指变一指时锚点会从质心跳到剩下那根手指（实测 +40pt），
    那一跳会被滚出去或把光标拽走。凡是"参考点会因状态切换而跳变"的地方，
    切换那一帧都必须**吃掉、不补发**。
18. **给 `@Observable` 类的默认参数写 `.shared`** → 默认参数表达式在**调用方**上下文求值，
    触发「main actor-isolated property can not be referenced from a nonisolated context」告警。
    改成 `= nil` 再在函数体里解析。
19. **把有分支的判定逻辑留在视图里** → 它就成了**永久验证盲区**。判据很简单：
    这段逻辑有没有 `if`？有的话就该问一句"它能不能被断言"。
20. **把"可断言"当成"已验证"** → 断言只能覆盖喂进去的那段纯逻辑；
    「触摸到底有没有被 UIKit 收到」不在这段里。换触摸层这类改动，
    纯逻辑全绿**不等于**功能可用，必须另外手点一遍。
21. **`DisplayPatternCanvas` 这类 `TimelineView` + `Canvas` 的视图不吃"比父级更大"的 frame** →
    想靠"画布比视口宽"来做横向位移时，`Canvas` 仍按父级建议的尺寸绘制，
    结果推开之后露出的是黑边。要么让背景层有真实内容可露，要么不做这条轴。

---

## 七、迁到真实项目

- **换成视频/Metal 渲染**：把 `DisplayPatternCanvas` 的 `Canvas` 换成承载 `MTKView` /
  `AVPlayerLayer` 的 `UIViewRepresentable`。scene 接入层（`ExternalDisplaySceneDelegate`
  与 Info.plist）**不需要任何改动**。
- **多块外接屏**：`ExternalDisplayMonitor.attachments` 已按 `session.persistentIdentifier`
  区分，为每块屏各建一个 window 即可。
- **只在部分页面投屏**：把注册/注销跟着页面生命周期走
  （`registerSceneAccessory` / `unregisterSceneAccessory`）。
- **外接屏要能交互**：非交互 role 下只能走手机侧中继（`GesturePad` + `RemoteControl`）。
  真需要外接屏自己接收触摸，得改用 iPad 台前调度那条 interactive 路径。
- **加一页内容**：只改 `ExternalDisplayRootView` 的分支与 `RemoteControl` 的落点，
  接入层一行都不用动。先问一句：**这一页里指针还在动吗？** 不在，就得另开一个
  不依赖指针的入口 —— 非交互屏上任何"点得到的东西"都靠手机侧送过来的光标。
- **本 demo 刻意没做的**：交互式外接屏（iPad 台前调度把应用窗口搬到外接屏）、
  自定义分辨率协商、把音频路由到外接屏（声音只在手机侧播，见
  `docs/recording-pipeline.md` 第七节）。

---

## 八、归档

这个工程在 2026-09-24 ~ 09-28 之间堆过一整套演示业务：瀑布流幕墙、星海穹顶、
照片详情页、全景（equirect / 柱面）浏览、空鼠（CoreMotion 激光指针）。
2026-10-22 按「只留一个手势面 + 一个简洁外接屏页面」收敛掉了：

- 源码：`git log --oneline -- Sources` 里能看到删除那一次提交，文件全部可从历史取回；
- 文档：`docs/legacy/` 是那批业务的说明与 devnotes，**只作历史参考**，
  其中的文件名与类型在现在的代码里已经不存在；
- `docs/porting-to-jove-view.md` 保留在 `docs/` 下 —— 全景线已经移植到 jove-view，
  那份手册是那次移植的记录，不随本工程的代码变化而失效。
