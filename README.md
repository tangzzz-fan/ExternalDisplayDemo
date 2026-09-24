# ExternalDisplayDemo

验证「iOS 17 起接入外部显示器（external display）」的最小可运行工程。
只做接入：屏幕怎么连上、内容怎么送上去、拔掉怎么收尾。业务渲染只有一个图案画布。

- Deployment target：**iOS 17.0**
- Bundle ID：`com.jove.externaldisplaydemo`
- 手机端与外接屏均为 SwiftUI，接入层为 UIKit（scene + window）

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
  详见第八节的对照表。

  本项目当前保留一个空壳条目：

  ```xml
  <key>UIWindowSceneSessionRoleApplication</key>
  <array>
    <dict>
      <key>UISceneConfigurationName</key>
      <string>Phone Scene</string>
    </dict>
  </array>
  ```

  它**不能**带 `UISceneDelegateClassName` —— 本项目主界面走 SwiftUI `WindowGroup`，
  scene delegate 由 SwiftUI 自己装，写上会与之冲突。

- `UISceneDelegateClassName` 必须**模块限定**：`$(PRODUCT_MODULE_NAME).ExternalDisplaySceneDelegate`。
  写错的表现和上面一样 —— 静默镜像。用 `plutil -p` 检查构建产物里的 Info.plist 确认展开正确：

  ```
  plutil -p build/.../ExternalDisplayDemo.app/Info.plist
  ```

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
  「随该 VC 的呈现状态生效」，于是必须凑一个真实存在于视图层级里的控制器、还要担心它有没有
  真的在呈现；声明式写法由系统决定何时呈现，没有这个前置条件。
- **不需要自己强引用注册句柄**（UIKit 那条路返回的 `UISceneAccessoryRegistration` 一松手就失效）。
- `sceneAccessory` 标了 `@available(iOS 27.0, *)`，而本 target 的 deployment target 是 17.0，
  所以必须包在 `if #available` 里 —— 注意 `ViewModifier.body` 的两个分支能直接这样写。
- `onAvailabilityChange` 是**唯一**能在无硬件时确认「注册被系统接受」的可观测信号：
  没有外接屏时它会被回调一次 `false`（本工程在 DEBUG 下把它打到了控制台）。
- 纯 SwiftUI 路径拿不到 `windowScene`（没有 scene delegate 就没有），所以分辨率由外接屏那份
  内容自己量（视口点数 × `displayScale`）后回报给 `ExternalDisplayMonitor`。

<details>
<summary>UIKit 那条路的等价写法（本工程不用，留作对照）</summary>

```swift
if #available(iOS 27.0, *) {
    let configuration = UISceneConfiguration(
        name: ExternalDisplaySceneDelegate.configurationName,   // 与 plist 中的名字一致
        sessionRole: .windowExternalDisplayNonInteractive
    )
    configuration.delegateClass = ExternalDisplaySceneDelegate.self  // 同时显式指定，双保险

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
├── docs/
│   ├── mock-external-display.md                   -mockExternalDisplay 的原理（可发布）
│   └── devnotes/                                  分支级实验记录
│       ├── 2026-09-22-swiftui-scene-accessory.md  scene accessory 改造
│       ├── 2026-09-24-waterfall-starfield.md      瀑布流 + 下拉露背景墙 + 星海假 3D
│       └── 2026-09-24-airmouse-gesture.md         空鼠手势：上下滑动 + 单指点击确认
└── Sources/
    ├── App/
    │   ├── ExternalDisplayDemoApp.swift           @main（SwiftUI App）+ accessory 声明
    │   ├── PhoneRootView.swift                    状态面板 + 推送内容控制
    │   ├── GesturePad.swift                       ★ 单指手势采集面（触控板与空鼠栏共用）
    │   ├── RemoteControlPad.swift                 手机端遥控板（触控板那一栏）
    │   ├── RemoteControlDock.swift                底部常驻遥控台（safeAreaInset 宿主）
    │   ├── AirMousePad.swift                      空鼠模式的控制面板
    │   └── AirMouseDiagnostics.swift              陀螺仪预热/可用性读数
    ├── Core/
    │   ├── ExternalDisplayMonitor.swift           连接状态记录（@Observable，三个数据源）
    │   ├── DisplayContentStore.swift              共享内容状态（「选什么」）
    │   ├── RemoteControl.swift                    共享交互状态（「怎么看」）
    │   ├── PadGesture.swift                       ★ 单指手势状态机（纯逻辑，可独立断言）
    │   ├── AirMouse.swift                         手机姿态 → 激光指针
    │   └── MotionWarmup.swift                     CoreMotion 预热与可用性判定
    ├── ExternalDisplay/
    │   ├── ExternalDisplayAccessory.swift         ★ iOS 27 的 scene accessory 声明（纯 SwiftUI）
    │   ├── ExternalDisplaySceneDelegate.swift     ★ iOS 17~26 的接入落点
    │   ├── ExternalDisplayRootView.swift          外接屏根视图（纯输出，无手势，自测量分辨率）
    │   ├── DisplayPatternCanvas.swift             逐帧渲染验证
    │   ├── WaterfallLayout.swift                  瀑布流布局 + 左右边距几何（纯计算，可独立断言）
    │   ├── WaterfallColumnView.swift              瀑布流视图（左右留白，每列完整）
    │   ├── DisplayScrollGeometry.swift            滚动/下拉几何 + 手感曲线（纯计算）
    │   ├── StarfieldModel.swift                   星表 + 透视投影（纯计算，可独立断言）
    │   └── StarfieldBackdrop.swift                星海背景墙（TimelineView + Canvas）
    └── Debug/
        ├── MockExternalDisplay.swift              模拟器替身（不参与真机链路）
        ├── MockAirMouseSource.swift               陀螺仪替身
        └── MockRemoteState.swift                  从启动参数预置视口状态，供截图验证
```

