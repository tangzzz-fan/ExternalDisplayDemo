# 空鼠手势：上下滑动 + 单指点击确认

分支：`feat/airmouse-tap-scroll`
日期：2026-09-24
基线：`34baa67 feat: 瀑布流左右出血 + 卡片随机性大幅提高`

## 缘起

需求原话两句，第二句是打断第一句之后补的：

1. 「创建新的分支，现在激光空鼠部分，也需要支持手势上下滑动（左右可以）」
2. 「即用户打开激光空鼠时，其实还需要依赖单指手势实现点击确认」

第 2 句才是真正的痛点。原来的空鼠交互是「抬手瞄准 + 按底部扳机确认」，
但空鼠工作时手机是**被举起来**的：瞄准的那只手在手机背面/侧面，
手指去够屏幕底部那个扳机按钮既别扭、又会带歪姿态 ——
**瞄准和确认被拆到了两个物理上打架的位置**。

所以确认必须能落在手边的任意位置。这就把问题从"加一个按钮"变成了
"加一块能识别轻点的手势面"，而这块面又要和滚动共存。

---

## 一、为什么不能直接叠两个手势识别器

最直觉的写法是给面板同时挂 `TapGesture` 和 `DragGesture`：

```swift
.gesture(TapGesture().onEnded { confirm() })
.gesture(DragGesture().onChanged { ... })
```

这条路不通，原因是 SwiftUI 里**两个独立的手势识别器会竞争同一个触摸序列**：

- `DragGesture` 的 `minimumDistance` 默认是 10pt。轻点几乎不动，它压根不触发；
- 但一旦手抖超过了 10pt，`DragGesture` 赢下这次竞争，`TapGesture` 就收不到 `onEnded`；
- 更糟的是两个手势的**优先级不确定**，同一个动作在不同设备/系统版本上可能表现不同。

还有一个隐蔽问题：`TapGesture` 与 `DragGesture` 各自维护自己的状态，
"这次触摸到底是点还是拖"这个判定被分散在两个对象里，
**任何一方都无法看到全局**，于是必然出现"既算点了也算拖了"或"两个都不算"的缝隙。

正确的做法是**只挂一个识别器**，由它自己分派：

```swift
DragGesture(minimumDistance: 0)   // minimumDistance: 0 —— 按下即开始
```

`minimumDistance: 0` 是关键：它让识别器从手指**按下**的那一刻就开始收事件，
于是"按下 → 位移 → 抬起"整条序列都在这一个对象手里，
点与拖的判定就有唯一权威。

---

## 二、把判定抽成纯状态机

判定逻辑写在 `View` 里，就带上了 SwiftUI 依赖，脱离模拟器一行都断言不了。
`xcrun simctl` 没有触摸注入 API，Xcode 27 的模拟器 GUI（DeviceHub）也没有
可脚本化的设备窗口 —— 这等于把整条"手指按下 → 产生什么动作"的链路
变成**永久验证盲区**。

所以把它抽出来：`Sources/Core/PadGesture.swift`，只依赖 `CoreGraphics` 与 `Foundation`。

```swift
struct PadGesture {
    enum Action: Equatable {
        case pointer(CGPoint)   // 归一化落点（触控板用）
        case scroll(CGFloat)    // 归一化纵向增量
        case tap                // 点击确认
    }

    private enum Phase: Equatable { case idle, touching, dragging }
    private var phase: Phase = .idle
    private var startTime = Date.distantPast
    private var lastTranslation = CGSize.zero

    static let slop: CGFloat = 8
    static let tapMaxDuration: TimeInterval = 0.4

    mutating func moved(translation:location:time:padSize:
                        mapsPointer:isScrollEnabled:) -> [Action]
    mutating func ended(time: Date) -> [Action]
    mutating func cancelled()
}
```

视图侧只剩转发，一行业务判断都没有：

```swift
DragGesture(minimumDistance: 0)
    .onChanged { perform(gesture.moved(translation: $0.translation, location: $0.location,
                                       time: $0.time, padSize: size,
                                       mapsPointer: mapsPointer,
                                       isScrollEnabled: isScrollEnabled)) }
    .onEnded { perform(gesture.ended(time: $0.time)) }
```

三个状态：

```
idle ──按下──▶ touching ──位移越过 slop──▶ dragging
                 │                            │
                 └──抬起（时长 ≤ 0.4s）→ tap   └──抬起 → 什么都不做
```

---

## 三、四个容易写错的地方

### 1. slop 内的位移必须被吃掉，不能补发

越过 slop 的那一帧**不产生滚动**，并且把当前累计位移记为基准：

```swift
guard phase == .dragging || Self.exceedsSlop(translation) else { return actions }
if phase != .dragging {
    phase = .dragging
    lastTranslation = translation   // ← 吃掉 slop 内的位移，不补发
    return actions
}
```

不补发是"起手不跳"的前提。反过来如果先按累计位移滚一次，
那么**每次轻点都会顺带把画面推走 8pt** —— 因为轻点的手指几乎不可能绝对静止。

### 2. 逐帧增量必须用累计位移之差

