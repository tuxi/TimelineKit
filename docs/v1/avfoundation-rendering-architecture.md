# TimelineKit + AVFoundation 渲染整体架构设计

> TimelineKit 渲染方案 · V1.0
>
> 本文档描述 EditorTimeline → 预览播放 → 导出 的完整渲染架构。
> 所有渲染代码的开发必须遵守本文档约束；如需变更，先更新本文档再动代码。

---

## 一、总体架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                         TimelineKit                                   │
│                                                                       │
│  ┌──────────────┐    mutate()    ┌──────────────────┐                │
│  │  EditorStore  │ ─────────────▶ │  EditorTimeline   │ (value type) │
│  │  (@Observable)│               │  (EditorTrack[])  │               │
│  └──────────────┘               └────────┬─────────┘                │
│                                          │ onChange                   │
│                                          ▼                            │
│                               ┌──────────────────┐                   │
│                               │ CompositionBuilder│  (pure, async)   │
│                               │  (background Task)│                  │
│                               └────────┬─────────┘                   │
│                                        │                              │
│                         ┌──────────────┼──────────────┐              │
│                         ▼                             ▼               │
│               ┌──────────────────┐       ┌──────────────────────┐    │
│               │ PreviewComposite │       │  ExportComposite      │    │
│               │ (AVPlayerItem)   │       │ (AVAssetExportSession)│    │
│               └────────┬─────────┘       └──────────┬───────────┘    │
│                        │                             │                │
│                        ▼                             ▼                │
│               ┌──────────────────┐       ┌──────────────────────┐    │
│               │   TimelinePlayer │       │   ExportPipeline      │    │
│               │   (AVPlayer)     │       │   (输出 .mp4)          │    │
│               └──────────────────┘       └──────────────────────┘    │
│                        │                                              │
│                        ▼                                              │
│               ┌──────────────────┐                                    │
│               │ ThumbnailCache   │  (AVAssetImageGenerator)          │
│               │ (scrubbing 帧)   │                                    │
│               └──────────────────┘                                    │
└───────────────────────────────────────────────────────────────────────┘
```

---

## 二、核心组件职责

### 2.1 CompositionBuilder

**职责**：将 `EditorTimeline`（值类型）转换为 `AVMutableComposition` + `AVMutableVideoComposition`。

```swift
// 伪接口（尚未实现）
actor CompositionBuilder {
    /// 从 EditorTimeline 构建合成对象。
    /// 纯函数：无副作用，每次返回全新的 Composition 对象。
    /// 在 actor（后台线程）上执行，主线程安全。
    func build(from timeline: EditorTimeline) async throws -> CompositionResult
}

struct CompositionResult {
    let composition:      AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix:         AVMutableAudioMix
}
```

**关键约束**：
- `build()` 必须可取消（外部用 `Task` 包裹，可 `.cancel()`）
- 不持有 `EditorStore` 引用（避免循环引用）
- `AVURLAsset` 从外部传入 `AssetCache`，Builder 不自己创建 asset

### 2.2 AssetCache

**职责**：持有 `URL → AVURLAsset` 映射，避免同一文件重复创建 asset。

```swift
// 伪接口
final class AssetCache {
    static let shared: AssetCache

    /// 返回已缓存的 asset，若不存在则创建并缓存。
    func asset(for url: URL) -> AVURLAsset

    /// 内存警告时调用 — 只清已完成加载的 asset（URLAsset 本身不大，
    /// 清的是已解码帧；AVFoundation 在 asset 被 nil 时自动释放解码器）。
    func purgeDecodedCache()

    /// 完全清空（App 退到后台时）
    func purgeAll()
}
```

**缓存策略**：
- Key: `URL.absoluteString`
- 容量上限：不做数量限制，但响应 `UIApplication.didReceiveMemoryWarningNotification`
- 后台切换：`purgeDecodedCache()`（保留 URLAsset 引用，仅释放解码帧）

### 2.3 TimelinePlayer

**职责**：封装 `AVPlayer`，对外暴露 `isPlaying`、`currentTime`、`seek(to:)` 等状态。

```swift
// 伪接口
@MainActor @Observable
final class TimelinePlayer {
    private(set) var isPlaying: Bool
    private(set) var currentTime: Double
    private(set) var duration: Double