`WaterfallLayout` / `DisplayScrollGeometry` / `StarfieldModel` 三个文件**只依赖
`CoreGraphics` 与 `Foundation`**，不认识 SwiftUI —— 这是刻意设计的，见第九节。


数据流：手机端改 `DisplayContentStore` → 外接屏 `ExternalDisplayRootView` 自动重绘。
两侧是**同一进程内的两个 UIScene，共享内存**，不需要任何跨进程通道。

内容与交互拆成两份状态，各自职责单一：

| 状态 | 回答的问题 | 写入方 | 读取方 |
| --- | --- | --- | --- |
| `DisplayContentStore` | 外接屏**显示什么** | 手机端表单 | `ExternalDisplayRootView` |
| `RemoteControl` | 外接屏**怎么看**（滚动 / 缩放 / 光标） | 手机端手势采集面（`GesturePad`） | `ExternalDisplayRootView` |

---

## 四、交互：外接屏收不到触摸，怎么办

**结论：外接屏自己不能滚动，也不接受任何手势。** 两个独立原因，任一条都足以让它失效：

1. **role 本身就是非交互的**。`windowExternalDisplayNonInteractive` 明确不接收触摸，
   `ExternalDisplaySceneDelegate` 里的 `window.isUserInteractionEnabled = false` 只是把语义写出来。
2. **模拟器 mock 同样收不到**。`PassthroughWindow.hitTest` 恒返回 `nil`，触摸全部穿透到下层窗口。

所以在外接屏的视图树里加 `ScrollView` 或 `.gesture` 是**无效的** —— 手势根本到不了那里。
外接屏是纯输出设备，一切输入都必须从手机侧中继。

本工程的做法：手机端底部常驻一块遥控台，手势在手机侧采集，经 `RemoteControl`
单向送到外接屏渲染视图。遥控台上有**两块手势采集面**（触控板 / 空鼠栏，见下），
它们共用同一份判定逻辑。

```
   手机端手势                   共享状态                    外接屏渲染
GesturePad         ──写──▶   RemoteControl    ──读──▶  ExternalDisplayRootView
  DragGesture                 scroll / pull            .offset(y:)
  MagnifyGesture              pointer / tapCount       .scaleEffect()
  CoreMotion                  pointerSource            laser cursor
```

| 手势 | 手机端采集 | 外接屏响应 |
| --- | --- | --- |
| **单指上下拖动** | `DragGesture`，逐帧增量归一化。**两块 `GesturePad` 都有**（触控板 / 空鼠栏） | 内容列按 `scroll` 偏移（见第九节） |
| 单指继续下拉 | 同上，越过顶部后自动转成 `pull` | 内容整体下移，露出星海背景墙（见第九节） |
| 单指轻点 | 同上，位移未越过 slop（8pt） | 光标处扩散一次涟漪（点击确认）。空鼠栏上等同按下「扳机」 |
| 转动手机 | `CoreMotion`（`AirMouse`） | 红色激光指针 + 拖尾；同时驱动星海视差 |
| 双指捏合 | `MagnifyGesture`，**仅触控板** | hero 图案画布 `.scaleEffect(zoom)` |
| 手指落点 → 光标环 | **仅触控板**（空鼠栏 `mapsPointer: false`） | 橙色光标环 |

> 前四行是**两块采集面共有**的能力，后两行只有触控板有。
> 换句话说：**空鼠栏不是"只能轻点"** —— 它和触控板一样能上下拖动滚动、能下拉露背景墙。
> 它少的只是"手指落点当光标"和"双指捏合"，因为光标归陀螺仪、捏合与瞄准姿态无意义。

### 两块采集面，一份逻辑

触控板（`RemoteControlPad`）与空鼠栏（`AirMousePad`）各有一块 `GesturePad`，
差别只有三个参数：提示文案、高度、以及**落点要不要映射成光标**。

**滚动这条链路两块面完全一致**：上下拖动 → 逐帧增量 → `RemoteControl.scroll(by:)`，
连 slop、归一化分母、逐帧增量算法都是同一份代码。做成一个视图而不是复制两份，
就是为了让两处的手感**必然**一致 —— 复制的话迟早有一处被改了分母而另一处没跟上。

空鼠栏为什么也要能滚：空鼠的交互是「抬手瞄准 + 确认」，而确认原本只有一个「扳机」按钮。
但空鼠工作时手机是被**举起来**的，手指去够底部那个按钮既别扭、又会带歪姿态 ——
瞄准的那只手没法稳定地去点一个具体控件。所以确认必须能落在手边的任意位置。
顺带把"上下拖动滚动"也放进来，这样空鼠跑着的时候不必切回触控板那一栏。

#### 为什么手指滑动不会把激光带歪

空鼠跑着的时候，「抬手转手机 → 激光移动」和「手指在面板上上下滑 → 滚动」
是**可以同时发生**的（一只手举着转、另一只手滑）。两者不打架，靠的是一条硬约束：

```swift
GesturePad(..., mapsPointer: false, ...)   // 空鼠栏
```

