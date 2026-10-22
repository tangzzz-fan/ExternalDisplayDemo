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
┌──────────────────┐                  ┌────────────────┐
│ 手势面            │── 归一化坐标 ──▶ │ 按钮页 / 光标   │
│ WKWebView 站点页  │   RemoteControl  │ 实时预览        │
│ 文字 + 视频        │                  │ 回放            │
└──────┬───────────┘                  └───────▲────────┘
       │ 播放键 → playrequest → startCapture    │
       ▼                                        │
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
| 手机有声音但外接屏那路还是静音 | `startCapture` 重配 `AVAudioSession`，把 `.playback` 顶掉；**采集侧仍是零，见第七节** | `ScreenCapture.start()` |
| 替身屏（mock）突然消失 | 删字段时把 `install()` 里唯一的 `isHidden = false` 一起删了 | `MockExternalDisplay.install()` |
| 手机状态栏出现 `1086 × 610 px @3.̶0̶ 秒…` 这种乱码 | 分辨率与状态拼成一行后 `.lineLimit(1)` 中截断 | `PhoneRootView.statusBar` |
| 成片有音轨但整条 −91 dB | WKWebView 的音频在别的进程渲染，ReplayKit 的 `.audioApp` 采不到 | 声音改由 `PageAudio` 在进程内播，见第七节 |
| 录制在 13 秒左右自己收工，成片比素材短 | 兜底 deadline 写死 12 秒，而 `loadedmetadata` 还没到 | `DemoFlow.scheduleDeadlineStop()`，见第十一节 |
| 录制点第二次不呼吸了 | 复用 `isPulseOn == true`，`onAppear` 置同值不触发动画 | `ExternalDisplayRootView`，见第十一节 |
| 站点封面是一块纯黑，还以为是加载失败 | WKWebView 没播过就不画首帧，挪 `currentTime` 也不一定画 | `index.html` `primePoster()`，见第十二节 |

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

修完手机确实有声音了（用户确认）。但**这只解决了「手机能听见」**，
采集侧仍然是静音 —— 那是另一回事，见第七节。

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

## 七、坑 6：成片音轨是数字静音

### 证据

- 视频：884×1920、6.6 Mbps、20.7 秒、1278 帧 —— 全部正常
- 音频：970 帧、正好铺满 20.8 秒（48kHz / 1024 帧每包），但 `volumedetect` 是 **−91 dB**
- 手机扬声器确实有声音（第四节修完之后）

音频包数量与时长严丝合缝，说明 ReplayKit 真的在送音频，只是内容全是 0。

### 已排除写入器

新增 `testAudioSurvivesWriter`：喂 440 Hz 正弦，回读 PCM 断言峰值 > 0.05，通过。
原来那条 `testAudioAndVideoStartTogether` 的音频是 `memset 0` 的，所以查不出静音 ——
顺手把 helper 改成写正弦。

### 真因

**WKWebView 的媒体音是 WebKit 在 WebContent / GPU 进程里渲染的**，
ReplayKit 的 `.audioApp` 只 tap 到 app 进程自己的音频，所以它送来的全是零。
第四节把 `AVAudioSession` 要回来，只让「手机能听见」，并不能让 tap 看见。

### 修法：把声音搬进 app 进程

页面那边把 `<video>` 常静音，只留画面；声音由 `Sources/Flow/PageAudio.swift` 用
`AVPlayer` 播同一份 mp4（不挂 layer，只出声）。进程内的音频走 app 的 `AVAudioSession`，
这才落在 ReplayKit 的采集范围内。

音画对齐靠页面报点：首帧真正上屏时，`requestVideoFrameCallback` 给出 `mediaTime`，
原生侧按它 `seek` 之后再播（`mediaTime < 0.3` 就不 seek，省掉几十毫秒的 seek 延迟）。

```js
if (!startedPosted && !player.paused) {
  startedPosted = true;
  post('started', { mediaTime: metadata.mediaTime });
}
```

副作用是顺带删掉了「自动播放被拒就静音」那套兜底 —— 画面本来就是静音的，
`play()` 不会被策略拦，整个失败模式消失了。

### 结果

| 指标 | 修前 | 修后 |
| --- | --- | --- |
| 平均音量 | −91.0 dB | **−20.2 dB** |
| 峰值 | −91.0 dB | **−2.2 dB** |
| 音频码率 | 2.2 kbps（静音） | **125.5 kbps** |
| 音轨起点 | — | 视频起点 +14.6 ms |
| 时长 | 20.7 s | 20.11 s |