    func play()
    func pause()
    func seek(to time: Double)

    /// 用新的 CompositionResult 无缝替换当前播放项（无黑帧）。
    func replaceComposition(_ result: CompositionResult)
}
```

**无缝 swap 的实现方式**：

```swift
// replaceComposition 内部逻辑（伪代码）
func replaceComposition(_ result: CompositionResult) {
    let item = AVPlayerItem(asset: result.composition)
    item.videoComposition = result.videoComposition
    item.audioMix         = result.audioMix
    let savedTime = player.currentTime()
    player.replaceCurrentItem(with: item)
    player.seek(to: savedTime, toleranceBefore: .zero, toleranceAfter: .zero)
}
```

注意：`replaceCurrentItem` 必须在主线程调用，但构建 `AVPlayerItem` 可以在后台。

### 2.4 ThumbnailCache（时间轴缩略图 & Scrubbing 帧）

**职责**：为时间轴刻度和 Scrubbing 提供快速帧缓存。

```swift
// 伪接口
actor ThumbnailCache {
    /// 请求指定时间点的帧，结果通过 continuation 返回。
    /// 节流：同一帧 30ms 内的重复请求合并。
    func frame(at time: Double, asset: AVURLAsset) async -> CGImage?

    /// 预热指定范围的缩略帧（在时间轴渲染前后台生成）。
    func warmup(range: ClosedRange<Double>, asset: AVURLAsset, fps: Double)

    func purge()
}
```

**帧生成策略**：
- 使用 `AVAssetImageGenerator`，`requestedTimeToleranceBefore/After = CMTime(value:1, timescale:10)`（允许前后 0.1s 偏差，换取速度）
- `appliesPreferredTrackTransform = true`（正确处理旋转素材）
- 生成分辨率：固定 `320×180`（16:9）或等比缩放至宽度 320pt

---

## 三、层级合成规则

### 3.1 视频轨道合成顺序（z-order）

```
z  最高 ──────────────────────────
         字幕 / 文字         AVVideoCompositionCoreAnimationTool
         贴纸 / 水印         (CALayer 叠加)
         调色 / LUT           CIFilter 链
         画中画 / 叠加轨     AVMutableCompositionTrack (overlay)
z  最低  主视频轨             AVMutableCompositionTrack (primary)
──────────────────────────────────
```

### 3.2 字幕/文字特殊路径

字幕和文字**不走视频解码**，走 `AVVideoCompositionCoreAnimationTool`：

```
EditorTimeline.textTracks / subtitleTracks
         ↓
CompositionBuilder 构建 CALayer 树（字幕/文字动画）
         ↓
AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: ..., in: ...)
         ↓
挂载到 AVMutableVideoComposition.animationTool
```

**优势**：
- 修改字幕文字 → 只需重建 CALayer，不需要重建整个 `AVMutableComposition`
- 字幕动画（淡入淡出）用 `CABasicAnimation` 驱动，零额外渲染成本

### 3.3 音频轨道合成

所有音频通过 `AVMutableAudioMix` 控制：

```swift
let audioParams = AVMutableAudioMixInputParameters(track: audioTrack)
audioParams.setVolume(Float(seg.volume), at: .zero)
audioMix.inputParameters.append(audioParams)
```

主视频音频 + BGM + 录音 各自独立 track，音量独立控制，无需自定义合成代码。

---

## 四、编辑操作 → 渲染触发规则

> 核心原则：**UI 操作即时生效（EditorStore），渲染异步延迟**。

```
用户操作                    EditorStore     CompositionBuilder
─────────────────────────────────────────────────────────────
裁剪片段 / 移动片段           mutate()       300ms 防抖后触发 rebuild
修改文字内容 / 样式            mutate()       仅重建 CALayer（不 rebuild composition）
修改音量                     mutate()       重建 AVAudioMix（轻量，不 rebuild composition）
添加 / 删除轨道               mutate()       立即触发 rebuild（结构变化）
Undo / Redo                 stack.pop()    300ms 防抖后触发 rebuild
时间轴拖拽（playheadTime）     selection      不触发 rebuild（只 seek）
```

**防抖实现**：

```swift
// CompositionCoordinator 内部（伪代码）
private var pendingRebuildTask: Task<Void, Never>?