`mapsPointer: false` 让这块面**只产生 `.scroll`，永不写 `RemoteControl.pointer`**；
而激光指针由 `AirMouse` 独占写入（每次调用都带 `source: .airMouse`）。
两者写的是同一个字段的两条互斥路径，谁都不会覆盖谁。

反过来说：如果空鼠栏也用默认的 `mapsPointer: true`，那么手指一碰面板
激光就会**瞬移到手指落点**，与陀螺仪的姿态控制互相抢，表现是"瞄准时激光乱跳"。
`pointerSource` 这个字段就是为这种归属问题准备的（见第五节）。

注意这个开关**只影响落点，不影响轻点** —— 断言里单独守了这条
（`mapsPointer = false 不影响轻点`）。

### 一个手势识别器同时管滚动和轻点

```
按下 ──┬─ 位移没越过 slop（8pt）就抬起 ──▶ 轻点：点击确认
       └─ 位移越过 slop ──────────────▶ 拖动：开始滚动
```

判定逻辑全在 `PadGesture`（`Sources/Core/`）这个**纯状态机**里，视图只负责转发。
三个容易写错的点：

- **slop 内的位移必须被吃掉，不能补发**。不补发是"起手不跳"的前提；
  若反过来先滚动、抬起时再补一次点击，那么每次轻点都会顺带把画面推走几个点。
- **逐帧增量必须用累计位移之差**。`DragGesture.translation` 是累计值，
  直接拿它当增量，滚动速度会随拖拽时长线性放大。
- **只取纵向分量，但横向分量不拦截**。这就是"上下滑动（左右可以）"这句需求的全部含义：
  斜着划照样能滚，只是横向那段不产生位移。若改成"只认纯竖向拖动"，
  斜拖会被判成手势失败，手感立刻变粘。

还有一条防误触：轻点要求按下时长 ≤ 0.4s。空鼠瞄准时手指自然搭在面板上很常见，
抬手时误触发一次点击比漏掉一次更让人恼火。

完整推导、四个易错点与 27 条断言清单见
[`docs/devnotes/2026-09-24-airmouse-gesture.md`](docs/devnotes/2026-09-24-airmouse-gesture.md)。

其余实现要点：

- **存归一化值，不存像素位移**。外接屏可能是 1080p / 4K / 模拟器里 362×203pt 的 letterbox
  小窗口，尺寸差一个数量级。`RemoteControl.scroll` 存 `0...1` 的进度，外接屏侧用
  `ScrollMetrics` 按自身内容高度换算实际位移，同一份手机端状态在哪块屏上都成立。
- **拖拽增量要自己算**（`MagnifyGesture` 的 `magnification` 同理，也是累计值；
  单指那一路的算法见上）。
- **滚动与下拉是同一个标量的两段**，不是两个维度。见第九节。
- **`.frame()` 不指定对齐会居中**。滚动内容高度（本工程约 446pt）远超视口（约 203pt），
  `.frame(width:height:)` 默认居中会把内容上移半个差值 —— 表现是「滚动起点就少了两条内容」。
  必须写 `alignment: .topLeading`，再靠 `.clipped()` 裁掉溢出。

> **验证边界**：`xcrun simctl` 没有触摸注入 API，Xcode 27 的模拟器 GUI（DeviceHub）也没有
> 可脚本化的设备窗口，所以「手指按下 → 产生什么动作」这条链路**曾经**完全无法自动化验证。
> 后来把手势判定抽成纯状态机 `PadGesture`（见上），这半条链路就可以喂事件断言了 ——
> 目前覆盖 slop 边界、轻点判定、逐帧增量、方向、开关与取消，共 27 条。
> 仍然只能手点的是「手势能不能被识别到」这一层（SwiftUI 的手势分发本身）。
> 「状态 → 渲染」那半条已用 `-remoteState` 预置参数逐状态截图验证过
> （`scroll = 0.62` / `zoom = 1.9` / `pointer = (0.3, 0.35)`）：可见内容恰为条目 04（顶部被切）～11，
> 光标环实测落点 `(109.5, 70.8)pt`，与计算值 `(108.6, 71.0)pt` 一致。
>
> **手势归属靠结构保证，不靠运气**。触控板最初放在 `Form` 里，它的 `DragGesture` 会与外层
> 滚动视图的竖向 pan 手势竞争 —— 而 SwiftUI **没有**能压过祖先 `ScrollView` 的公开 API
> （`highPriorityGesture` 只影响当前视图与其子视图）。现在改由 `RemoteControlDock` 经
> `.safeAreaInset(edge: .bottom)` 挂在滚动区域**之外**，归属没有歧义，
> 顺带省掉了「要先滚动才能摸到遥控板」这一步。遥控台默认收起只留读数栏，
> 展开才铺开触控板 —— 这样它和模拟外接屏窗口能同时看见。
> 遥控台自身高度会实时上报给替身窗口，让它始终避开（见第六节第 12 条）。

---

## 五、运行

### 生成工程

```sh
xcodegen generate
open ExternalDisplayDemo.xcodeproj
```

### 模拟器（无需硬件）

模拟器**不支持**外接显示器，`windowExternalDisplayNonInteractive` 的 scene 永远不会被创建。
因此工程内置了 `-mockExternalDisplay` 启动参数（已挂在 scheme 里，默认关闭，勾上即可）：

