# 在 iOS 模拟器里调试外接屏 UI：`-mockExternalDisplay` 的实现原理

> 配套代码：`Sources/Debug/MockExternalDisplay.swift`（约 150 行，可整段抄走）

## TL;DR

iOS 模拟器**永远不会创建** `windowExternalDisplayNonInteractive` 的 scene，所以外接屏那份 UI 在模拟器里本来完全无法调试。

解法不是去"模拟一块外接屏"，而是换个角度：**外接屏上跑的内容本来就只是一个 `UIWindow`**，而一个 `UIWindowScene` 可以承载多个 `UIWindow`。于是在手机屏自己的 scene 上再叠一个 `UIWindow`，挂上与外接屏**完全相同**的那份视图即可。

整个方案只依赖两个开关：

| 开关 | 作用 |
| --- | --- |
| `windowLevel = .normal + 1` | 让替身窗口浮在 App 主窗口之上 |
| `hitTest(_:with:)` 返回 `nil` | 让触摸穿透到下层，不挡住手机端 UI |

全程不碰任何外接屏 API。

---

## 二、问题：模拟器不会给你外接屏 scene

iOS 13 起接入外接屏只有一条路径 —— **scene**。应用在 Info.plist 里声明 `UIWindowSceneSessionRoleExternalDisplayNonInteractive`（iOS 27 起该声明不再生效，必须另行注册 scene accessory：SwiftUI 用 `View.sceneAccessory { ExternalNonInteractiveAccessory { … } }`，UIKit 用 `UIViewController.registerSceneAccessory(_:)`），系统才会为外接屏建立独立的 `UISceneSession` 并回调 scene delegate。

但在模拟器里，这个 scene **永远不会被创建**。`UIScreen.screens` 也永远只有主屏一个。

这里有两个容易走偏的判断：

**它不是代码问题。** 插上 HDMI 适配器就正常工作的代码，在模拟器里照样什么都不发生。别去反复检查 Info.plist 里的 `UISceneDelegateClassName` 是否模块限定 —— 那个坑的排查成本很高，但和模拟器无关。

**它不是运行时版本问题。** 有人会想"装个旧版 iOS 运行时试试"。没用：这是**硬件约束**，不是运行时约束。`xcodebuild -downloadPlatform iOS -buildVersion <ver>` 会花掉好几 GB 流量，然后得到同样的结果。

结论就是：**外接屏那条链路在模拟器里根本无法端到端验证**。但真正让人难受的不是"接不上"，而是**外接屏上那份 UI 完全没法调试** —— 布局对不对、动画跑不跑、状态同步有没有生效，全都看不到。

这份文档解决的是后者。

---

## 三、思路：借手机屏的 scene 用

关键洞察有三条：

**1. 外接屏上的内容，本质上只是一个普通 `UIWindow`。**

看真机的 scene delegate：

```swift
func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
           options connectionOptions: UIScene.ConnectionOptions) {
    guard session.role == .windowExternalDisplayNonInteractive,
          let windowScene = scene as? UIWindowScene else { return }

    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = UIHostingController(rootView: ExternalDisplayRootView(...))
    window.isHidden = false          // 刻意不用 makeKeyAndVisible()
    self.window = window
}
```

除了 `windowScene` 来自哪块屏之外，它和任何一个普通窗口没有区别。

**2. 一个 `UIWindowScene` 可以承载多个 `UIWindow`。**

这不是什么黑魔法。系统自己就在这么干：键盘、alert、`UIAlertController` 的浮层、`UIDimmingView`，都是独立 window。App 通常只建一个，但**没有任何规则禁止建第二个**。

**3. 因此"外接屏内容"和"某个窗口里的内容"是解耦的。**

同一份 `ExternalDisplayRootView`，挂到外接屏的 window 上就是外接屏内容，挂到手机屏的 window 上就是一块浮层。视图本身完全不知道自己在哪。

三条合起来，方案就出来了：

```
真机路径                              模拟器 mock 路径
────────────────────────────          ────────────────────────────
UIWindowScene（外接屏，独立 screen）   UIWindowScene（手机屏，同一个）
  └─ UIWindow                           ├─ UIWindow ① App 主窗口
       └─ ExternalDisplayRootView       └─ UIWindow ② 替身窗口（level .normal + 1）
                                              └─ ExternalDisplayRootView  ← 同一份
```

注意右侧：**替身窗口和主窗口共用同一个 `windowScene`**。这就是"能渲染到模拟器屏幕上"的全部原因 —— 它本来就是一个普通窗口。

---

## 四、实现拆解

### 4.1 触发：启动参数，默认关闭

```swift
static var isEnabled: Bool {
    ProcessInfo.processInfo.arguments.contains("-mockExternalDisplay")
}
```

