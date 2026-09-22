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
| 屏幕信息 | `windowScene.screen.nativeBounds` / `.nativeScale` | iOS 13+ | ✅ |
| 自动连接 scene | 仅在 Info.plist 声明 role | iOS 16 – 26 | ⚠️ **iOS 27 起失效** |
| **主动注册 scene** | `UIViewController.registerSceneAccessory(_:)` + `UISceneAccessory.externalNonInteractive(sceneConfiguration:)` | **iOS 27.0+** | ✅ **iOS 27 起必须** |

### 最关键的一条

> Apple 文档 *Presenting content on a connected display*：
> "Beginning in iOS 27, your app receives a scene with the `windowExternalDisplayNonInteractive`
> role only after it registers a scene accessory. In earlier releases, the system connected this
> scene automatically."

也就是：

- **iOS 17 ~ 26**：Info.plist 里声明了 role，插上屏系统就自动送 scene 过来。
- **iOS 27 起**：光声明 plist 不够，必须调 `registerSceneAccessory(_:)`，否则系统根本不会连这个 scene。

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
    ├── UIWindowSceneSessionRoleApplication                          → 空壳条目（见下）
    └── UIWindowSceneSessionRoleExternalDisplayNonInteractive        → ExternalDisplaySceneDelegate
```

三个易错点：

- **application role 的条目必须留，但不能带 `UISceneDelegateClassName`**。
  本项目主界面走 SwiftUI `WindowGroup`，scene delegate 由 SwiftUI 自己装，
  所以这条只需要一个空壳占位：

  ```xml
  <key>UIWindowSceneSessionRoleApplication</key>
  <array>
    <dict>
      <key>UISceneConfigurationName</key>
      <string>Phone Scene</string>
    </dict>
  </array>
  ```

  删掉它（"反正 SwiftUI 自己管"）会**黑屏且零日志**，详见第八节。
  反过来给它写上 delegate class，则会与 SwiftUI 的 delegate 冲突。

- `UISceneDelegateClassName` 必须**模块限定**：`$(PRODUCT_MODULE_NAME).ExternalDisplaySceneDelegate`。
  写错的表现和上面一样 —— 静默镜像。用 `plutil -p` 检查构建产物里的 Info.plist 确认展开正确：

  ```
  plutil -p build/.../ExternalDisplayDemo.app/Info.plist
  ```

- **不要**设置 `UIRequiresFullScreen = YES`。iPhone 上这个键会让应用直接失去外部显示器能力。

### 2. 实现外接屏 scene delegate

见 `Sources/ExternalDisplay/ExternalDisplaySceneDelegate.swift`：

```swift
func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
           options connectionOptions: UIScene.ConnectionOptions) {
    guard session.role == .windowExternalDisplayNonInteractive,
          let windowScene = scene as? UIWindowScene else { return }

    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = UIHostingController(rootView: ...)
    window.isHidden = false          // 不要 makeKeyAndVisible()
    self.window = window
}

func sceneDidDisconnect(_ scene: UIScene) { window = nil }
```

为什么不用 `makeKeyAndVisible()`：外接屏窗口不该从手机屏抢走 key 状态，
否则手机端第一响应者 / 键盘焦点可能被打断。只设 `isHidden = false` 即可显示。

### 3. iOS 27+：注册 scene accessory

见 `Sources/App/PhoneSceneBridge.swift`：

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

要点：

- 必须在**主界面里的 view controller** 上注册，语义是「随该 VC 的呈现状态生效」：
  VC 在屏幕上 + `registration.isEnabled == true` + 外接屏可用 → 系统才连接 scene。
- 返回的 `UISceneAccessoryRegistration` **必须强引用住**，否则注册立即失效。
- 需要在某一页才提供外部屏内容时，用 `unregisterSceneAccessory(_:)` 在页面退出时注销。
- 想给 scene delegate 传业务上下文（比如"这块屏是给观众看的还是给控制台用的"），
  用 `externalNonInteractive(sceneConfiguration:userInfo:)`，在 delegate 里读
  `connectionOptions.sceneAccessoryUserInfo`。

---

## 三、工程结构

```
ExternaldisplayDemo/
├── project.yml                                    XcodeGen 配置（XcodeGen 2.46+）
├── Support/Info.plist                             scene manifest 在这里
└── Sources/
    ├── App/
    │   ├── ExternalDisplayDemoApp.swift           @main（SwiftUI App）
    │   ├── PhoneSceneBridge.swift                 零尺寸宿主 VC：反查 windowScene + 注册 accessory
    │   ├── PhoneRootView.swift                    状态面板 + 推送内容控制
    │   ├── RemoteControlPad.swift                 手机端遥控板（手势采集）
    │   └── RemoteControlDock.swift                底部常驻遥控台（safeAreaInset 宿主）
    ├── Core/
    │   ├── ExternalDisplayMonitor.swift           连接状态记录（@Observable）
    │   ├── DisplayContentStore.swift              共享内容状态（「选什么」）
    │   └── RemoteControl.swift                    共享交互状态（「怎么看」）
    ├── ExternalDisplay/
    │   ├── ExternalDisplaySceneDelegate.swift     ★ 接入落点
    │   ├── ExternalDisplayRootView.swift          外接屏根视图（纯输出，无手势）
    │   └── DisplayPatternCanvas.swift             逐帧渲染验证
    └── Debug/
        └── MockExternalDisplay.swift              模拟器替身（不参与真机链路）