它会在手机屏 scene 上叠一个 16:9 的 letterbox 窗口，挂载**与外接屏完全相同**的
`ExternalDisplayRootView`，同时登记为 `source == .mock` 的 attachment。
手机端会多出一个「显示模拟外接屏」开关。

该窗口浮在 `.normal + 1` 层、永远盖在主窗口之上，所以它**主动避开屏幕底部 96pt**
（`letterboxedRect` 里的 `reservedBottom`）—— 那块留给常驻的遥控台，
否则展开遥控台时两者会在屏幕中段互相遮挡。

这个窗口是 `PassthroughWindow`（`hitTest` 恒返回 `nil`），触摸会穿透到下层窗口，
所以**不收起它也能正常操作表单**，只是视觉上被那块黑框盖住。

滚动 / 缩放 / 光标这些交互见第四节 —— 外接屏收不到触摸，一律由手机端的
「遥控外接屏」面板驱动。

可选参数：`-mockExternalDisplayAspect=4:3`（或写成 `-mockExternalDisplayAspect 4:3`）改宽高比。

### 真机

| 方式 | 说明 |
| --- | --- |
| USB-C / Lightning 转 HDMI·DP 适配器 | 最确定的路径。四路都支持 4K60，3D 类应用优先走这条 |
| AirPlay 到 Apple TV / 支持 AirPlay 的电视 | 应用声明并注册了 role 之后，外接屏 scene 会**顶替**系统镜像 |
| iPad 台前调度 + M1 及以上 + 外键鼠 | 走的是 interactive 路径，本 demo 未覆盖 |

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
    表现是「滚动起点凭空少了两条内容」，且滚到底也差一截。
11. **把带 `DragGesture` 的触控板放进 `Form` / `ScrollView`** → 与外层滚动视图的竖向 pan
    手势竞争，而 SwiftUI 没有能压过祖先 `ScrollView` 的公开 API。必须挂到滚动区域之外
    （`.safeAreaInset`），或换成承载 `UIPanGestureRecognizer` 的 `UIViewRepresentable`。
12. **让浮层窗口与底部常驻 UI 抢位置** → 替身窗口在 `.normal + 1` 层永远盖住主窗口，
    必须主动为底部面板预留空间（见第五节），否则展开时会遮住面板标题栏。
    **预留量必须实测，不能写死**：遥控台收起约 50pt、展开后三四百点，各栏还不一样高。
    写死的 96 在空鼠栏加上手势面之后就不够了 —— 表现是「触控板 / 空鼠」切换器被窗口盖住。
    现在由 `RemoteControlDock` 用 `GeometryReader` 实测上报，高度一变就重新摆位。
13. ~~**SwiftUI `App` 生命周期下，把 `UIWindowSceneSessionRoleApplication` 从
    `UISceneConfigurations` 里删掉** → app scene 连不上，**纯黑屏、零日志**。~~
    **这条已实测推翻**（见第八节）：`UISceneConfigurations` 整块在 SwiftUI 生命周期下都不是必需的，
    application role 的空壳条目可有可无。当时看到的黑屏是**第 14 条**那类持久化会话问题，
    与 plist 少没少那条无关。当前 plist 里保留它只是惰性选择。
14. **改掉某个 role 的 `UISceneDelegateClassName`（尤其是删掉那个委托类）之后覆盖安装** →
    系统恢复上一次安装持久化下来的 `UISceneSession`，里面**存着旧委托类**；旧类已经不在
    二进制里 → 该 role 拿不到可用委托 → **启动屏白屏转纯黑屏**，进程存活、不崩溃、**零日志**。
    **覆盖安装不会自愈**，必须卸载重装。复现与排查见第八节末。
15. **让某个子视图刻意超出父视图之后，忘了父级 `.frame` 也要 `alignment: .topLeading`** →
    与第 10 条同一类：`.frame(width:height:)` 默认**居中**，子视图比它大时会被顶掉半个差值。
    第 10 条只修了内层容器，这次把外层约束拆掉，同一个 bug 换了个层级复现。
    **这个坑与具体层级无关，只与"是否有子视图会超出父视图"有关。**
16. **布局没有遵守从几何反推出来的约束**（如「hero 高度 ≤ 视口高/2 − 内边距」）→
    表现是"下拉到底之后标题被屏幕下沿切掉半截"，看起来像渲染 bug，查错方向很容易跑偏。
    正确做法是把约束写成函数让布局直接受它约束，而不是写一条注释提醒。
17. **给 `@Observable` 类的默认参数写 `.shared`** → 默认参数表达式在**调用方**上下文求值，
    触发「main actor-isolated property can not be referenced from a nonisolated context」告警。
    改成 `= nil` 再在函数体里解析。
18. **让内容溢出父视图时没锁死父视图宽度** → 父级被子视图撑宽，
    「在屏幕边缘切开」变成「整片内容右移」。与第 10 / 15 条同源（都是"子视图超出父视图"），
    但这次问题不在**对齐**而在**尺寸**。
19. **一个内边距值兼任两个方向** → `inset` 同时当左右内边距时，
    "让内容溢出屏幕"这个需求根本写不出来（只能写负数内边距，而负数会被父级裁剪夹回来）。
    横向需求一变，竖向节奏就被迫跟着变。拆成 `.padding(.vertical, _)` + 独立的横向留白量。
