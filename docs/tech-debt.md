# 技术债

> 规矩：每条都要有**实测证据**。没有证据的判断先放「待验证」，别当结论用 ——
> 这个仓库已经吃过一次亏（把 `sandbox_apply` 的退出码 71 当成"不允许嵌套沙箱"）。

---

## TD-001 · 远程网页的音频录不进成片（整条数字静音）

- **状态**：已实测量化，未解
- **影响面**：数据源换成远程网站之后的所有录制（当前是 B 站视频页）
- **登记时间**：2026-10-22

### 现象

成片**有** AAC 音轨，声道、采样率、时长全都正常，但整条是数字静音。

### 实测证据（2026-10-22 23:52，iPhone 16 Pro）

同一台设备、同一条录制链路，**只换页面源**：

| 成片 | 音轨 | 时长 | mean_volume | max_volume |
| --- | --- | --- | --- | --- |
| 本地页 `recording-20261022-234048.mp4` | AAC 48k 立体声 | 20.05 s | **−20.2 dB** | −2.6 dB |
| B 站远程页 `recording-20261022-234925.mp4` | AAC 48k 立体声 | 31.06 s | **−91.0 dB** | −91.0 dB |

复现：

```sh
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.jove.externaldisplaydemo \
  --source Library/Caches/Recordings/<file>.mp4 --destination /tmp/sample.mp4

ffmpeg -hide_banner -nostats -i /tmp/sample.mp4 -af volumedetect -f null - 2>&1 \
  | grep -E "mean_volume|max_volume"
```

### 结论（两句话，别读错）

- **不是"没有音轨"**：`RecordingWriter` 的 `.audioApp` 分支照常收、照常写，
  所以容器里有一条完整音轨，时长也对得上。只看 `ffprobe` 会误判成"音频没问题"。
- **是采样全 0**：−91.0 dB 是 AAC 全零采样的典型读数，不是"很小声"。
- 根因：WKWebView 的媒体音频在**独立的 WebContent 进程**里渲染，不在 app 进程的
  `AVAudioSession` 上 ⇒ ReplayKit 的 `.audioApp` 取不到它。

### 为什么现有的本地页方案不能直接沿用

本地页的做法是「页面 `<video>` 静音 + app 进程内用 `AVPlayer` 播同一份 mp4」，
成立的前提是**同一份素材**。远程页面的素材在站点服务器上，本地那份 `video.mp4`
跟它内容完全不同，拿它出声只会音画全错。所以 `DemoFlow.handle(.started)` 用
`page.isRemote` 短路掉了 `PageAudio` —— 宁可静音，不要错位。

### 可能的方向（都未验证，按代价排序）

| 方案 | 代价 | 风险 |
| --- | --- | --- |
| 解析站点流地址，用 `AVPlayer` 在进程内播同一条流 | 要处理签名/防盗链，站点一改就坏 | 高 |
| 录完再合成：视频轨用录制产物，音频轨单独下载后混流 | 要两路时间对齐；仍要解析流地址 | 中 |
| 接受无声，音频作为独立产物（导出时再合并） | 无 | 低 |
| 等系统开放"采集其它进程音频"的公开 API | 无 | 不可控 |

### 验收标准（解了之后怎么证明）

同一段远程视频、同一条链路录两遍：

1. `volumedetect` 的 `max_volume` 应 > −6 dB（不是 −91）；
2. 与原视频对应片段的音频做互相关，峰值要落在零延迟附近 —— **只验"有声音"不够**，
   音画错位照样算没解。