```

数据流：手机端改 `DisplayContentStore` → 外接屏 `ExternalDisplayRootView` 自动重绘。
两侧是**同一进程内的两个 UIScene，共享内存**，不需要任何跨进程通道。

内容与交互拆成两份状态，各自职责单一：

| 状态 | 回答的问题 | 写入方 | 读取方 |
| --- | --- | --- | --- |
| `DisplayContentStore` | 外接屏**显示什么** | 手机端表单 | `ExternalDisplayRootView` |
| `RemoteControl` | 外接屏**怎么看**（滚动 / 缩放 / 光标） | 手机端遥控板手势 | `ExternalDisplayRootView` |

---

## 四、交互：外接屏收不到触摸，怎么办

**结论：外接屏自己不能滚动，也不接受任何手势。** 两个独立原因，任一条都足以让它失效：

1. **role 本身就是非交互的**。`windowExternalDisplayNonInteractive` 明确不接收触摸，
   `ExternalDisplaySceneDelegate` 里的 `window.isUserInteractionEnabled = false` 只是把语义写出来。
2. **模拟器 mock 同样收不到**。`PassthroughWindow.hitTest` 恒返回 `nil`，触摸全部穿透到下层窗口。

所以在外接屏的视图树里加 `ScrollView` 或 `.gesture` 是**无效的** —— 手势根本到不了那里。
外接屏是纯输出设备，一切输入都必须从手机侧中继。

本工程的做法：手机端加一块遥控板，手势在手机侧采集，经 `RemoteControl` 单向送到外接屏渲染视图。

```
   手机端手势                   共享状态                    外接屏渲染
RemoteControlPad   ──写──▶   RemoteControl    ──读──▶  ExternalDisplayRootView
  DragGesture                 scroll / zoom             .offset(y:)
  MagnifyGesture              pointer / tapCount        .scaleEffect()
