# TimelineKit V6 P4：VideoFrameProvider 性能化阶段评估

> 日期：2026-05-19  
> 范围：`TimelineRenderer + LayerResolver + ImageLayerComposer + VideoLayerComposer` 已验证 mixed timeline 可以脱离 `AVVideoCompositing` 后，评估 `VideoFrameProvider` 从 P3 架构验证版升级为长期实时预览运行时的方案。

---

## 一、评估结论

**P4 必须执行。**

**2026-05-20 实施状态**：P4 主预览链路已从 `AVAssetImageGenerator.copyCGImage` 升级到 source-level `AVPlayerItemVideoOutputProvider`。编辑器主预览与全屏预览均接入 TimelineRuntime preview，且 preview 不允许自动 fallback 到 `AVAssetImageGenerator`。当前已验证：纯视频播放不闪；图片在前、视频在后时视频段可正常进入；播放态 source player 不再逐帧 seek，实测 `seeks=1`；`compositionTime=0` 重复 forced copy 已消失；尾段 stale forced copy 已被拦截。剩余工作是 seek 目标帧 warm-frame / delayed replace 手感优化，以及 P4-E 性能基准。

P3 已经完成最关键的架构验证：视觉输出可以统一进入 `TimelineRenderer.renderFrame(at:)`，并由 `TimelinePreviewView` 展示 `CVPixelBuffer`。但当前视频帧来源仍是：

```
AVAssetImageGenerator.copyCGImage(at:)
  -> CGImage
  -> CIImage(cgImage:)
  -> TimelineRenderer
  -> CVPixelBuffer
```

这条链路适合证明 mixed timeline 能跑通，不适合作为长期实时预览路径。主要问题不是合成器本身，而是视频帧获取方式仍是“逐帧精确截图式解码”，会放大 CPU、内存、seek/replay 抖动和手机发热。

P4 的最终主线已经调整为 source-level provider：

```
VideoLayerSpec(assetURL, sourceStartTime, timeRange)
  -> per-source hidden AVPlayerItem + AVPlayerItemVideoOutput
  -> CVPixelBuffer
  -> CIImage(cvPixelBuffer:)
  -> TimelineRenderer
  -> LayerComposer 合成
```

主 `AVPlayer` 仅负责 audio、clock 和 composition timeline；视频画面不再从 composition item 取最终 canvas frame，而是按每个源视频 asset 解码 source-local pixel buffer，再由 `VideoLayerComposer` 执行 fit / transform / adjustment。这个调整解决了 composition-level output 在“前置 image-only 段、后续 video 段”中无法稳定唤醒的问题。

---

## 二、当前 P3 代码状态

| 模块 | 当前状态 | P4 判断 |
|---|---|---|
| `TimelineRenderer` | 已输出 `CVPixelBuffer`，共享 Metal-backed `CIContext` 和 `CVPixelBufferPool` | 保留，新增 pixel-buffer 视频输入路径 |
| `LayerResolver` | 已把 image/video layer 解析成统一 frame 描述 | 保留 |
| `ImageLayerComposer` | 已提供 image/image_motion/image_3d 的 CIImage 路径 | 保留 |
| `VideoLayerComposer` | 依赖全局 `VideoFrameProviderProtocol`，接收 `VideoFrameImage` | 已接入 `CIImage(cvPixelBuffer:)`，source frame 继续走 fit / segment transform / adjustment |
| `VideoFrameProvider` | legacy `AVAssetImageGenerator` 实现仍保留 | 仅作为 export/debug fallback；preview 主链路禁止自动 fallback |
| `AVPlayerItemVideoOutputProvider` | source-level provider 已落地 | 每个 asset 管理独立 hidden `AVPlayerItem + AVPlayerItemVideoOutput` |
| `CompositionCoordinator` | `CADisplayLink` tick 读取 `player.currentTime()` 后同步 render | 已补 seek/replay 去重、deferred retry、replace frame 生命周期 |
| `FullScreenPreviewController` | 独立 player + TimelineRuntime 输出 | 已补与编辑器一致的 provider 生命周期和 seek/replay 去重 |
| `VideoExporter` | 也临时使用 `VideoFrameProvider` | P4 不强行统一导出；导出 provider 留给 P5 `AVAssetReader` |