`DragGesture.translation` 是**累计值**（从按下算起），不是帧增量。
直接拿它当增量，滚动速度会随拖拽时长线性放大：

```swift
let delta = CGSize(width:  translation.width  - lastTranslation.width,
                   height: translation.height - lastTranslation.height)
lastTranslation = translation
```

断言里专门有一条守这个：40 步粗采样滚完，总滚动量不得超过实际位移。

### 3. 横向分量刻意忽略，但不拦截

只取 `delta.height`，`delta.width` 直接丢掉：

```swift
if isScrollEnabled, delta.height != 0 {
    actions.append(.scroll(delta.height / padSize.height))
}
```

需求原话「左右可以」，意思就是横向不参与滚动。但**不能因此判定"斜拖不算拖动"** ——
手指斜着划是常态，若因为横向分量非零就拒绝滚动，手感会非常粘。
所以横向只是不产生输出，不影响状态推进。

### 4. 轻点要求按下时长 ≤ 0.4s

空鼠瞄准时，手指自然搭在面板上是很常见的姿态。如果"按住很久再抬手"也算点击，
那么每次调整姿态都会误触发一次确认 —— **误触发比漏掉更让人恼火**，因为它会打断正在做的事。

```swift
mutating func ended(time: Date) -> [Action] {
    defer { reset() }
    guard phase != .dragging,
          time.timeIntervalSince(startTime) <= Self.tapMaxDuration else { return [] }
    return [.tap]
}
```

另外 `cancelled()` 只 reset、**不产生点击**：系统取消手势（来电、切后台）
不是用户的确认意图。

---

## 四、两块采集面，一份逻辑

触控板和空鼠栏各有一块 `GesturePad`，差别只有三个参数：

| 参数 | 触控板 | 空鼠栏 |
| --- | --- | --- |
| `hints` | 四条（含捏合提示） | 三条（含"抬手转动手机"） |
| `height` | 自适应 | 固定 120pt |
| `mapsPointer` | `true` —— 落点画成橙色光标环 | `false` —— 光标归陀螺仪管 |

### 4.1 上下滑动这条链路，两块面完全一致

需求第一句是「空鼠部分也需要支持手势上下滑动」。这条链路上两块面**没有任何差异**：

```
手指上下拖
   │
   ▼  DragGesture(minimumDistance: 0)          GesturePad
translation（累计）
   │
   ▼  delta = translation - lastTranslation     PadGesture
归一化 delta.height / padSize.height
   │
   ▼  .scroll(dy)
RemoteControl.scroll(by:)                      RemoteControl
   │
   ▼  position -= dy（clamp 到 -rawLimit...1）
scroll / pull（计算属性）
   │
   ▼  plan.scroll.contentOffset(scroll:pull:)   ExternalDisplayRootView
.offset(y:)
```

slop、归一化分母（采集面**自身**高度）、逐帧增量算法、方向约定，全是同一份代码。
做成一个视图而不是复制两份，就是为了让两处的手感**必然**一致 ——
复制的话迟早有一处被改了分母而另一处没跟上，而症状（"空鼠栏滑得比触控板快"）
离原因（另一个文件里的一行除法）很远。

顺带说一句归一化分母的选择：用**采集面自身高度**而不是外接屏高度。
两者尺寸差一个数量级（120pt vs 1080p），但 `RemoteControl.position` 存的是
**进度**（`0...1`）而不是像素 —— 所以分母用哪块屏的尺寸都不影响最终结果，
用采集面高度只是让"拖过整个面板 = 拖过整屏"这个手感更直白。

### 4.2 两路输入怎么隔离

空鼠跑着的时候，「抬手转手机 → 激光移动」和「手指在面板上上下滑 → 滚动」
是**可以同时发生**的（一只手举着转、另一只手滑）。两者不打架，靠的是一条硬约束：

```swift
GesturePad(..., mapsPointer: false, ...)   // 空鼠栏
```

`mapsPointer: false` 让这块面**只产生 `.scroll`，永不写 `RemoteControl.pointer`**；
而激光指针由 `AirMouse` 独占写入（每次调用都带 `source: .airMouse`）。
两条互斥路径写同一个字段，谁都不会覆盖谁。

反过来说：如果空鼠栏也用默认的 `mapsPointer: true`，手指一碰面板
激光就会**瞬移到手指落点**，与陀螺仪的姿态控制互相抢，
表现是"瞄准时激光乱跳"——很容易被当成陀螺仪噪声去查错方向。

注意这个开关**只影响落点，不影响轻点** —— 断言里单独守了这条
（`mapsPointer = false 不影响轻点`）。落点映射是**立即**的、不受 slop 约束，
而 slop 只管滚动；两者在同一个状态机里分开处理。

### 4.3 确认动作分情况

空鼠栏的确认动作还要分情况：空鼠在跑就走 `airMouse.trigger()`（计入扳机计数，
和按扳机是同一条路径），没跑就退回 `remote.tap()` ——
免得这块面板在空鼠没启动时变成哑巴。

```swift
private func confirm() {
    if airMouse.isRunning { airMouse.trigger() } else { remote.tap() }
}
```

---

## 五、验证

### 5.1 纯函数断言