20. **放宽随机区间之后，没回头检查原有的"安全边界"是否仍然成立** →
    色相抖动从 ±0.025 放宽到 ±0.045 后，锚点 `0.09` 加满抖动是 `0.135`，
    越过了刻意避开的黄绿区间（低明度下是橄榄绿），屏幕上冒出一张脏卡。
    锚点是按旧抖动挑的，抖动一放宽，"锚点够远"这个前提就失效了。
21. **稀有分支的概率没按实际条目数折算** → 「22% 的卡片被拉长」听起来够了，
    但"最终超出基础区间"还要再乘约 0.31，36 张的演示集里期望不到 2 张。
    分布断言用 400 张样本是过的，屏幕上却看不出差别。
    **概率要按实际条目数反推期望值再定。**
22. **分布类断言用了太小的样本** → 36 张卡里"中性色占比 12%"的理论值被抽成 0，
    断言亮红灯而代码完全正确。阈值要按**理论值**定，且样本量要让期望值上两位数。
23. **改动后截图"看起来没变化"时，先排除"构建没生效"** → 比对模拟器容器内二进制与
    构建产物的 md5，比看截图猜可靠得多。这次正是靠它确认了修正确实部署了，
    那张卡本来就不需要修正 —— 是缩略图上看错了颜色。
24. **把有分支的判定逻辑留在视图里** → 它就成了**永久验证盲区**。手势的
    「slop 边界 / 轻点 vs 拖动 / 逐帧增量」全是纯逻辑，但写在 `View` 里就带上了
    SwiftUI 依赖，脱离模拟器一行都断言不了。抽成 `PadGesture` 之后，
    同一段逻辑立刻可以喂事件断言（本次新增 27 条）。
    **判据很简单：这段逻辑有没有 `if`？有的话就该问一句"它能不能被断言"。**
25. **给手势加新功能时顺手改了视图结构，却没重新核对跨视图的几何假设** →
    空鼠栏加了一块手势面 → 遥控台变高 → 替身窗口按老的固定预留量摆位 →
    「触控板 / 空鼠」切换器被盖住。改动本身没问题，是**别人的常数**失效了。
    所以：凡是"某个视图的高度/宽度被别人当作常数依赖"的地方，都应该改成实测上报。

---

## 七、迁到真实项目

- **换成视频/Metal 渲染**：把 `DisplayPatternCanvas` 的 `Canvas` 换成承载 `MTKView` /
  `AVPlayerLayer` 的 `UIViewRepresentable`。scene 接入层（`ExternalDisplaySceneDelegate`
  与 Info.plist）**不需要任何改动**。
- **多块外接屏**：`ExternalDisplayMonitor.attachments` 已按 `session.persistentIdentifier`
  区分，为每块屏各建一个 window 即可。
- **只在部分页面投屏**：把注册/注销跟着页面生命周期走
  （`registerSceneAccessory` / `unregisterSceneAccessory`）。
- **外接屏要能交互**：非交互 role 下只能走手机侧中继（本工程的 `RemoteControlPad` +
  `RemoteControl`）。真需要外接屏自己接收触摸，得改用 iPad 台前调度那条 interactive 路径。
- **本 demo 刻意没做的**：交互式外接屏（iPad 台前调度把应用窗口搬到外接屏）、
  自定义分辨率协商、外接屏音频路由。

---

## 八、为什么主界面走 SwiftUI 原生生命周期

本项目最初是 `AppDelegate` + `MainSceneDelegate` + `PhoneRootViewController` 三层派发，
现已改为 SwiftUI 原生生命周期。本节记录改造范围，以及过程中最容易踩的那个坑。

### 能换掉什么、换不掉什么

| | 改造前（AppDelegate 派发） | 现在（SwiftUI App 派发） |
| --- | --- | --- |
| `@main` | `AppDelegate` | `ExternalDisplayDemoApp: App` |
| 主屏 scene | `MainSceneDelegate` | `WindowGroup` |
| 手机端 UI 宿主 | `PhoneRootViewController` | 不需要宿主 VC（SwiftUI 自己管） |
| 主屏 `UIWindowScene` 的取用 | 由 `MainSceneDelegate` 登记 | 用的人自己查 `UIApplication.shared.connectedScenes` |
| scene accessory 声明 | `PhoneRootViewController.viewDidLoad` 主动注册 | **SwiftUI 声明式**（`ExternalDisplayAccessory`） |
| 外接屏 scene（iOS 17~26） | `ExternalDisplaySceneDelegate` | **不变** |
| Info.plist external role | 声明 | **不变**（iOS 17~26 唯一声明处） |

**外接屏那一路换不掉**：SwiftUI 的 `App` / `Scene` / `WindowGroup` 只能创建
`windowApplication` role 的 scene，没有任何 API 能声明 iOS 17~26 的
`windowExternalDisplayNonInteractive`。所以「plist + scene delegate」这套到手机端为止
仍然保留；但 iOS 27 那条**已经全部是 SwiftUI 了**。

### 曾经借过的那个宿主 VC（现已删除）

改造中期曾在根视图 `.background` 挂一个零尺寸、`allowsHitTesting(false)` 的
`UIViewControllerRepresentable`（`PhoneSceneBridge`），用来补 SwiftUI 拿不到的两样东西：

1. **主屏 `UIWindowScene`** —— 只是 debug 用的 `MockExternalDisplay` 需要；
2. **`registerSceneAccessory(_:)` 的宿主** —— iOS 27 起必须在「主界面里的一个
   view controller」上注册，且返回句柄要强引用住。