---

## 三、为什么 P3 方案不能长期使用

### 3.1 每帧都是精确 seek + decode

当前 `VideoFrameProvider.copyCGImage(at:from:)` 使用同步 API，并把 tolerance 设置为零。这意味着 30fps、15s 的视频层会触发约 450 次精确取帧；如果叠加 `image_3d`、overlay、transition，每个 display tick 都可能同时承受视频 seek/decode、CI 合成和 display layer 入队。

### 3.2 CGImage 路径造成 CPU/GPU 往返

`CGImage` 是 CPU 图像对象。当前路径会把视频解码结果拉到 `CGImage`，再包装成 `CIImage`，最后由 Core Image 渲染进 `CVPixelBuffer`。这比直接从 `CVPixelBuffer` 创建 `CIImage` 多一段不必要的内存和格式转换。

### 3.3 不符合实时播放器的调度模型

`AVAssetImageGenerator` 更适合缩略图、单帧 seek、封面图和非实时截图，不适合作为 60fps runtime 的主视频帧来源。实时预览应让系统播放器持续解码和缓存，Timeline Runtime 在当前时钟点取可用 pixel buffer。

---

## 四、P4 架构方案

### 4.1 新增 provider protocol

新增 `VideoFrameProviderProtocol`，把视频帧来源从 `VideoLayerComposer` 中解耦：

```swift
protocol VideoFrameProviderProtocol: AnyObject {
    func setCanvasSize(_ size: CGSize)
    func setPlaybackActive(_ active: Bool)
    func preload(videoSpecs: [VideoLayerSpec])
    func prepare(for item: AVPlayerItem)
    func frame(for spec: VideoLayerSpec, at compositionTime: CMTime) -> VideoFrameImage?
    func seek(to time: CMTime)
    func flush()
    func invalidate()
}
```

设计要点：

- preview provider 使用 `AVPlayerItemVideoOutput`
- export provider 后续使用 `AVAssetReader`
- legacy provider 可保留 `AVAssetImageGenerator`，只作为 export/debug/thumbnail fallback，不允许在 TimelineRuntime preview 中自动兜底
- `preload(videoSpecs:)` 在 renderer update 后预创建 source output，减少首次进入视频段时 `itemStatus=unknown / duration=nan` 的窗口

### 4.2 新增 `AVPlayerItemVideoOutputProvider`

职责：

- 为每个 source asset 维护独立 hidden `AVPlayerItem + AVPlayer + AVPlayerItemVideoOutput`
- 使用 BGRA pixel buffer attributes，直接输出 `CVPixelBuffer`
- 在 display tick 中由 `VideoLayerSpec.assetURL + sourceStartTime + localTime` 推导 `sourceTime`
- 返回 source-local frame（`isCanvasFrame=false`），由 `VideoLayerComposer` 继续处理 fit / transform / adjustment
- 在用户 seek、replay、replace item 后治理 stale frame；播放态不再逐帧校准 seek
- 首次拿不到帧时返回 nil，并打印 `asset / compositionTime / sourceTime / hasNewPixelBuffer / output status / playerItem status / duration / reason`
- 播放中 `hasNewPixelBuffer=false` 时复用 0.1s 内的上一帧，不回退到 `AVAssetImageGenerator`
- forced copy 仅接受 `displayTime` 接近目标 `sourceTime` 的帧；明显旧帧直接拒绝，避免 seek 后错帧

核心取帧逻辑：

```swift
let sourceTime = spec.sourceStartTime + (compositionTime - spec.timeRange.start)
let source = sourceOutput(for: spec.assetURL)

if didEnterSegment {
    source.player.seek(to: sourceTime, toleranceBefore: .zero, toleranceAfter: .zero)
} else if activePlayback {
    source.player.play()
}

let hasNew = source.output.hasNewPixelBuffer(forItemTime: sourceTime)
if hasNew,
   let pixelBuffer = source.output.copyPixelBuffer(forItemTime: sourceTime, itemTimeForDisplay: &displayTime) {
    lastFrame = (displayTime.isValid ? displayTime : sourceTime, pixelBuffer)
    return pixelBuffer
}
if let lastFrame, abs(lastFrame.time.seconds - sourceTime.seconds) < 0.1 {
    return lastFrame.buffer
}
logFrameMiss(..., hasNewPixelBuffer: hasNew, reason: ...)
return nil
```

