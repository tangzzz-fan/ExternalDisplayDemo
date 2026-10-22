# 录制管线：从 HTML 播放到外接屏实时预览

记录 `Sources/Flow` 这条链路（WKWebView 播 mp4 → ReplayKit 采集 → 落盘 + 外接屏实时预览）
在真机上踩过的坑。每个坑都写清「症状 → 怎么定位 → 真因 → 怎么改 → 下次怎么避免」，
目的是下次不要再花一遍时间。

- 验证机型：iPhone 16 Pro / iOS 18.0
- 模拟器：iPhone 18 Pro / iOS 27（**只能验证一半，见第八节**）

---

## 零、管线长什么样

```
手机屏                                 外接屏（非交互）
┌──────────────┐                      ┌────────────────┐
│ 手势面        │── 归一化坐标 ──▶     │ 按钮页 / 光标   │
│ WKWebView    │   RemoteControl      │ 实时预览        │
│  play mp4    │                      │ 回放            │
└──────┬───────┘                      └───────▲────────┘
       │ ReplayKit.startCapture               │
       ▼                                      │
  CMSampleBuffer ──┬── 原 buffer ──▶ RecordingWriter ──▶ mp4
                   │                                      │
                   └── 复制包装 ──▶ LivePreviewRelay ──▶ 显示层
                                                          │
                                          AVPlayerLooper ─┘
```

两条硬约束，后面所有设计都是被它们逼出来的：

1. **外接屏的 role 是 `windowExternalDisplayNonInteractive`，系统不投递任何触摸。**
   所以命中判定必须在手机侧做（`GlassesLauncherLayout.hitTest`），外接屏只负责画。
2. **实时预览不能用 `AVPlayer`。** AVPlayer 需要一个可 seek 的 item，得先落盘或拼 HLS，
   延迟至少几百毫秒。要「来一帧画一帧」只能用 `AVSampleBufferDisplayLayer`。

---

## 一、症状速查

| 症状 | 真因 | 改在哪 |
| --- | --- | --- |
| 外接屏播到 3 秒卡住，成片只有 2–3 秒 | 启动超时里 `stopCapture` 无条件执行 | `ScreenCapture.start()` |
| 手机完全没有声音 | seek 打断 `play()` 抛 `AbortError`，被当成自动播放被拒 → 静音兜底 | `index.html` `startPlayback()` |
| 手机有声音但外接屏那路还是静音 | `startCapture` 重配 `AVAudioSession`，把 `.playback` 顶掉 | `ScreenCapture.start()` |
| 替身屏（mock）突然消失 | 删字段时把 `install()` 里唯一的 `isHidden = false` 一起删了 | `MockExternalDisplay.install()` |
| 手机状态栏出现 `1086 × 610 px @3.̶0̶ 秒…` 这种乱码 | 分辨率与状态拼成一行后 `.lineLimit(1)` 中截断 | `PhoneRootView.statusBar` |
| 成片有音轨但整条 −91 dB | **未解决**，见第七节 | — |

---

## 二、坑 1：录制只到 2–3 秒

### 症状

外接屏实时预览播到第 3 秒左右画面冻住，计时还在走；拉回成片一测，四条都是 2.0–3.0 秒。

### 怎么定位的

分两步，第一步就把范围砍掉一半：

1. **先测落盘文件的时长。** 成片只有 2–3 秒，说明**录制在 3 秒就结束了**，
   而不是显示层卡住 —— 上游断了和下游停了是两件事，先用一个 `ffprobe` 分开。
2. **再打日志看采样回调。** 每 60 帧打一次 `pts`，结果是：

   ```
   [Capture] video frames=60  pts=2368858.47
   [Capture] video frames=120 pts=2368859.47    ← 之后彻底不来
   [Flow] event ended t=20.57                    ← 页面照常播满 20 秒
   [Flow] finishCapture t=20.57 duration=20.03
   ```

   页面播了 20 秒，采样流 2 秒就断了。问题在 ReplayKit 那一侧被谁掐了。

### 根因

`ScreenCapture.start()` 里为模拟器加的超时：

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + Self.startTimeout) {
    result.finish(.failure(Failure.startFailed("启动超时，未收到系统回调")))
    recorder.stopCapture { _ in }      // ← 无条件执行
}
```

`result.finish` 是幂等的（continuation 已经 resume 过就什么也不做），但 `stopCapture`
没有这层保护。**启动成功了，4 秒到点照样把录制停掉。**

### 为什么只录到 2–3 秒，不是 4 秒

这 4 秒从 `startCapture` **调用**那一刻算起，而真正开始出帧是在用户点掉系统授权框之后。
采样起点比这个窗口晚 1–2 秒，所以实际只拿到 2–3 秒素材。

### 为什么模拟器一直没暴露

模拟器根本不走这条路：

```swift
static var isSupported: Bool {
    #if targetEnvironment(simulator)
    return false            // 模拟器的 isAvailable 会撒谎，回调永远不来
    #else
    return RPScreenRecorder.shared().isAvailable
    #endif
}
```

`beginCapture()` 在模拟器上直接走 `SimulatedCapture` 分支，这段真机代码一次都没被执行过。

### 修复

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + Self.startTimeout) {
    guard result.finish(.failure(...)) else { return }   // 只有真超时才收
    recorder.stopCapture { _ in }
}
```