这两件事后来都被消掉了：第 1 件没必要「登记」—— `UIApplication.shared.connectedScenes`
随时可查，用的人自己找就行；第 2 件改用 SwiftUI 原生 `sceneAccessory` 后根本不需要宿主 VC。
于是 `Sources/App/` 里不再有任何 `UIViewRepresentable`。

### ★ 曾经的误会：application role 那条空壳条目其实不是必需的

改造过程中曾记录：把 `UISceneConfigurations` 里的 `UIWindowSceneSessionRoleApplication`
条目删掉后应用启动**纯黑屏**（进程存活、无崩溃报告、**零 error**），于是把该条目当成必需项保留了下来。

**后续实测推翻了这条结论。** 同一台机器、iOS 27.0 模拟器，每组都先 `uninstall` 排除会话残留：

| Info.plist 形态 | 干净安装 | 覆盖安装 |
| --- | --- | --- |
| A：application 空壳条目 + external role（当前形态） | 正常 | 正常 |
| B：只留 external role（**删掉 application 条目**） | **正常** | 正常 |
| C：整块 `UISceneConfigurations` 都不写 | **正常** | 正常 |

结论：**SwiftUI 生命周期下 `UISceneConfigurations` 整块都不是必需的**，application role 那条
空壳条目更是可有可无。当时看到的黑屏与下一节是同一类问题 —— 那一刻正好把 `MainSceneDelegate`
删了，覆盖安装恢复了指向旧委托类的会话，**与 plist 里少没少那条无关**。

所以现在这个形态是「惰性保留」，不是「必须这么写」：

- application role 留一个只有 `UISceneConfigurationName` 的空壳条目 —— **无用但无害**；
- external role 那条**必须留** —— 它是 **iOS 17~26**「plist 自动连接外接屏」的唯一声明处。
  iOS 27 起这条路失效、改由 scene accessory 负责（本工程走 SwiftUI 声明式，
  见第二节第 3 步），原则上可省；但本工程 deployment target 是 17.0，所以保留。

> **仍未验证**：本机只有 iOS 27.0 运行时，变体 B/C 在 **iOS 17~26** 上是否同样正常没测过。
> 要精简 plist 的话，先去有 17~26 运行时的机器上补齐这两组验证。

### ★ 第二个坑：改了 scene 宿主后**覆盖安装**也是黑屏

改造完成、代码全部正确，模拟器也验证过了，但**真机上仍然白屏转黑屏**。同一个根因的第二种触发方式，
和上面那条互为镜像：

- **现象**：启动时先是启动屏（白），随即整屏纯黑；进程存活、不崩溃、**日志里没有任何 error**。
  同一份代码在模拟器上正常。
- **原因**：系统会把 `UISceneSession`（**含它的 `UISceneConfiguration` 与委托类**）
  **持久化在 app 的数据容器里**，下次启动直接**恢复**。改造前 application role 的委托类是
  `MainSceneDelegate`，这次改造把它删了 —— 覆盖安装后恢复出来的会话指向一个**已经不存在的类**，
  于是 app scene 没有可用委托、没有 window。**代码怎么写都救不回来。**
- **判据**：覆盖安装不会自愈。**卸载重装即恢复**，这就是结论本身。
- **模拟器 100% 复现**（不需要真机）：

  ```sh
  SIM=<已启动的模拟器 UDID>; BID=com.jove.externaldisplaydemo
  OLD=<改造前那版代码的 .app 路径>   # 需先 checkout 到改造前的 commit 构建一次
  NEW=<当前代码的 .app 路径>

  xcrun simctl uninstall $SIM $BID
  xcrun simctl install   $SIM "$OLD" && xcrun simctl launch $SIM $BID   # 先让系统存下旧会话
  xcrun simctl install   $SIM "$NEW" && xcrun simctl launch $SIM $BID   # 覆盖安装 → 黑屏
  xcrun simctl uninstall $SIM $BID
  xcrun simctl install   $SIM "$NEW" && xcrun simctl launch $SIM $BID   # 卸载重装 → 正常
  ```

- **排查手段：截图比 lldb 省事。** 真机上 `xcrun lldb -b -o 'device process attach -p <pid>'`
  实测**没能挂上**（随后 `process interrupt` 报 `Process must be launched`），
  而截图一眼就能定性：

  ```sh
  xcrun devicectl device capture screenshot --device <UDID> --destination /tmp/x.png
  xcrun simctl io <SIM-UDID> screenshot /tmp/x.png
  ```

  顺带用 `xcrun devicectl device info displays` 确认外接屏到底插没插 —— 只有 `LCD (primary)`
  时，手机上的黑屏就与外部显示器无关，别往外接屏方向查。
- **级联效应（重要）**：声明 accessory 的那个视图没加载，就等于没注册 ——
  手机端 app scene 挂掉会连带掐死外接屏那条路：根视图不出现 → 没有 accessory →
  iOS 27 系统根本不给外接屏 scene → 外接屏只剩镜像（镜像的正是那块黑屏）。
  所以「外接屏白转黑」和「手机白转黑」很可能是**同一个根因**，
  先看手机屏，不要一头扎进 `ExternalDisplaySceneDelegate`。

### 生命周期钩子的差异

SwiftUI 没有 `sceneDidDisconnect` 的等价物。原 `MainSceneDelegate` 在那里调用的
`MockExternalDisplay.shared.reset()`，这里挂在 `scenePhase` 的 `.background` 上近似，
并在 `.active`（以及首次 `.onAppear`）时重新 `bootstrap()` ——
否则进一次后台，替身窗口就永久消失了。真实项目若有必须在 scene 断开时释放的资源，
这一条要另行设计。