`PadGesture` 可以和 `WaterfallLayout` / `DisplayScrollGeometry` / `StarfieldModel`
一起用 `swiftc` 独立编译（都只依赖 `CoreGraphics` + `Foundation`）：

```sh
xcrun swiftc -O Sources/ExternalDisplay/WaterfallLayout.swift \
      Sources/ExternalDisplay/DisplayScrollGeometry.swift \
      Sources/ExternalDisplay/StarfieldModel.swift \
      Sources/Core/PadGesture.swift \
      .scratch/verify/main.swift -o .scratch/verify/verify
```

第 9 节「单指手势状态机」共 **27 条**，覆盖：

| 组 | 条数 | 守什么 |
| --- | --- | --- |
| 轻点判定 | 5 | 不动→1 次点击；按住 > 0.4s → 0 次；拖动过 → 0 次 |
| slop 边界 | 4 | 恰好 8pt 不算越界；越界那一帧不滚；起手不跳 |
| 逐帧增量 | 5 | 总量 ≤ 实际位移；粗/细采样只差一个死区；方向正确 |
| 方向 | 3 | 上滑为负；纯横向不滚；斜拖照样滚 |
| 落点 | 3 | 夹进 0...1；`mapsPointer = false` 不产生落点但不影响轻点 |
| 开关与取消 | 4 | 捏合中拖动不滚；取消后抬起不算点击 |
| 退化输入 | 3 | `padSize` 为 0 不除以 0；正常尺寸按下即有动作 |

总数 162 条全过（另加瀑布流/滚动几何/星海三块）。

### 5.2 逐状态截图

新增 `-dockState=expanded,airMouse` 启动参数（`Sources/Debug/MockDockState.swift`），
让遥控台的"展开 + 指定模式"可以脚本化预置。三张截图确认：

- `dock2-airmouse.png` —— 空鼠栏三行 + 手势面完整可见
- `dock2-trackpad.png` —— 触控板栏
- `dock2-collapsed.png` —— 收起态

### 5.3 构建

`xcodebuild build` 零错误零告警。

---

## 六、踩坑

### 1. 把有分支的判定逻辑留在视图里 = 永久验证盲区

手势的「slop 边界 / 轻点 vs 拖动 / 逐帧增量」全是纯逻辑，
但写在 `View` 里就带上了 SwiftUI 依赖，脱离模拟器一行都断言不了。
抽成 `PadGesture` 之后，同一段逻辑立刻可以喂事件断言（本次新增 27 条）。

> 判据很简单：**这段逻辑有没有 `if`？有的话就该问一句"它能不能被断言"。**

### 2. 给手势加新功能时顺手改了视图结构，却没重新核对跨视图的几何假设

**现象**：给空鼠栏加了手势面之后，「触控板 / 空鼠」切换器被模拟外接屏窗口遮住。

**链路**：空鼠栏加了一块手势面 → 遥控台展开后变高 → 替身窗口仍按老的
固定预留量（`reservedBottom: CGFloat = 96`）摆位 → 窗口下沿压到切换器上。

**修复**：`MockExternalDisplay` 新增 `dockHeight` + `reserveBottom(_:)`，
`RemoteControlDock` 用 `GeometryReader` 实测自身高度并上报，高度一变就重新摆位。

```swift
private var heightReporter: some View {
    GeometryReader { proxy in
        Color.clear
            .onAppear { report(height: proxy.size.height) }
            .onChange(of: proxy.size.height) { _, height in report(height: height) }
    }
}
```

改动本身没问题，是**别人的常数**失效了。

> 一般化的教训：凡是"某个视图的高度/宽度被别人当作常数依赖"的地方，
> 都应该改成**实测上报**。写死的预留量在任何一个子视图长高之后都会变成 bug，
> 而且症状（被遮挡）离原因（另一个文件的常数）很远，很难顺着报错找回来。

### 3. 高度上报要防抖

`reserveBottom` 里加了 `abs(height - dockHeight) > 0.5` 的门槛：

```swift
func reserveBottom(_ height: CGFloat) {
    guard height > 0, abs(height - dockHeight) > 0.5 else { return }
    dockHeight = height
    layout()
}
```

`GeometryReader` 的高度回调可能在同一帧内反复触发（尤其是展开动画期间），
没有门槛就会不停重摆窗口、跟着动画抖。

---

## 七、已知限制

1. **"手势能不能被识别到"这一层仍然只能手点**。`PadGesture` 覆盖的是
   "识别到之后产生什么动作"，SwiftUI 的手势分发本身（`GesturePad` 的
   `simultaneousGesture` 会不会被祖先吞掉）没有自动化手段。
2. **捏合与单指拖动是 `simultaneousGesture` 共存**。目前靠
   `isScrollEnabled: !isMagnifying` 在捏合期间关掉滚动来回避冲突，
   但没有断言守这条 —— 它依赖 `MagnifyGesture` 与 `DragGesture` 的实际分发行为。
3. **0.4s 的轻点上限是拍的**，没有实测数据支撑。若真机上手感偏紧，这个值应该调。
4. **空鼠栏手势面高度固定 120pt**，没有按可用高度自适应。