`finish` 改成返回 `Bool`：谁先抢到 continuation 谁说了算。同时把反方向也堵上 ——
超时已判失败后 completion 才迟到时，要把这次录制 `stopCapture` 收回去，
否则会留下一个没人接管的采样流：

```swift
} completionHandler: { error in
    let outcome: Result<Void, Error> = error.map {
        .failure(Failure.startFailed($0.localizedDescription))
    } ?? .success(())
    if !result.finish(outcome) { recorder.stopCapture { _ in } }
}
```

超时值也从 4 秒提到 30 秒 —— 系统授权框要人点，人工操作远不止 4 秒。

修复后实测：`frames=1260`、成片 **20.66 秒**、6.6 Mbps。

### 教训

- **兜底逻辑里不要放有副作用的操作。** 「超时就取消」这种句子，必须和「是否真的超时」
  绑在同一个判断里。
- 这个超时本身就不该存在。真机上 `startCapture` 的 completion 一定会回调（成功或报错），
  超时只该兜「永远不回调」这种病态情况；它当初被加进来，纯粹是因为模拟器的
  `isAvailable` 会撒谎。**正确做法是让模拟器根本不进这条路**，超时只留作最后一道保险。

---

## 三、坑 2：手机完全没声音

### 症状

录制过程中手机扬声器一点声音都没有，成片音轨全零。

### 根因

`beginCapture()` 的顺序是 `page.rewind(); page.play()`。`rewind()` 里的
`player.currentTime = 0` 会触发 seek，seek 打断了紧接着的 `play()`，抛 `AbortError`。

原来的兜底把**任何** `play()` 失败都当成「自动播放被系统拒绝」，于是静音重试：

```js
attempt.catch(function (err) {
  mutedFallbackUsed = true;
  player.muted = true;          // ← AbortError 也被静音了
  ...
});
```

静音播放当然没有声音，`.audioApp` 采到的自然也是零。

### 修复

只有 `NotAllowedError`（真的被策略拒绝）才静音；`AbortError` 是瞬时状态，定时重试：

```js
if (name === 'AbortError' && retries < 20) {
  retries += 1;
  setTimeout(function () {
    if (autoplay && player.paused) { startPlayback(); }
  }, 150);
  return;
}
```

### 反面写法（也踩过）

第一版改成「等 `seeked` 事件再播」：

```js
if (player.seeking) {
  player.addEventListener('seeked', function () { ... }, { once: true });
  return;                        // ← seeked 不来就永远不播
}
```

`seeking` 为真但 `seeked` 不触发时，播放永远不会开始 —— 实测结果是一条全黑的成片。
**定时重试比等事件稳**：事件可能因为页面不可见、WebKit 内部状态等原因不投递。

---

## 四、坑 3：startCapture 会重配音频会话

### 症状

坑 2 修完，手机有声音了，但成片音轨还是全零。

### 根因

`startCapture` 起采集时会重配 `AVAudioSession`，把 app 先设好的
`.playback / .moviePlayback` 顶掉。之后 WKWebView 的媒体音落到 ambient 上
（手机静音开关一开就彻底没声），`.audioApp` 送来的采样也全是 0。

### 修复

采集已经起来之后，再把会话要回来：

```swift
self.writer = writer
isRunning = true
try? activateAudioSession()      // 再设一次
```

修完手机确实有声音了（用户确认）。

---

## 五、坑 4：替身屏（mock）突然消失

### 症状

用户没有操作，外接屏替身窗口凭空消失。状态栏却仍显示 `1086 × 610 px @3.0x`
—— 说明 `ExternalDisplayMonitor` 还挂着 mock 附件，不是 `uninstall()`。

### 误判过程（值得记下来）

看到「窗口没了但附件还在」，第一反应是「窗口在后台被系统拆掉，`bootstrap()`
只在 `isVisible == false` 时才重建，所以永远回不来」，于是去改 `bootstrap()`。
**这个方向是错的。**

真因简单得多：删 `isSuppressedForCapture` 字段时，把 `install()` 里唯一一处
`mockWindow.isHidden = false` 一起删掉了。新建的 `UIWindow` 默认隐藏，
所以窗口从来就没显示过 —— 而 `bootstrap()` 那边看到 `isVisible == true`，
以为一切正常。

### 修复

```swift
mockWindow.rootViewController = UIHostingController(rootView: ExternalDisplayRootView())
mockWindow.isHidden = false      // 补回来
window = mockWindow
```

顺带做了两件相关的事：