用启动参数而不是编译条件（`#if DEBUG`）的好处：**同一份构建产物**可以带参数跑 mock、不带参数跑真实路径。真机包和模拟器包的行为差异不会被编译期分支割裂开。

在 Xcode 的 scheme 里挂成 `commandLineArguments`，默认关闭，需要时勾上：

```yaml
# project.yml（XcodeGen）
run:
  commandLineArguments:
    "-mockExternalDisplay": false
```

用 `simctl` 启动时直接跟在 bundle id 后面：

```sh
xcrun simctl launch booted com.example.app -mockExternalDisplay
```

### 4.2 挂载：在手机屏的 scene 上再建一个 window

```swift
func bootstrap(on windowScene: UIWindowScene) {
    guard Self.isEnabled else { return }      // 真机链路直接短路
    self.windowScene = windowScene
    if !isVisible { isVisible = true }        // didSet → install()
}

private func install() {
    guard window == nil, let windowScene else { return }

    let mockWindow = PassthroughWindow(windowScene: windowScene)   // ← 注意是手机屏的 scene
    mockWindow.frame = rect
    mockWindow.windowLevel = .normal + 1
    mockWindow.rootViewController = UIHostingController(
        rootView: ExternalDisplayRootView(resolution: ...)          // ← 与外接屏同一份视图
    )
    mockWindow.isHidden = false
    window = mockWindow
}
```

`guard Self.isEnabled else { return }` 这一句保证了**这层完全不参与真机链路**：没有启动参数时 `bootstrap` 直接返回，一行 mock 代码都不会执行。

`windowScene` 声明成 `weak`：它由系统持有，替身窗口不该延长它的生命周期。

### 4.3 尺寸：按宽高比 letterbox

替身窗口不是全屏的 —— 它要模拟一块 16:9 的横屏，而手机屏是竖的。所以按宽高比在可用区域内居中摆放，多出来的方向留黑边：

```swift
private static func letterboxedRect(in container: CGRect, aspect: CGFloat) -> CGRect {
    guard container.width > 0, container.height > 0, aspect > 0 else { return container }

    let reservedBottom: CGFloat = 96        // 底部常驻 UI 的预留（见第七节）
    let available = CGRect(
        x: container.minX, y: container.minY,
        width: container.width,
        height: max(container.height - reservedBottom, 0)
    )
    guard available.height > 0 else { return container }

    if available.width / available.height > aspect {
        // 容器更宽 → 高度顶满，宽度按比例收
        let width = available.height * aspect
        return CGRect(x: available.midX - width / 2, y: available.minY,
                      width: width, height: available.height)
    } else {
        // 容器更高（竖屏手机就是这种）→ 宽度顶满，高度按比例收
        let height = available.width / aspect
        return CGRect(x: available.minX, y: available.midY - height / 2,
                      width: available.width, height: height)
    }
}
```

容器取 `windowScene.coordinateSpace.bounds`，再 `insetBy(dx: 20, dy: 60)` 留出边距。

宽高比可配置，支持 `-mockExternalDisplayAspect=4:3` 与 `-mockExternalDisplayAspect 4:3` 两种写法（`parseAspect()` 里对两种形式都做了处理，解析失败回落 16:9）。

### 4.4 层级：`windowLevel`

```swift
mockWindow.windowLevel = .normal + 1
```

`.normal` 是 App 主窗口的层级。`+ 1` 让它盖在上面。

这里有个**必须接受的事实**：替身窗口一旦在更高层，就永远盖在主窗口之上，你没法让它"半透"或"局部让位"。所以任何与它抢位置的手机端 UI，都得由替身窗口**主动避让**（见 4.3 的 `reservedBottom` 和第七节）。

### 4.5 触摸穿透：`PassthroughWindow` ★

这是整个方案里最关键、也最容易漏掉的一行：

```swift
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
```

`hitTest` 恒返回 `nil`，意味着**这个窗口对触摸完全透明**。UIKit 在找到它之后不会停在这里，而是继续往下层窗口派发。

不写这一句会怎样：替身窗口按层级盖在手机端 UI 上方，而它自己有内容（一块黑底画布），于是**它覆盖到的所有手机端控件都点不动了**。表现为"界面还在，但按钮全部失灵"，很容易误判成别的 bug。

注意 `hitTest` 返回 `nil` 只是让**窗口**不接收触摸，替身窗口内部的 SwiftUI 视图照样正常渲染和跑动画 —— 我们要的正是"只显示、不拦截"。

### 4.6 状态登记：让手机端 UI 知道这是模拟的

替身挂载后，把它登记进连接状态的中心记录点，并**标记来源**：

```swift
ExternalDisplayMonitor.shared.attachMock(
    pixelSize: CGSize(width: rect.width * scale, height: rect.height * scale),
    nativeScale: scale
)
```