`silencedetect` 在 −40 dB 阈值下找不到任何静音段，说明整条都有内容。

### 教训

**「播放成功」和「被采集到」是两件事。** 音频在哪个进程渲染，决定了谁能 tap 到它。
遇到「有音轨但全是零」，先问「这份声音是谁在渲染」。

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

---

## 十一、review 补的四个坑（真机上还没踩到，逻辑上必踩）

前六条都是真机实测出来的。这四条是事后按代码路径推的 —— 都能在特定时序下发生，
所以先记下来。

### 坑 7：兜底 deadline 把成片截在 13 秒

`scheduleDeadlineStop()` 原来写的是 `videoDuration > 0 ? videoDuration : 12`，
而 `videoDuration` 来自页面的 `loadedmetadata`。

`beginCapture()` 只等 `ready`（脚本末尾同步发出），`loadedmetadata` 是视频元数据解析完之后
才发的，**两者没有先后保证**。真机上开录要先过系统授权框，通常来得及；但素材解析慢
（冷启动第一次读 moov）、或者授权框早就允许过、点击到开录只有几十毫秒时，
`videoDuration` 还是 0 → deadline 按 12 秒排 → 20 秒素材在 13.2 秒被 `finishCapture()` 收掉，
**没有任何报错**，症状和第二节「只录到 2–3 秒」几乎一样。

改法两头都堵：

```swift
// 兜底值只兜「loadedmetadata 永远不来」，不再假装自己是正常时长
private static let unknownDurationLimit: Double = 60

// metadata 到位后重排一次
case .metadata(let duration, _):
    videoDuration = duration
    if phase == .capture, isCapturing { scheduleDeadlineStop() }
```

教训：**兜底值不能同时承担「正常值」和「病态值」两个角色。** 一旦兜底值比正常值小，
它就变成了一个静默的截断器。

### 坑 8：`ended` 有两个来源，逐帧链有两条

`index.html` 里结束有两条来源：DOM 的 `player.addEventListener('ended')`，
和 `requestVideoFrameCallback` 里按 `mediaTime >= duration - 0.08` 判定。
两条都直接 `post('ended')`，原生侧靠 `guard phase == .capture, isCapturing` 挡掉第二次 ——
**靠下游守卫兜住上游的重复**，不是幂等。

顺带发现同一段里逐帧链被起了两次：脚本末尾 `watchFrames()` 一次，`rewind()` 又一次
（因为原来链在 `endPosted` 为真时就掐断，`rewind()` 得重起）。同一次播放里两条链并存，
每帧回调走两遍。

改法：

```js
function postEnded(mediaTime) {
  if (endPosted) { return; }
  endPosted = true;
  post('ended', { duration: player.duration, mediaTime: mediaTime });
}
```

逐帧链改成**永不断链**（暂停时 rVFC 本来就不触发，继续播自己接上），入口用 `watching` 去重。

教训：**同一个事实只能有一个上报口。** 谁先到不重要，重要的是第二条被上报函数自己挡掉，
而不是指望消费者幂等。

### 坑 9：停止采集没有超时

`start()` 在第二节已经补了 30 秒超时（授权框要人点），`stop()` 却是裸等：

```swift
await withCheckedContinuation { RPScreenRecorder.shared().stopCapture { _ in continuation.resume() } }
```

回调不来就永远停在「正在生成录制文件」。第二节已经证明这个系统的回调会撒谎/失约，
那么停止侧也得有上界：

```swift
private static let stopTimeout: TimeInterval = 5
```

超时后**照样往下走**，`writer.finish()` 把已经到手的采样收尾成文件 —— 丢尾不丢片。

教训：**给一个异步调用加了超时，就要检查同一条链路上另一半。** 起和停是同一个系统的两次回调。

### 坑 10：启动期间被中止，采样流没人收

`abort()` 里收采样流的条件是 `isCapturing && !isSimulatedCapture`。
而 `beginCapture()` 在 `await capture.start()` 期间 `isCapturing` **还是 false**
（它在 await 之后才置 true）。用户这时点「返回按钮页」→ `abort()` 什么都不收 →
`start()` 返回后照常 `isCapturing = true`、`page.play()`、排 deadline，而 `finishCapture()`
被 `phase == .capture` 挡掉 → **ReplayKit 一直在采，没人停**。