对于 pause/seek 后的单帧渲染，可用目标 composition time 转成 source time 后主动取帧；如果 output 尚未 ready 且没有可复用帧，provider 必须返回 nil 并打印明确诊断，不允许自动切回 `AVAssetImageGenerator`。

### 4.3 `VideoLayerComposer` 零拷贝输入

当前：

```swift
let cgImage = provider.copyCGImage(...)
let ciImage = CIImage(cgImage: cgImage)
```

P4 改为：

```swift
let frame = provider.frame(for: spec, at: compositionTime)
let ciImage = frame.image
```

后续的 fit、segment transform、color adjustment、opacity 逻辑保持不变。

### 4.4 Provider 生命周期绑定到 `CompositionCoordinator`

`CompositionCoordinator.rebuild(timeline:)` 已经负责创建 `AVPlayerItem`、`replaceCurrentItem(with:)`、恢复播放位置、启动 `TimelineClock`。P4 在这里补齐：

- replace item 前：旧 provider `invalidate()`
- replace item 后：新 provider `prepare(for:)`
- renderer update 后：`preload(videoSpecs:)` 提前创建 source output
- seek/replay：`prepareTimelineRuntimeForSeek(to:)` 去重后通知 provider；不提前清空 preview 层，目标帧 render 成功后 replace
- render miss：只保留一个 50ms deferred retry，避免同一时间点重复 `renderFrameAndFlush`
- replay：seek 到 0 后重置 display time 和 provider seek state，避免 end-frame/stale-frame cache

---

## 五、Frame Reuse / Miss 策略

P4 preview 不做 `AVAssetImageGenerator` fallback。`AVPlayerItemVideoOutput.hasNewPixelBuffer=false` 在播放中是正常状态，允许复用短时间窗口内的 last frame；首次取帧失败、seek/replay 后无帧、或 copyPixelBuffer 失败且无可复用帧时，miss 必须显性暴露，便于验证 ready、seek、replay、time mapping。

| 项目 | 目的 | 规则 |
|---|---|---|
| `lastFrame` | 避免 hasNewPixelBuffer=false 时主视频层消失 | 仅复用 0.1s 内的上一帧；seek/replay/flush 清空 |
| `SegmentKey` | 识别是否进入新的 video segment | 进入 segment 时 seek 一次；播放中同一 segment 不再逐帧 seek |
| `lastSeekTime` / `lastPreparedSeekTime` | 避免同一 seek 目标重复 reset provider | 重复的 `compositionTime=0` seek 不再清空 source/counter |
| `lastDisplayedTime` | 避免重复 enqueue 同一个 presentation time | 相同或倒退时间不入队，seek/replay 后重置 |
| stale forced copy guard | 防止 seek 后拿到旧 displayTime 的错帧 | forced copy 的 `displayTime` 必须接近目标 `sourceTime`，否则返回 nil 并打印 reason |
| source preload | 缩短进入视频段时 output 未 ready 的窗口 | `TimelineRenderer.update` 解析所有 `VideoLayerSpec`，provider 预创建 source output |
| playback active hint | 避免 replay / seek 时靠时间差误判播放态 | `EditorStore` / `FullScreenPreviewController` 显式调用 `setPlaybackActive(_:)` |
| frame miss / reuse log | 暴露 output 未 ready / time mapping 错误，也统计复用频率 | 打印 asset、compositionTime、sourceTime、hasNewPixelBuffer、output status、playerItem status、duration、reason、requests、hasNewFalse、copyNil、reused、forcedCopy、seeks、nilFrames |

不在 P4 preview 做 fallback / 多帧 LRU 的原因：

- fallback 会掩盖 `AVPlayerItemVideoOutput` 的 ready、seek、replay、time mapping 真实问题
- `AVAssetImageGenerator` 会继续引入高内存和发热风险
- 多帧缓存容易在 replay/seek 时引入 stale frame；P4 只允许短窗口 last-frame 复用

---

## 六、Replay / Seek 生命周期治理

P4 验收的关键不是“能播放”，而是 replay、seek、play 三者一致。

### 6.1 Replay

播放结束后再次播放：

