# iOS 27 外接屏改用 SwiftUI 原生 scene accessory

分支：`feat/swiftui-scene-accessory`
日期：2026-09-22

## 缘起

前一轮确认了 `UISceneConfigurations` 整块在 SwiftUI 生命周期下都不是必需的，随后追问
「`PhoneSceneBridge` 还是必须的吗」。查 SDK 时发现 iOS 27 的 SwiftUI 自带一套一等公民 API，
于是开了这条分支做实验：**能不能用它替掉 UIKit 注册，并连带删掉那个宿主 VC。**

## SDK 依据

`SwiftUI.swiftinterface`（iPhoneOS27.0.sdk）里的三处声明，全部 `@available(iOS 27.0, *)`：

```swift
extension View {                                    // line 19774
    func sceneAccessory<C: SceneAccessoryContent>(@ContentBuilder content: () -> C) -> some View
}

public struct ExternalNonInteractiveAccessory<Content: View>   // line 20750
    : SceneAccessoryContent {
    init(@ContentBuilder content: @escaping () -> Content)
    init(isEnabled: Binding<Bool>, @ContentBuilder content: @escaping () -> Content)
}

extension SceneAccessoryContent {                   // line 17562
    func onAvailabilityChange(perform action: @escaping (_ isAvailable: Bool) -> Void)
        -> some SceneAccessoryContent
}
```

对照组（UIKit，只作备选）：`UIViewController.h:366` 的
`- (UISceneAccessoryRegistration *)registerSceneAccessory:(UISceneAccessory *)accessory`
是**实例方法** —— 这就是「必须有一个宿主 view controller，且它得处于呈现状态」的来源；
返回值是一个必须强引用的注册句柄。SwiftUI 那条路把这两件事都消掉了。

`UISceneAccessory.h` 同时明确：accessory 是**增强**，应用必须能在没有它的情况下完整工作。

## 采用的方案

1. iOS 27+：`WindowGroup` 根视图上挂 `.externalDisplaySceneAccessory()`，内部
   `if #available(iOS 27.0, *)` → `content.sceneAccessory { ExternalNonInteractiveAccessory { … } }`；
   iOS 17~26 落到 `else`，仍是 Info.plist + `ExternalDisplaySceneDelegate`。
2. `ExternalDisplayRootView` 不再接收 `resolution`，改为自测量（视口点数 × `displayScale`）。
   纯 SwiftUI 路径没有 `windowScene`，而 `UIScreen.screens`（iOS 16 废弃）、
   `UIScreen.main`（iOS 26 废弃）都不该再用。顺带让 delegate / mock / Preview 三个宿主
   都不再需要知道屏幕尺寸。
3. 删除 `PhoneSceneBridge`。它原本补的两件事都没了：accessory 注册改声明式；
   主屏 `UIWindowScene` 只有 debug 的 mock 需要，而 `UIApplication.shared.connectedScenes`
   随时可查，不需要「登记」。
4. `ExternalDisplayMonitor` 增加第三个数据源：可用性由 `onAvailabilityChange` 驱动，
   尺寸由内容自报。

## 实测

| 项 | 方法 | 结果 |
| --- | --- | --- |
| 编译（deployment target 17.0） | `xcodebuild build`（模拟器） | 零错误零告警 |
| **注册被系统接受** | `simctl launch --console-pty` 抓 `onAvailabilityChange` | 回调 `availability = false` ✔ |
| 手机端无回归（无 mock） | 截图 | 「未检测到外接屏」，正常 |
| 手机端无回归（`-mockExternalDisplay`） | 截图 | 替身窗口正常，`1086 × 611 px` |
| **自测量正确性** | 与宿主按窗口矩形独立算出的值比对 | 完全一致（`1086 × 611 px`） |
| 模拟器能否替代真外接屏 | 探针读 `UIScreen.screens` | `count == 1`，**不能替代** |

`onAvailabilityChange` 那次回调是目前无硬件时**唯一**能确认「注册生效」的信号 ——
整条外接屏链路的失败模式清一色是静默，所以保留了一行 DEBUG 打印作为观测点。

模拟器探针还发现：CoreSimulator 枚举得出一个 `Display class: 1`、7680×4320 的 IO 端口，
但 UIKit 侧看不到它。所以「模拟器有第二块屏」是个假象，不能用来验证外接屏。

## 未验证边界

1. 真机 + HDMI 适配器的外接屏 scene **从未跑过**（适配器没插）。插上后手机端应出现
   「已连接 1 块外接屏 + 分辨率」。
2. 自测量的两个前提 ——「accessory 内容铺满外接屏」与「其 `displayScale` 就是外接屏的 scale」——
   按 API 语义推断，无画面证据。
3. iOS 17~26 路径本机无法实测（只有 iOS 27 运行时）。
4. 没有做前后台切换的替身重挂验证（`simctl` 不便精确控制该时机）。

**结论：iOS 27 上的取舍要等真插上屏才能定。** 这条分支目前的证据只支持「注册被系统接受」，
不支持「真外接屏上一定出画面」。