- 替身屏改成 **DEBUG 构建默认挂载**（`-noMockExternalDisplay` 可关）。原来必须带
  `-mockExternalDisplay` 才生效，结果只有命令行拉起才有，点图标进来整块外接屏都没了。
- `bootstrap()` 在已有 `.physical` 附件时跳过，避免真接了眼镜还叠一个替身。

### 教训

**先看窗口自己的 `isHidden`，再看状态栏有没有附件，最后才怀疑 scene 生命周期。**
「附件还在」只能证明没走 `uninstall()`，证明不了窗口可见。

---

## 六、坑 5：状态栏文本被截断成乱码

`detailText` 把分辨率和状态拼成一行，再套 `.lineLimit(1)` + `.truncationMode(.middle)`：

```
1086 × 610 px @3.̶0̶ 秒，已在眼镜屏播放
```

中间被截掉，两段文字叠在一起。改成标题 / 分辨率 / 状态三行，各自独立 `lineLimit`。

---

## 七、未解决：成片音轨是数字静音

### 证据

- 视频：884×1920、6.6 Mbps、20.7 秒、1278 帧 —— 全部正常
- 音频：970 帧、正好铺满 20.8 秒（48kHz / 1024 帧每包），但 `volumedetect` 是 **−91 dB**
- 手机扬声器确实有声音

音频包数量与时长严丝合缝，说明 ReplayKit 真的在送音频，只是内容全是 0。

### 已排除写入器

新增 `testAudioSurvivesWriter`：喂 440 Hz 正弦，回读 PCM 断言峰值 > 0.05，通过。
原来那条 `testAudioAndVideoStartTogether` 的音频是 `memset 0` 的，所以查不出静音 ——
顺手把 helper 改成写正弦。

### 推断

ReplayKit 的 `.audioApp` 拿不到 WKWebView 的媒体音频。WebKit 的音频在
WebContent / GPU 进程渲染，不在 app 进程的音频 tap 上。

### 三条候选路

1. **接受无声** —— 画面完全正确，演示够用
2. **用 `AVPlayer` 在 app 内另播一路同源音频**（能被 tap 到），与 webview 画面手工对齐 ——
   音画可能漂移
3. **把播放器从 WKWebView 换成 `AVPlayer`** —— 放弃「HTML 页面包装 mp4」这个前提

---

## 八、可复用的调试手法

### 先看落盘文件，别看现象

「卡住」可能是上游断了，也可能是下游停了。拉回成片测时长，一步就能分开：

```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.jove.externaldisplaydemo \
  --source Library/Caches/Recordings --destination /tmp/recs
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1 /tmp/recs/*.mp4
```

### devicectl 的几个坑

- 传启动参数必须加 `--`，否则 `-mockXxx` 会被 devicectl 当自己的选项解析，
  报 `Missing value for '-t'`。
- 截图：`devicectl device capture screenshot --destination x.png`
- 录屏：`devicectl device capture screen-record --destination x.mp4`（**只认 .mp4**；
  本机被 `com.apple.coredevice.feature.screenrecording` 能力拒绝，没用上）
- **每次 `devicectl install` 都会重弹「允许屏幕捕捉」**，必须人工点，脚本化不了。
  调试期尽量减少安装次数，把改动攒在一起装。

### 模拟器验证不了什么

- ReplayKit 整条链路（`isAvailable` 撒谎，回调不来）
- 音频路由与 `.audioApp`
- 真机录制的分辨率/朝向（ReplayKit 会按 0.733 缩，884×1920）

模拟器上跑的是 `SimulatedCapture`：用 `AVAssetReader` 按 PTS 节拍把同一段 mp4 解码成
`CMSampleBuffer`，走**和真机完全相同**的下游（relay → 显示层）。它能验证预览与回放，
**验证不了采集**。

---

## 九、门禁

`xcodebuild test`，5 项：

| 用例 | 守什么 |
| --- | --- |
| `testFinishProducesPlayableVideo` | 成片能播、尺寸对、时长在预期区间 |
| `testFinishWithoutSamplesFails` | 空录制要抛错且不留残留文件 |
| `testCancelRemovesFile` | 取消要删文件 |
| `testAudioAndVideoStartTogether` | 音视频轨道同时起、起点差 ≤50ms、时长差 ≤0.1s |
| `testAudioSurvivesWriter` | 音轨不是静音（峰值 > 0.05） |

---

## 十、素材

`Resources/VideoPage/video.mp4`：1080×1920 / 20 秒 / H.264 + AAC 立体声 48kHz，
由 video.js 演示素材 `oceans.mp4` 的第 14–34 秒重制（模糊背景铺满 + 原画等比居中）。

**授权未核实**：`oceans.mp4` 是 video.js 的演示素材，没找到明确授权声明。
只在本机 demo 用没问题，要外发就换成 Big Buck Bunny（CC-BY 3.0）或自拍素材。