1. provider `seek(to:)` 清空 lastFrame，但不先 flush preview layer
2. `player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)`
3. seek completion 后尝试 `renderFrameAndFlush()`
4. 只有目标帧 render 成功后才 `timelinePreviewView.flush()` + enqueue；失败时保持 last displayed frame，并在 50ms 后补渲染一次
5. 同一目标时间的 runtime seek prepare 会被去重，避免重复 reset source output

### 6.2 Seek

seek 时：

- 暂停 display enqueue 或用 `isRenderingFrame` 阻止并发 render
- 不在 seek 前 flush display layer，避免 output 暂未 ready 时短暂黑屏
- provider 标记目标时间，避免返回 seek 前旧帧
- seek completion 后同步渲染目标帧；目标帧成功后再 flush + enqueue，失败时保持 last displayed frame 并延迟补帧
- 同一时间点只保留一个 deferred retry，避免 `renderFrameAndFlush` 被重复触发
- forced copy 返回旧 `displayTime` 时拒绝该帧，不显示错帧

### 6.3 当前剩余问题

已验证 `compositionTime=0` 重复 forced copy 消失。当前 seek 日志中仍可能出现单次：

```
reason=no new pixel buffer and no reusable source frame
```

或：

```
reason=forced copy returned stale displayTime=...
```

这说明 provider 正确拒绝了未 ready 或旧时间戳的帧。下一步手感优化是“seek 目标 warm frame”：用户 seek 时记录目标 composition time，允许 preview 保持 last displayed frame；目标 source seek completion 或 30-50ms retry 成功后再 replace，减少 seek 后短暂空帧。

### 6.4 最新诊断：Preview 黑屏 / 卡帧仍未根治（2026-05-26）

截至 2026-05-26，导出路径已经稳定，但编辑器预览和全屏预览仍会在播放、seek、replay 中偶发黑屏或卡帧。该问题不是 `TimelineRenderer` / `LayerResolver` / `VideoLayerComposer` 的合成错误，而是 preview-only 的实时取帧链路仍不稳定。

当前架构已经拆成两套 provider：

```
PreviewFrameProvider
  -> per-source hidden AVPlayer
  -> AVPlayerItemVideoOutput
  -> CVPixelBuffer
  -> TimelineRenderer

ExportFrameProvider
  -> per-segment AVAssetReaderTrackOutput
  -> CVPixelBuffer
  -> TimelineRenderer
```

导出正常说明：

- timeline layer 解析大体正确
- `TimelineRenderer.renderFrame(at:)` 可稳定合成
- `VideoLayerComposer` 的 fit / transform / adjustment 路径可用
- 视频段 `sourceTime` 映射在顺序导出语境下成立

预览仍异常说明：

- `PreviewFrameProvider` 的 realtime decode / output scheduling 仍存在竞态
- 主 `AVPlayer` 的 audio/clock 与 hidden source player 的 video output 没有硬同步
- `AVPlayerItemVideoOutput` 在 seek、segment switch、replay、前后台恢复时可能 ready 但不产出目标帧

#### 6.4.1 典型症状

| 场景 | 表现 | 说明 |
|---|---|---|
| 播放多段视频 | 第二段 / 第三段中间偶发黑屏，或画面卡住但声音继续 | hidden source player/output 卡在旧 PTS，主 player 时间继续走 |
| seek 时间线 | 比播放更容易黑屏或卡帧 | paused seek 会清理/重置 provider 状态，目标帧通常尚未 ready |
| replay | 播放结束后再次点击播放，有概率画面定格第一帧但音频继续 | 从 duration 跳回 0 时，provider 播放态与 source seek/play 状态容易错位 |
| 全屏预览 | 与编辑器预览类似，偶发黑屏/卡住 | 复用了同类 `PreviewFrameProvider`，只是 player 独立 |
| 导出 | 正常，无尾部黑屏，速度可接受 | 导出不依赖 `AVPlayerItemVideoOutput` 的 realtime readiness |

#### 6.4.2 关键日志含义

正常但高频的日志：

```
hasNewPixelBuffer=false
reason=no new pixel buffer; reused source frame
```

`AVPlayerItemVideoOutput` 不保证每个 display tick 都有新 pixel buffer。播放中 `hasNewPixelBuffer=false` 本身不是 bug，只要 `lastFrame` 能短窗口复用，画面就应稳定。