`Attachment` 里带一个 `source` 字段区分 `.physical` / `.mock`，手机端界面据此显示不同徽章（物理=蓝色、模拟=橙色）。

这件事看起来是锦上添花，实际很重要：**调试时最怕把 mock 的状态当成真机的状态**。状态面板上明确写着"模拟"，就不会误读。

### 4.7 分辨率是伪造的 ★

```swift
let scale: CGFloat = 3          // 硬编码
resolution: "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
```

替身窗口上显示的那串 `1086 × 610 px @3.0x`，是**由 letterbox 窗口的点尺寸乘一个硬编码的 3 推出来的**，不是任何真实屏幕的参数。

真机路径才是真的读屏幕：

```swift
let screen = windowScene.screen
screen.nativeBounds.size     // 真实像素尺寸
screen.nativeScale           // 真实倍率
```

这个区别要在文档和代码注释里写清楚，否则很容易有人拿 mock 上显示的"分辨率"去调真实项目的适配逻辑 —— 那是纯虚构的数字。

---

## 五、真正的关键：复用同一份视图

前面所有技巧加起来，价值都建立在这一点上：

> 替身窗口里挂的 `ExternalDisplayRootView`，与真机 `ExternalDisplaySceneDelegate` 里挂的是**同一个类型**。

```swift
// 真机：Sources/ExternalDisplay/ExternalDisplaySceneDelegate.swift
window.rootViewController = UIHostingController(
    rootView: ExternalDisplayRootView(resolution: "\(Int(screen.nativeBounds.width)) × \(...))")
)

// 模拟器：Sources/Debug/MockExternalDisplay.swift
mockWindow.rootViewController = UIHostingController(
    rootView: ExternalDisplayRootView(resolution: "\(Int(rect.width * scale)) × \(...))")
)
```

只有 `resolution` 这个字符串的来源不同。如果 mock 里挂的是一份"长得差不多"的仿制视图，那这个方案就退化成了一张截图，调试价值基本归零 —— **布局差异、动画卡顿、状态不同步，全都测不出来**。

同理，两侧共享同一份状态对象（本项目里是 `DisplayContentStore` 与 `RemoteControl`），手机端改一个值，替身窗口立刻重绘。因为它们在**同一个进程**里，只是分属两个 `UIScene`，连跨进程通道都不需要。

---

## 六、这个方案能验证什么、不能验证什么

必须把边界说清楚，否则容易产生虚假的安全感。

| | 能否验证 | 说明 |
| --- | --- | --- |
| 外接屏 UI 的布局 | ✅ | 尺寸比例真实（letterbox 按宽高比算） |
| 逐帧渲染 / 动画 | ✅ | 同一个进程、同一条渲染链路 |
| 状态同步 | ✅ | 共享内存，手机端改立刻重绘 |
| 交互（遥控） | ✅ | 手势在手机侧采集，mock 与真机走同一条路 |
| **scene 是否被创建** | ❌ | 模拟器永远不创建该 scene |
| **Info.plist / role / accessory 配置是否正确** | ❌ | 配置写错了，mock 照样跑得好好的 |
| **真实分辨率与 `nativeScale`** | ❌ | 数字是伪造的 |
| **拔插时机与 `sceneDidDisconnect`** | ❌ | 没有真实的连接/断开事件 |
| **多屏** | ❌ | 只有一块替身 |

一句话：**mock 验证的是"内容与渲染"，不是"接入"**。

而"接入"恰恰是最容易出错、最需要验证的部分 —— 静默镜像、`UIRequiresFullScreen`、模块限定的类名、iOS 27 起必须注册 accessory，这些坑 mock 一个都覆盖不到。所以：

- 用 mock 快速迭代 UI；
- 用真机 + USB-C/Lightning 转 HDMI 适配器（或 AirPlay）验证接入；
- 两者都做，不要用前者替代后者。

---

## 七、踩坑清单

**1. 忘了 `hitTest` 返回 `nil`** → 替身窗口挡住手机端所有控件，界面正常但按钮失灵。

**2. 替身窗口与底部常驻 UI 抢位置** → 替身窗口在更高层且永远盖住主窗口，如果手机端底部有常驻面板（工具栏、遥控台、播放控制条），展开时会正好被它遮住标题栏。必须在 letterbox 计算时主动预留（本项目预留底部 96pt）。

  判断"预留多少"的办法：把替身窗口的可用区域扣掉面板高度，再居中。预留量取面板展开后的高度，别只算收起态 —— 否则展开时照样重叠。

**3. 把伪造的分辨率当真实参数用** → 见 4.7。mock 上的 `1086 × 610 px @3.0x` 是点尺寸乘 3 编出来的。