```

| 手势 | 手机端采集 | 外接屏响应 |
| --- | --- | --- |
| 单指拖动 | `DragGesture`，逐帧增量归一化 | 内容列按 `scroll` 偏移；手指落点画成橙色光标环 |
| 双指捏合 | `MagnifyGesture` | 图案画布 `.scaleEffect(zoom)` |
| 轻点 | 按钮 | 光标处扩散一次涟漪 |

三个实现要点：

- **存归一化值，不存像素位移**。外接屏可能是 1080p / 4K / 模拟器里 362×203pt 的 letterbox
  小窗口，尺寸差一个数量级。`RemoteControl.scroll` 存 `0...1` 的进度，外接屏侧用
  `ScrollMetrics` 按自身内容高度换算实际位移，同一份手机端状态在哪块屏上都成立。
- **拖拽增量要自己算**。`DragGesture` 的 `translation` 是**累计值**，直接当增量用会让滚动速度
  随拖拽时长不断放大，必须减掉上一次的值。`MagnifyGesture` 的 `magnification` 同理。
- **`.frame()` 不指定对齐会居中**。滚动内容高度（本工程约 446pt）远超视口（约 203pt），
  `.frame(width:height:)` 默认居中会把内容上移半个差值 —— 表现是「滚动起点就少了两条内容」。
  必须写 `alignment: .topLeading`，再靠 `.clipped()` 裁掉溢出。

> **验证边界**：`xcrun simctl` 没有触摸注入 API，Xcode 27 的模拟器 GUI（DeviceHub）也没有
> 可脚本化的设备窗口，所以「手势 → 状态」这半条链路在本机无法自动化验证，需手动在模拟器里拖一下。
> 「状态 → 渲染」这半条已用临时插桩验证过（`scroll = 0.62` / `zoom = 1.9` / `pointer = (0.3, 0.35)`）：
> 可见内容恰为条目 04（顶部被切）～11，光标环实测落点 `(109.5, 70.8)pt`，与计算值 `(108.6, 71.0)pt` 一致。
>
> **手势归属靠结构保证，不靠运气**。触控板最初放在 `Form` 里，它的 `DragGesture` 会与外层
> 滚动视图的竖向 pan 手势竞争 —— 而 SwiftUI **没有**能压过祖先 `ScrollView` 的公开 API
> （`highPriorityGesture` 只影响当前视图与其子视图）。现在改由 `RemoteControlDock` 经
> `.safeAreaInset(edge: .bottom)` 挂在滚动区域**之外**，归属没有歧义，
> 顺带省掉了「要先滚动才能摸到遥控板」这一步。遥控台默认收起只留读数栏，
> 展开才铺开触控板 —— 这样它和模拟外接屏窗口能同时看见。

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
13. **SwiftUI `App` 生命周期下，把 `UIWindowSceneSessionRoleApplication` 从
    `UISceneConfigurations` 里删掉** → app scene 连不上，**纯黑屏、零日志**。
    该条目必须留，但不能带 `UISceneDelegateClassName`。详见第八节。

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
| 手机端 UI 宿主 | `PhoneRootViewController` | `PhoneSceneBridge`（零尺寸宿主 VC） |
| scene accessory 注册 | `PhoneRootViewController.viewDidLoad` | `PhoneSceneBridge.viewDidLoad` |
| 外接屏 scene | `ExternalDisplaySceneDelegate` | **不变** |
| Info.plist external role | 声明 | **不变** |

**外接屏那一路换不掉**：SwiftUI 的 `App` / `Scene` / `WindowGroup` 只能创建
`windowApplication` role 的 scene，没有任何 API 能接管
`windowExternalDisplayNonInteractive`。所以「纯 SwiftUI」到手机端为止。

### 两个 SwiftUI 拿不到的东西

`PhoneSceneBridge` 存在的唯一理由就是补上这两样：

1. **主屏 `UIWindowScene`** —— SwiftUI 只有 `scenePhase`，没有 windowScene 环境值。
   优先从 `view.window?.windowScene` 反查；`viewDidLoad` 阶段 `view.window` 还是 nil，
   退回遍历 `UIApplication.shared.connectedScenes` 找 `windowApplication` role。
2. **`registerSceneAccessory(_:)` 的宿主** —— iOS 27 起必须在「主界面里的一个
   view controller」上注册，且句柄要强引用住。

它是根视图 `.background` 里一个零尺寸、`allowsHitTesting(false)` 的
`UIViewControllerRepresentable`，不参与布局。

### ★ 踩到的坑：只声明 external role 会黑屏

把 `UISceneConfigurations` 里的 `UIWindowSceneSessionRoleApplication` 条目删掉之后，
应用启动是**纯黑屏**：进程存活、无崩溃报告、**日志里一个 error 都没有**。
把根视图换成一个纯色（`Color.red`）依然黑屏 —— 说明与视图层无关，是 app scene 压根没连上
（黑屏其实是 `UILaunchScreen` 没被替换掉）。

规则是：

- `UISceneConfigurations` 字典**存在**时，必须包含 `UIWindowSceneSessionRoleApplication`
  条目，否则 app scene 连不上（本坑）；
- 但该条目**不能**带 `UISceneDelegateClassName`，否则会与 SwiftUI 自己装的
  scene delegate 冲突；
- 若把整个 `UISceneConfigurations` 字典删掉，SwiftUI 反而正常 ——
  代价是 iOS 17~26 的「plist 自动连接外接屏」那条路也没了。

所以最终形态：application role 留一个只有 `UISceneConfigurationName` 的空壳条目，
external role 保持原样。

### 生命周期钩子的差异

SwiftUI 没有 `sceneDidDisconnect` 的等价物。原 `MainSceneDelegate` 在那里调用的
`MockExternalDisplay.shared.reset()`，这里挂在 `scenePhase` 的 `.background` 上近似，
并在 `.active` 时用 `PhoneSceneLocator` 存的主屏 scene 重新 bootstrap ——
否则进一次后台，替身窗口就永久消失了。真实项目若有必须在 scene 断开时释放的资源，
这一条要另行设计。

### 验证

Debug 模拟器零告警构建通过；带 `-mockExternalDisplay` 与不带两种启动都实跑截图确认
（替身窗口正常挂载 / 「未检测到外接屏」正常显示）。iOS 17~26 的旧路径在本机无法实测
（只有 iOS 27 运行时）。