危险日志：

```
reason=no new pixel buffer and no reusable source frame
```

说明当前目标 `sourceTime` 没有新帧，且 provider 没有可复用的 source-local frame。无背景图时该帧会表现为黑屏。

更危险的日志：

```
reason=forced copy returned stale displayTime=4.1250
sourceTime=5.0033
```

说明 `copyPixelBuffer(forItemTime:)` 返回了旧 PTS 的帧。此时如果直接显示，会错帧/卡帧；如果严格拒绝，又会返回 nil 造成黑屏。当前代码采取过折中策略：播放态持有上一帧，并限频 reattach output + seek 到当前 sourceTime，但这只能降低概率，不能保证彻底恢复。

#### 6.4.3 为什么 seek 更明显

seek 是当前 preview provider 最脆弱的路径：

1. 用户拖动时间线，主 player 异步 `seek(to:)`
2. `PreviewFrameProvider.seek(to:)` 重置 source seek 状态
3. `renderFrameAndFlush()` 立即请求目标 `compositionTime`
4. provider 映射到目标视频段的 `sourceTime`
5. hidden source player 也需要 seek 到对应 `sourceTime`
6. `AVPlayerItemVideoOutput` 可能还没 ready，或仍返回旧 `displayTime`
7. renderer 当前帧拿不到视频 layer，画布缺少主画面，表现为黑屏或持帧

播放态相对好一些，因为 source player 可以持续解码，`lastFrame` 能跟着推进；paused seek 没有连续推进窗口，目标帧未 ready 的概率更高。

#### 6.4.4 为什么 replay 会卡第一帧

replay 从结尾重新播放的路径是：

```
main player currentTime ~= duration
  -> prepareTimelineRuntimeForSeek(.zero)
  -> main player seek(.zero)
  -> player.play()
  -> renderFrame(at: 0)
```

如果 provider 只靠 `compositionTime` 增量判断播放态，`duration -> 0` 是时间倒退，第一帧会被误判为 paused seek。当前已经增加 `setPlaybackActive(_:)`，由 `EditorStore` / `FullScreenPreviewController` 显式传入播放状态。但 source player seek/play/output readiness 仍可能与主 player 不同步，因此仍可能出现“音频继续、画面卡第一帧”。

#### 6.4.5 当前已尝试的修复

| 修复 | 作用 | 现状 |
|---|---|---|
| source-level provider | 避免 composition-level output 在 image->video 时不激活 | 已落地 |
| 禁止 `AVAssetImageGenerator` preview fallback | 暴露真实 preview readiness 问题，避免高内存/发热回流 | 已落地 |
| `lastFrame` 短窗口复用 | 降低 `hasNewPixelBuffer=false` 导致的闪烁 | 有效但不足 |
| segment enter seek once | 播放态不再逐帧 seek | 有效 |
| output reattach | 尝试恢复 attached 但不产帧的 output | 降低概率，非根治 |
| stale forced copy guard | 避免显示旧 PTS 错帧 | 正确但会暴露黑屏 |
| playback active hint | replay / play 不再只靠时间差判断播放态 | 有效但不足 |
| paused seek lastDisplayedFrame fallback | seek 目标帧未 ready 时先保住画布 | 降低黑屏但仍可能卡帧 |
| preloadSource ready guard | 避免 `player.status != .readyToPlay` 调用 preroll 崩溃 | 已修复 |
| ExportFrameProviderReader | 导出改为 `AVAssetReaderTrackOutput` | 已验证导出正常 |

#### 6.4.6 当前结论

P4 的 source-level `AVPlayerItemVideoOutput` 方向验证了实时预览可以脱离 `AVVideoCompositing`，也明显优于 `AVAssetImageGenerator` 截图式解码；但多 source hidden player + 主 player clock 的同步模型仍有结构性风险。

当前问题应记录为：

> 导出正常，预览黑屏/卡住集中发生在 `PreviewFrameProvider` 的 realtime source player / `AVPlayerItemVideoOutput` 同步链路。`AVPlayerItemVideoOutput` 在 seek、segment 切换、replay、前后台恢复时可能 ready 但不产出目标 `CVPixelBuffer`，或持续返回 stale `displayTime`。在没有背景层时，视频 layer miss 会直接暴露为黑屏；有背景层时表现为视频层消失、卡住或叠加层正常但底图不动。