**4. 忘了把 mock 排除在真机链路之外** → 所有入口都要有 `guard isEnabled` 短路。真机上跑出两个窗口会非常难排查。

**5. 忘记在 scene 断开时释放 window** → 残留一个无人持有的渲染面。真机路径挂在 `sceneDidDisconnect`；SwiftUI 生命周期下没有等价钩子，要在 `scenePhase` 的 `.background` 里做，并在 `.active` 时重建（进后台再回前台**不会**重新触发 `viewDidAppear`）。

**6. 在 mock 里仿制视图而不是复用** → 见第五节，这是最容易把方案做废的一条。

---

## 八、迁移到真实项目

这套东西是通用的，与具体业务无关。落地步骤：

1. 把 `MockExternalDisplay.swift` 整段拷进项目，改一下视图类型和状态对象；
2. 把 `ExternalDisplayRootView` 换成你的外接屏根视图（视频用 `MTKView` / `AVPlayerLayer` 的 `UIViewRepresentable`，一样能用）；
3. 在手机 scene 建立后调一次 `bootstrap(on:)`；
4. 手机端加一个开关绑定 `isVisible`，随时收起替身去操作表单；
5. scheme 里挂上 `-mockExternalDisplay`，默认关闭。

**唯一的前提**：你的外接屏内容必须是一份**独立的、可被 `UIHostingController` / `UIViewController` 承载的视图**。如果它和手机端 UI 耦合在一个视图树里，先拆开 —— 这一步本来也该做，真机上它们就是两个独立 scene。

---

## 附：完整代码骨架

```swift
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class MockExternalDisplay {

    static let shared = MockExternalDisplay()

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-mockExternalDisplay")
    }

    var isVisible: Bool = false {
        didSet {
            guard oldValue != isVisible else { return }
            isVisible ? install() : uninstall()
        }
    }

    @ObservationIgnored private weak var windowScene: UIWindowScene?
    @ObservationIgnored private var window: UIWindow?

    private init() {}

    /// 手机 scene 建好后调用一次。没有启动参数时直接短路。
    func bootstrap(on windowScene: UIWindowScene) {
        guard Self.isEnabled else { return }
        self.windowScene = windowScene
        if !isVisible { isVisible = true }
    }

    func reset() {
        window?.isHidden = true
        window = nil
        windowScene = nil
        if isVisible { isVisible = false }
    }

    private func install() {
        guard window == nil, let windowScene else { return }

        let container = windowScene.coordinateSpace.bounds
        guard container.width > 0, container.height > 0 else { return }

        let scale: CGFloat = 3                       // 伪造的倍率
        let aspect = Self.parseAspect() ?? 16.0 / 9.0
        let rect = Self.letterboxedRect(in: container.insetBy(dx: 20, dy: 60), aspect: aspect)

        let mockWindow = PassthroughWindow(windowScene: windowScene)
        mockWindow.frame = rect
        mockWindow.windowLevel = .normal + 1
        mockWindow.backgroundColor = .black
        mockWindow.layer.cornerRadius = 20
        mockWindow.layer.borderWidth = 4
        mockWindow.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.8).cgColor
        mockWindow.clipsToBounds = true
        mockWindow.rootViewController = UIHostingController(
            rootView: YourExternalDisplayRootView(
                resolution: "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
            )
        )
        mockWindow.isHidden = false
        window = mockWindow
    }

    private func uninstall() {
        window?.isHidden = true
        window = nil
    }

    // MARK: - Helpers

    private static func letterboxedRect(in container: CGRect, aspect: CGFloat) -> CGRect {
        guard container.width > 0, container.height > 0, aspect > 0 else { return container }

        let reservedBottom: CGFloat = 96             // 给底部常驻 UI 让位
        let available = CGRect(
            x: container.minX, y: container.minY,
            width: container.width,
            height: max(container.height - reservedBottom, 0)
        )
        guard available.height > 0 else { return container }

        if available.width / available.height > aspect {
            let width = available.height * aspect
            return CGRect(x: available.midX - width / 2, y: available.minY,
                          width: width, height: available.height)
        } else {
            let height = available.width / aspect
            return CGRect(x: available.minX, y: available.midY - height / 2,
                          width: available.width, height: height)
        }
    }

    private static func parseAspect() -> CGFloat? {
        let flag = "-mockExternalDisplayAspect"
        let arguments = ProcessInfo.processInfo.arguments
        var raw: String?

        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix(flag + "=") {
                raw = String(argument.dropFirst(flag.count + 1))
            } else if argument == flag, index + 1 < arguments.count {
                raw = arguments[index + 1]
            }
        }

        guard let raw else { return nil }
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return CGFloat(parts[0] / parts[1])
    }
}

/// 对触摸完全透明：不吞事件，否则手机端 UI 会被这个覆盖窗口挡住。
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
```