func scheduleRebuild(for timeline: EditorTimeline, delay: Duration = .milliseconds(300)) {
    pendingRebuildTask?.cancel()
    pendingRebuildTask = Task {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        let result = try? await builder.build(from: timeline)
        guard let result, !Task.isCancelled else { return }
        await MainActor.run { player.replaceComposition(result) }
    }
}
```

---

## 五、导出管线

```swift
// 伪接口
actor ExportPipeline {
    /// 导出时复用 CompositionBuilder，保证和预览行为完全一致。
    func export(
        timeline:     EditorTimeline,
        outputURL:    URL,
        preset:       String = AVAssetExportPresetHighestQuality,
        onProgress:   @escaping (Float) -> Void
    ) async throws
}
```

**实现要点**：
1. 先调 `CompositionBuilder.build(from: timeline)` 得到 `CompositionResult`
2. 创建 `AVAssetExportSession(asset: result.composition, presetName: preset)`
3. 设置 `exportSession.videoComposition = result.videoComposition`
4. 设置 `exportSession.audioMix = result.audioMix`
5. 用 `exportSession.exportAsynchronously` + `Timer` 轮询 `progress`（或用 `AsyncStream`）

**导出分辨率**：
- 默认 `AVAssetExportPresetHighestQuality`（源分辨率）
- 用户可选 1080p / 720p（对应 `AVAssetExportPreset1920x1080` / `AVAssetExportPreset1280x720`）

---

## 六、模块边界与文件规划

```
TimelineKit/Sources/TimelineKit/
│
├── Store/
│   └── EditorStore.swift               ✅ 已有
│
├── Rendering/                          🔲 待建
│   ├── CompositionBuilder.swift        核心转换逻辑
│   ├── CompositionCoordinator.swift    防抖调度 + AVPlayer swap
│   ├── AssetCache.swift                URLAsset 缓存
│   ├── ThumbnailCache.swift            Scrubbing 帧缓存
│   └── ExportPipeline.swift           导出
│
├── Views/
│   ├── ClipEditorView.swift            ✅ 已有
│   ├── EditorPreviewView.swift         ✅ 已有（接 TimelinePlayer）
│   └── ...
│
└── Models/
    └── EditorTimeline.swift            ✅ 已有
```

---

## 七、开发顺序（分层交付）

| 阶段 | 交付物 | 依赖 |
|------|-------|------|
| P0 | `AssetCache` | 无 |
| P0 | `CompositionBuilder`（仅主视频轨，无特效） | AssetCache |
| P1 | `CompositionCoordinator`（防抖 + swap） | Builder |
| P1 | `TimelinePlayer` 接入 Coordinator | Coordinator |
| P2 | 字幕/文字 CALayer 路径 | Builder |
| P2 | `ThumbnailCache` + 时间轴缩略图 | AssetCache |
| P3 | 音频混音（AVAudioMix） | Builder |
| P3 | `ExportPipeline` | Builder |
| P4 | 预览分辨率动态降级 | Coordinator |
| P4 | 内存压力响应 | AssetCache + ThumbnailCache |

---

## 八、变更历史

| 日期 | 版本 | 说明 |
|------|------|------|
| 2026-05-13 | V1.0 | 初稿，定义完整渲染架构与组件边界 |