#### 6.4.7 下一步方向

不要继续无限叠加局部 fallback。下一阶段应做架构收口评估：

1. **Preview source player 同步策略重审**
   - 明确 source player 进入 segment、离开 segment、seek、replay 的状态机
   - 拆分 paused seek 与 active playback 两套路径
   - 对 source player rate、currentTime、output displayTime 建立 DEBUG 状态表

2. **Preview warm frame 专用路径**
   - seek 时先保持 last displayed frame
   - source seek completion 后再 replace
   - 若 output 返回 stale displayTime，延迟 retry 而不是立即 flush/黑屏

3. **考虑 Preview 专用 reader cache / hybrid**
   - 对 paused seek 使用轻量 `AVAssetReader` 或可控单帧 reader，不用于播放态
   - 播放态仍用 `AVPlayerItemVideoOutput`
   - 目标是让 scrub/seek deterministic，避免完全依赖 realtime output readiness

4. **长期方向：独立 TimelineClock**
   - 当前主 player 同时承担 audio clock 与 visual composition time
   - P5 应把视觉时间推进从 `player.currentTime()` 中解耦
   - AVPlayer 仅负责 audio，visual runtime 使用独立 clock，并显式同步 seek/play/pause

### 6.5 End frame flood

P3 已经通过 `store?.isPlaying == true` 避免结束后 display link 持续入队。P4 保留此规则，并增加：

- compositionTime >= duration 时不再请求 provider 新帧
- 结束帧只允许入队一次
- replay 前必须重置 last displayed time

---

## 七、Performance Benchmark

P4 需要补一个轻量 runtime profiler，至少记录：

| 指标 | 采样点 | 验收目标 |
|---|---|---|
| FPS | display link tick + successful enqueue | 720p mixed timeline 稳定，目标 >= 55fps |
| render latency | `TimelineRenderer.renderFrame(at:)` 前后 | p95 不超过单帧预算，明显低于 P3 |
| video frame latency | provider frame request 前后 | seek/replay 后首帧稳定 |
| memory peak | `task_vm_info` 或 Xcode Instruments | 720p 预览内存稳定，无持续爬升 |
| replay latency | tap replay 到首帧 enqueue | 无黑屏，首帧可见 |
| seek latency | seek completion 到目标帧 enqueue | 不叠图、不闪烁、不 backlog |
| thermal | 真机 Instruments / Xcode gauge | 连续播放 3-5 分钟无明显发热退化 |

建议新增 DEBUG-only 结构：

```swift
struct TimelineRuntimeMetrics {
    var frameCount: Int
    var droppedFrameCount: Int
    var renderLatencyP95: Double
    var providerLatencyP95: Double
    var replayLatency: Double
    var seekLatency: Double
}
```

---

## 八、P4 不做项

| 不做 | 原因 | 后续位置 |
|---|---|---|
| VideoToolbox | 工程复杂度高，当前收益不匹配；需要自行管理解码 session、时间戳、颜色空间和缓存 | V6.1+ 或专项性能阶段 |
| AVAssetReader 作为实时预览主线 | 顺序离线读取更适合导出；随机 seek/实时播放体验不如播放器输出 | P5 导出统一 |
| Preview fallback 到 `AVAssetImageGenerator` | 会掩盖 output ready / seek / replay / time mapping 问题，并继续引入高内存和发热风险 | 禁止 |
| 多帧视频 LRU | 容易引入 stale frame，P4 优先解决主路径性能和生命周期 | 视真机数据决定 |
| 重写 TimelineRenderer | 当前瓶颈在视频帧来源，不在合成器主体 | 保留 |
| 废除 AVPlayer | 仍需要 audio、clock、decode scheduling | 保留为基础设施 |

---

## 九、实施拆分

### P4-A：协议与 legacy 兼容

- 新增 `VideoFrameProviderProtocol`
- 将现有 `VideoFrameProvider` 改名或包装为 `ImageGeneratorVideoFrameProvider`
- `VideoLayerComposer` 从具体类依赖改为 protocol 依赖
- 行为保持不变，先确保编译和 mixed timeline 不退化