### 验证

Debug 模拟器零告警构建通过；带 `-mockExternalDisplay` 与不带两种启动都实跑截图确认
（替身窗口正常挂载 / 「未检测到外接屏」正常显示）。iOS 17~26 的旧路径在本机无法实测
（只有 iOS 27 运行时）。

覆盖安装黑屏这一条已实机验证：iPhone 16 Pro（iOS 27）上先卸载再装当前构建，
手机端 UI 正常；模拟器上按上面第四节（「第二个坑」）的脚本复现出同样的黑屏，
卸载重装后恢复正常，且反复重启稳定。

**iOS 27 的 SwiftUI accessory 路径实测（iOS 27.0 模拟器，iPhone 18 Pro）**：

- 启动后 `onAvailabilityChange` 回调一次 `availability = false`（DEBUG 下打印到控制台），
  即**注册被系统接受、可用性正确上报**。整条外接屏链路的失败模式都是「静默」，
  这是目前无硬件时唯一能确认注册生效的信号。
  复现：`xcrun simctl launch --console-pty <UDID> com.jove.externaldisplaydemo`，看
  `[ExternalDisplay] scene accessory availability = …`。
- 无外接屏时手机端显示「未检测到外接屏」；无 mock 与带 `-mockExternalDisplay` 两种启动
  都不崩溃、无回归。
- **交叉校验**：`ExternalDisplayRootView` 自测出的像素尺寸（视口点数 × `displayScale`）
  与宿主按窗口矩形算出的值完全一致（都是 `1086 × 611 px`）—— 两条独立算法互为验证。

> **仍未实测**：
> 1. **真机 + HDMI 适配器的外接屏 scene 本身**从未跑过（适配器没插，`device info displays`
>    只有主屏）。插上后手机端应出现「已连接 1 块外接屏 + 分辨率」；若仍只镜像，
>    优先怀疑 accessory 那段 `if #available` 没生效。
> 2. **模拟器替代不了这个验证** —— 实测 `UIScreen.screens.count == 1`：CoreSimulator
>    虽然枚举得出一个 7680×4320 的 `Display class: 1` 端口，UIKit 侧看不到它。
>    所以「真外接屏上到底出不出画面」在本机没有软件替代方案。
> 3. iOS 17~26 的 plist + scene delegate 路径在本机无法实测。
> 4. 自测量的两个前提 ——「accessory 内容铺满外接屏」与「其 `displayScale` 就是外接屏的
>    scale」—— 都是按 API 语义推断的，同样没有画面证据。

---

## 九、瀑布流 + 下拉露背景墙 + 星海

完整设计推导、踩坑与实测数据见
[`docs/devnotes/2026-09-24-waterfall-starfield.md`](docs/devnotes/2026-09-24-waterfall-starfield.md)。
这里只留结论。

### 滚动仍然是"假滚动"

外接屏用不了 `ScrollView`（第四节），所以瀑布流也是手写 `.offset` 驱动的：

```swift
.offset(y: plan.scroll.contentOffset(scroll: remote.scroll, pull: pull))
```

全项目**没有任何 `UIScrollView` 参与滚动**。UIKit 只出现在宿主层。

这条链路的两端：

| 端 | 在哪 | 干什么 |
| --- | --- | --- |
| 输入 | `GesturePad`（第四节，**触控板与空鼠栏各一块**） | 手指上下拖动 → `PadGesture` → `RemoteControl.scroll(by:)` |
| 输出 | `ExternalDisplayRootView` | 读 `remote.scroll` / `pull` → 算 `.offset(y:)` |

本节只讲**输出端**的几何；输入端（slop、逐帧增量、两块面的差异）在第四节。

### 滚动与下拉是同一个标量的两段

原来的 `scroll` 被 clamp 在 `0...1`，表达不了"已经在顶部还继续往下拽"。
但这两件事其实是同一条数轴上的两段，所以内部只留一个权威标量：

```
position > 0  →  正常滚动进度
position < 0  →  顶部下拉的超出行程
```

对外暴露 `scroll` 与 `pull`，但**唯一权威只有 `position`**。
拆成两个可独立写的存储属性的话，下拉时被阻尼吃掉的那部分行程，
在回拉时会变成凭空多出来的滚动 —— 手指一松内容就跳。

手感曲线 `1 - (1 - t)^1.7` 起手轻快、末段发沉，且在 `t = 1` 处**恰好取到 1**
（不是渐近逼近）—— 否则「内容顶边落在屏幕中线」这个几何承诺永远差一截。

### 瀑布流为什么不用 LazyVGrid

`LazyVGrid` 是**等高网格**：同一行的 cell 高度取该行最高的那个，剩下的用空白补齐。
那是「网格」不是「瀑布流」。真瀑布流要求每列的项独立堆叠、互不对齐。

本工程的实现是贪心分列（每项放进当前最矮的列），写成纯函数放在 `WaterfallLayout`，
高度用**权重**而不是点数（`unitHeight = 画面短边 × 0.20`），列数按宽高比选（16:9 用 4 列，
4:3 用 3 列）。

卡片的随机量分五路，都走同一条确定性随机序列（换种子即换一整片内容）：