改法：`await` 回来先复查意图，再看要不要继续：

```swift
guard phase == .capture else {
    capture.cancel()
    simulated.stop()
    return
}
```

教训：**跨 `await` 的状态检查要在 `await` 之后重做一遍。** 决定「要不要开始」的是 await 之前的意图，
决定「现在还能不能算开始」的是 await 之后的状态。

---

## 十二、入口挪到页面上：播放键 → 申请录屏 → 全屏播放

### 为什么不是原生按钮

最早的入口是手机端全屏页上叠一个原生「开始录制」按钮，页面在底下。这有两个毛病：

1. **按钮和视频不在同一个坐标系里**，演示时看着像"点了外面的按钮才把里面的东西打开"；
2. 站点页改成「文字 + 视频」之后，原生按钮会盖住内容，而那正是要被录进去的画面。

现在入口就是页面上的那个播放键 —— 一个真的播放键。

### 顺序：先起采集，再让页面全屏播

```
用户点播放键
  → JS post('playrequest')
  → DemoFlow.beginCapture()
  → ScreenCapture.start()（系统弹「允许屏幕捕捉」）
  → 用户点「录屏」
  → window.__page.beginPlayback()              ← 收站点、满屏、从头播
```

**反过来（先全屏播再申请授权）会丢掉开头几百毫秒**，而那几百毫秒正好是用户
最想确认的部分（"我点下去它有没有反应"）。授权框是人点的，等待时间不可控，
所以只能让画面等采集，不能让采集等画面。

### 失败要把按钮还回去

`beginCapture()` 的三条失败路径（页面没就绪 / `start()` 抛错 / 超时）都会走
`failCapture()` → `page.fail(message)`。少了这一步，页面会永远停在
「正在请求录屏」—— 按钮被自己禁用，用户只能退出去重进。

### 音画同步：`play()` 之前必须**真的**回到 0

`player.currentTime = 0; player.play()` 是赌：seek 是异步的，`play()` 可能从旧位置起播，
页面报给原生的 `mediaTime` 就是中间值 —— 声音按它 seek，结果**成片最后几秒没有声音**
（真机实测：缺的秒数正好等于旧位置）。

```js
function rewindToZero() { /* 等 seeked，兜底 400ms */ }
beginPlayback: function () {
  player.pause();
  rewindToZero().then(function () { if (autoplay) { startPlayback(); } });
}
```

修完之后 `started` 的 `mediaTime` 是 `0.000`，19 秒处仍有声。

### 站点封面：`primePoster()`

WKWebView 在没播过之前**可能一帧都不画**，`currentTime = 0.05` 也不保证生效，
封面就是纯黑 —— 看起来像加载失败。

```js
function primePoster() {
  if (requested || startedPosted) { return; }
  var attempt = player.play();
  if (attempt && attempt.then) {
    attempt.then(function () { if (!requested) { player.pause(); } });
  }
}
```

两条约束：**静音短播**（`player.muted = true` 早就设了）；**必须先于用户点击**，
否则 `started` 会被这次预播抢先发出去。

### 横屏：先转再录，不是边录边转

曾经试过"用户授权后手机转横屏，眼镜屏那侧把画面转 90° 并铺满"，整体撤回了一次 ——
不是做不出来，是**顺序错了**。三条事实决定了唯一可行的顺序：

| 事实 | 后果 |
| --- | --- |
| ReplayKit 的缓冲尺寸在 `startCapture` 那一刻就定死 | 转屏之后的画面会以 90° 塞进旧缓冲 |
| 转屏请求 `requestGeometryUpdate` 在真机上**偶发被静默丢弃**（错误回调都不来，`mask` 与各 window 的 `supported` 都正确） | 只能轮询 `interfaceOrientation` 确认 + 重试，不能发完就等 |
| 一条轨道只有一个 transform | 转屏前后的两种朝向无法共存，必须丢帧 |

所以现在走的是 **点播放 → 先转横屏并等到真的转完 → 再 `startCapture`**。
成片从头到尾都是横向的，不需要补矩阵，也不需要丢帧。录制期间方向由
`OrientationLock` 钉死、用户转不动 —— 这是保护，不是体验取舍。

眼镜屏那一侧**不跟着转**：手机怎么转、录出来的帧多宽，它都按 `resizeAspectFill`
铺满自己的 16:9（见 README §四「横屏」）。