### P4-B：`AVPlayerItemVideoOutputProvider`

- 新增 source-level provider 实现
- 每个 video asset 维护独立 hidden `AVPlayerItem + AVPlayerItemVideoOutput`
- `CIImage(cvPixelBuffer:)` 接入 `VideoLayerComposer`
- 禁止 preview 自动 fallback；首次 miss 返回 nil 并打印诊断日志
- 恢复短窗口 last-frame 复用，避免 hasNewPixelBuffer=false 造成视频层闪烁
- 播放态同一 segment 不再逐帧 seek；仅在进入 segment / 用户 seek / replay 时 seek
- 拒绝 stale forced copy，避免 seek 后显示旧帧

状态：已完成并通过用户验证。纯视频播放稳定；图片在前、视频在后不再黑屏；播放态 `seeks=1`。

### P4-C：seek/replay 生命周期

- seek/replay 前后统一治理 provider + display layer，但不在目标帧 ready 前清空预览层
- 防 stale frame、防 end frame flood
- 补 paused seek 单帧渲染
- `renderFrameAndFlush` 同一时间点去重，只保留一个 deferred retry
- 同一 seek 目标去重，`compositionTime=0` 重复 forced copy 已消失

状态：主预览与全屏预览已接入并通过阶段验证。剩余 seek 目标帧 warm-frame 属于手感优化。

### P4-D：source preload / warm frame

- `TimelineRenderer.update` 解析全部 `VideoLayerSpec`
- provider `preload(videoSpecs:)` 预创建 source output 并请求 media data change
- 待补：preload 阶段对每个 `sourceStartTime` 做 warm seek，并保留可复用首帧
- 待补：用户 seek 目标帧 not ready 时保持 last displayed frame，source seek completion 或 30-50ms retry 成功后 replace

状态：轻量 preload 已落地；warm-frame 待做。

### P4-E：Benchmark 与真机验收

- DEBUG metrics
- 720p mixed timeline 压测
- replay / seek / play 矩阵
- Instruments 记录 CPU、memory、thermal 对比 P3

状态：待执行。

---

## 十、验收标准

P4 完成后必须验证：

1. mixed timeline：`video + image_3d + overlay` 稳定播放
2. image -> video：主轨第一段是 image、第二段是 video 时，video 段不黑屏
3. play：播放态 source provider `seeks` 保持为 segment 级别，不逐帧增长
4. replay：播放结束后再次播放不黑屏、不显示 stale end frame
5. seek：目标帧正确，不叠图、不闪烁、不 backlog；重复 `compositionTime=0 forced copy` 不再出现
6. pause seek：暂停状态拖动 playhead 后能立即或短延迟显示目标帧，期间保持 last displayed frame
7. performance：720p 预览内存稳定，无明显发热，FPS 稳定
8. regression：image-only runtime 路径不退化；纯音频/无视觉 timeline 仍走现有 AVPlayer path

当前阶段验证结果：

| 项目 | 状态 |
|---|---|
| 纯视频播放不闪 | 已验证 |
| image -> video 不黑屏 | 已验证 |
| 播放态 seek 频率 | 已验证，典型日志 `seeks=1` |
| `compositionTime=0` 重复 forced copy | 已验证消失 |
| stale forced copy 拦截 | 已验证，旧 `displayTime` 会被拒绝 |
| source preload | 轻量版已落地，warm seek 待补 |
| 性能 benchmark | 待执行 |

---

## 十一、长期方向

P4 之后的解码分层：

| 场景 | Provider | 状态 |
|---|---|---|
| 实时预览 | `AVPlayerItemVideoOutputProvider` | P4 主线 |
| 导出 | `AVAssetReaderVideoFrameProvider` | P5 |
| 高级低延迟/自定义解码 | `VideoToolboxVideoFrameProvider` | V6.1+ |
| 缩略图/封面/debug | `AVAssetImageGenerator` | fallback |

最终目标仍是：

```
TimelineRenderer
  -> preview sink: AVSampleBufferDisplayLayer
  -> export sink: AVAssetWriter
```

AVFoundation 只保留 audio、timing、decode infrastructure；视觉合成继续收敛到单一 `renderFrame(at:)` 路径。