| 随机量 | 区间 | 作用 |
| --- | --- | --- |
| `heightWeight` | `0.55...1.90`，另 22% 的卡再拉长 `0...0.85` | 错落的来源；长尾把少数卡从"横条"拉成"竖条" |
| `cornerScale` | `0.55...1.45` | 圆角浮动，消掉"批量生成"的整片轮廓线 |
| `gradientAngle` | `0...2π` | 每张卡各带一个光向，否则整片像被同一盏灯照亮 |
| `highlight` | 从渐变起点抖出 | **必须**与光向同侧，否则像被两盏灯从相反方向打光 |
| `tone` | 锚点 + ±0.045 抖动，12% 走深色中性 | 配色不跑偏的同时相邻卡片不重样 |

高度分布刻意不是均匀的：均匀铺满一个大区间会让长短卡五五开，看起来是"随机"而不是
"错落"。主体保持中等长度、少量长条插进去当锚点，才有节奏。

### 左右边距：内容收进屏内

最外两列**完整**落在屏内，与屏幕左右边缘各留出 `horizontalInset`
（参考 1920×1080 外接屏上 75.6pt）。做法是让**列排布区**比视口**窄**：

```swift
var horizontalInset: CGFloat { base * 0.07 }                    // 1080p 上 ≈ 75.6pt
var columnFieldWidth: CGFloat { max(0, viewport.width - horizontalInset * 2) }
var columnWidth: CGFloat { (columnFieldWidth - 列间距) / columns }
```

它与竖向 `inset` **同源**，于是瀑布流与 hero 的左右边正好对齐 —— 四个方向的留白
是同一个量级，画面上不会出现说不清的错位。

三个必须同时成立的条件：

1. **容器宽度仍锁死为视口宽**（`.frame(width: viewport.width)`）。父级 VStack 拿到的
   宽度一旦被子视图撑宽，圆角、阴影、下拉位移都会跟着跑偏。
2. **两侧留白由瀑布流内部让出**：排布区比视口窄，居中放置后自然内缩。
   容器那边不需要为横向做任何事（`.padding(.vertical, _)` 只管竖向）。
3. **hero 自己补左右内边距**，取同一个 `horizontalInset`。它的圆角是画面上的
   显式形状，被屏幕边缘切掉会看起来像布局错了。

> 早先这里是**反向**的：`horizontalBleed` 让内容向两侧各溢出约 100pt，最外两列被
> 屏幕边缘切开，用「内容比屏幕宽」来暗示两侧还有东西。改成正向后每一列都完整。
> 见 [`docs/devnotes/2026-09-24-waterfall-inset-focus.md`](docs/devnotes/2026-09-24-waterfall-inset-focus.md)。

### 星海：假 3D 的关键是"压缩过的透视"

教科书式的 `scale = focal / depth` 会把深度差放大成巨大的尺度差 ——
近处的星被推出画面、远处的星全挤在中心，**整片星海变成隧道而不是穹顶**。
纯分层平移又只剩平移视差，看不出纵深。

所以位置与尺寸**分别压缩**：

```swift
let positionScale = pow(focal / depth, 0.35)   // 0.82...1.35
let sizeScale     = pow(focal / depth, 0.60)   // 0.76...1.79
```

尺寸的指数更大，因为"远小近大"是大脑判断深度最强的单一线索。

劳斯莱斯质感另有六条：穹顶底色、亮度幂律分布、每颗星独立闪烁相位（**同步呼吸是"假"的
第一来源**）、最亮 3% 的十字光芒、尺寸与亮度正相关、深度衰减。

### 可验证性

四个纯计算文件（`WaterfallLayout` / `DisplayScrollGeometry` / `StarfieldModel` /
`PadGesture`）**只依赖 `CoreGraphics` 与 `Foundation`**，因此可以用 `swiftc` 独立编译跑断言 ——
目前 **162 条全过**。这是刻意设计的：`simctl` 没有触摸注入 API，
「手势 → 状态」那半条链路只能手点，但「状态 → 布局/投影」这半条可以真正断言，
而它恰好是最容易算错的部分。

`PadGesture` 是后来补进来的第四个（见第四节）：它把「手指按下 → 产生什么动作」
这半条也变成了可断言的（27 条）。仍然只能手点的只剩「SwiftUI 的手势分发本身」。

为了让「状态 → 渲染」那半条也可脚本化，有两个预置参数：

```bash
# 预置共享交互状态（滚动 / 下拉 / 缩放 / 光标）
xcrun simctl launch <device> <bundle> -mockExternalDisplay -remoteState pull=0.5
xcrun simctl launch <device> <bundle> -mockExternalDisplay -remoteState scroll=0.3,pull=0.25,zoom=1.5

# 预置遥控台的展开状态与输入方式（-dockState=expanded,airMouse）
xcrun simctl launch <device> <bundle> -mockExternalDisplay -dockState=expanded,airMouse
xcrun simctl launch <device> <bundle> -mockExternalDisplay -dockState=expanded,trackpad
```

`-dockState` 解决的是另一个盲区：遥控台默认收起、默认停在「触控板」那一栏，
而这两件事都只能靠手指点 —— 于是**空鼠栏的布局在自动化里完全看不到**。
把它变成启动参数后，空鼠栏也能进入逐状态截图流程。
（只认 `expanded` / `airMouse` / `trackpad` 三个记号，见 `MockDockState`。）

两者都与 `-mockExternalDisplay` 同一约定：只在带启动参数时生效，不参与真机链路。
它们伪造的都是**输入**，不是度量。
