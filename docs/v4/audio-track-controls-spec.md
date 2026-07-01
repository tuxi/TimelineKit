# 音频与轨道控制规范（v4）

> 版本：v4.0
> 状态：规范定稿，待实现
> 优先级：**P1**
> 对标产品：剪映 iOS（双滑杆 + 轨道头三图标）+ FCP（语义参考）
> 依赖：v3 [audio-feature-spec.md](../v3/audio-feature-spec.md)（磁吸基线）+ v3 [multi-track-architecture-spec.md](../v3/multi-track-architecture-spec.md)；[multi-track-scroll-spec.md](multi-track-scroll-spec.md)（左侧 labels 同步滚动是图标交互的前置）；[competitive-benchmarks-v4.md](competitive-benchmarks-v4.md) §6 / §7 / §8

---

## 一、覆盖范围

本规范一次性补齐 V4 P1 的 3 件能力：

1. **音频片段淡入 / 淡出**（fade in / fade out）
2. **轨道静音 / 锁定 / 隐藏**（mute / lock / hide）
3. **音频剪辑手柄拖拽磁吸精度补强**（fade handle 磁吸）

3 件功能共享 `EditorTrack` + `AudioContent` 既有字段、`CompositionBuilder` 音频管线、`TrackLabelsView` UI。

---

## 二、音频片段淡入 / 淡出

### 2.1 现状

- `AudioContent.fadeInDuration / fadeOutDuration`（[SegmentContent.swift:170-171](../../Sources/TimelineKit/Models/SegmentContent.swift)）：✅ 模型字段已在，Codable 已读写
- `CompositionBuilder` 音频 mix（[CompositionBuilder.swift:664-738](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift)）：仅 `setVolume(_:at:)` keyframe，**未调 `setVolumeRamp`** → fade 字段是死字段
- `AudioEditPanel`：无任何 fade UI

### 2.2 规则定义

- 范围：`fadeInDuration` ∈ `[0, min(2.0, segment.duration / 2)]` 秒
- 范围：`fadeOutDuration` ∈ `[0, min(2.0, segment.duration / 2)]` 秒
- 总约束：`fadeInDuration + fadeOutDuration ≤ segment.duration`（UI 层硬约束滑杆 max；spec 中也明示数据层约束）

### 2.3 渲染实现

```swift
// CompositionBuilder.swift audioMix 构建（伪代码）
for seg in audioSegments {
    let segStart = seg.targetRange.start
    let segEnd   = seg.targetRange.end
    let vol      = seg.content.audio.volume

    // isMuted 优先：硬置 0，不上 ramp
    if track.isMuted || seg.content.audio.isMuted {
        params.setVolume(0, at: .zero)
        continue
    }

    let fadeIn  = seg.content.audio.fadeInDuration
    let fadeOut = seg.content.audio.fadeOutDuration

    // Fade in ramp
    if fadeIn > 0 {
        params.setVolumeRamp(
            fromStartVolume: 0,
            toEndVolume:     vol,
            timeRange:       CMTimeRange(start: CMTime(seconds: segStart),
                                         duration: CMTime(seconds: fadeIn))
        )
    } else {
        params.setVolume(vol, at: CMTime(seconds: segStart))
    }

    // Mid plateau (instant set at end of fade-in or at segStart)
    let plateauStart = segStart + fadeIn
    let plateauEnd   = segEnd   - fadeOut
    if plateauEnd > plateauStart {
        params.setVolume(vol, at: CMTime(seconds: plateauStart))
    }

    // Fade out ramp
    if fadeOut > 0 {
        params.setVolumeRamp(
            fromStartVolume: vol,
            toEndVolume:     0,
            timeRange:       CMTimeRange(start: CMTime(seconds: plateauEnd),
                                         duration: CMTime(seconds: fadeOut))
        )
    }
}
```

### 2.4 与 isMuted 的优先级

`AudioContent.isMuted` 或 `EditorTrack.isMuted` 任一为 true → 整段硬 `setVolume(0, at: .zero)`，ramp 不生效。这与 v3 现有行为（[CompositionBuilder.swift:725-726](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift)）一致，本期不破坏。

### 2.5 UI 入口

`AudioEditPanel` 内追加「淡化」段落：

```
┌─ AudioEditPanel ─────────────────────────────────────────┐
│ 音量      [────●─────]  100%                                │
│ ─────────                                                  │
│ 淡入      [──●───────]  0.5s        ← v4 新增                │
│ 淡出      [────●─────]  1.0s        ← v4 新增                │
│ ─────────                                                  │
│ ...                                                        │
└────────────────────────────────────────────────────────────┘
```

滑杆 mutate → `EditorStore.mutateAudioFade(segmentID:fadeIn:fadeOut:)`（新增）→ 触发 audio mix 重建（compositionVersion++，与 v3 音量调节路径一致）。

### 2.6 新增 store API

```swift
public extension EditorStore {
    /// Set fade durations on an audio segment. UI clamps to [0, duration/2]
    /// before calling; store re-validates defensively.
    func mutateAudioFade(segmentID: UUID, fadeIn: Double, fadeOut: Double)
}
```

---

## 三、轨道静音 / 锁定 / 隐藏

### 3.1 现状

`EditorTrack.isMuted / isLocked / isHidden`（[EditorTrack.swift:9-11](../../Sources/TimelineKit/Models/EditorTrack.swift)）：3 字段都在。

| 字段 | 现状 |
|---|---|
| `isMuted` | ✅ **已全链路接入**——audio mix 在 isMuted 时 `setVolume(0)`，store API + undo 已就位 |
| `isLocked` | ❌ 字段存在；canvas 手势端 / 编辑面板均无 check |
| `isHidden` | ❌ 字段存在；渲染端、UI 端均无 check |

### 3.2 v4 全链路补齐规则

**编辑期与导出期行为（取剪映语义，详 [competitive-benchmarks-v4.md](competitive-benchmarks-v4.md) §7.3）**：

| 标志 | 编辑期 canvas | 编辑期预览（EditorPreviewView） | 编辑期编辑面板 | 导出 |
|---|---|---|---|---|
| `isMuted` | 喇叭斜线图标显示 | 音频不出声 | 段编辑面板音量滑杆灰显 | 该轨音频不输出（已实现）|
| `isLocked` | 锁图标显示；轨内所有段拒绝长按 / drag / trim handle / 选中后破坏性操作 | 不影响 | 段编辑面板隐藏：删除 / 替换 / 批量 / 复制粘贴；保留：朗读 / 内容查看 | 不影响 |
| `isHidden` | 眼睛斜线图标显示；轨内所有段灰显（透明度 40%）但仍可选中（用户解除隐藏前提）| 字幕 / 文本 / 视频叠加层不绘制 | 段编辑面板正常 | **不输出**（音频静音、视频叠加层跳过、字幕文本跳过）|

### 3.3 UI 入口

`TrackLabelsView` 每行右侧新增三图标：

```
┌────────────────────────┐
│  🎵                     │
│  音频1     🔇  🔒  👁     │ ← v4 新增三图标 (mute/lock/hide)
└────────────────────────┘
```

- 主轨：仅 `isMuted` 可点击（锁定 / 隐藏对主轨无意义，灰显）
- 字幕 / 文本 / 音频 / 叠加轨：三图标全可点击
- 图标状态：高亮 = 已启用；灰色 = 未启用
- 点击：toggle 当前状态

### 3.4 新增 store API

```swift
public extension EditorStore {
    /// Already exists from v3:
    /// func muteTrack(id: UUID, isMuted: Bool)

    /// v4 新增：
    func setTrackLocked(id: UUID, isLocked: Bool)
    func setTrackHidden(id: UUID, isHidden: Bool)
}
```

实现走单条 mutate，undo 跟踪。

### 3.5 canvas 手势对 isLocked 的响应

`TrackCanvasView.SegmentBlockView`（[TrackCanvasView.swift](../../Sources/TimelineKit/Views/TrackCanvasView.swift)）的手势识别器（长按 / pan / trim handle）在识别开始前检查 `track.isLocked`：

```swift
private func handlePanBegan(_ gesture: UIPanGestureRecognizer) {
    guard !ownerTrack.isLocked else {
        // 触觉反馈 + toast "轨道已锁定"
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        return
    }
    // 正常逻辑
}
```

trim handle 与 long-press → 同样 guard。

### 3.6 渲染端对 isHidden 的响应

#### 字幕 / 文本

`SubtitleLayerBuilder.build` 在循环 segments 时 skip `track.isHidden == true` 的整轨：

```swift
let visibleSegments = timeline.tracks
    .filter { !$0.isHidden }
    .flatMap { $0.segments }
SubtitleLayerBuilder.build(segments: visibleSegments, ...)
```

`SubtitleFrameBuilder` 同样。

#### 视频叠加层（overlay tracks）

`CompositionBuilder.buildVideoTrackUnified / buildVideoTrackSinglePass` 内的 overlay 处理（v2 transition spec 涉及）skip isHidden 轨道。本期由 v4 实现时打到 `audio + video + subtitle/text` 三类。

#### 音频

`AudioContent.isMuted` 已是路径，但 `track.isHidden` 应进一步硬置音量为 0：

```swift
if track.isHidden || track.isMuted || seg.content.audio.isMuted {
    params.setVolume(0, at: .zero)
    continue
}
```

### 3.7 编辑期 canvas 内段块灰显（isHidden）

`SegmentBlockView` 在 owner track 的 isHidden = true 时 `alpha = 0.4`；其他视觉不变（仍可选中以方便用户解除隐藏）。

---

## 四、磁吸精度补强（音频 fade handle）

### 4.1 V3 现状

V3 音频片段拖拽磁吸已上线，覆盖：

- 片段边缘 → 相邻片段边
- 片段边缘 → 播放头
- 片段边缘 → 时间轴起点 / 终点

详见 [docs/v3/audio-feature-spec.md](../v3/audio-feature-spec.md)。

### 4.2 v4 fade handle 磁吸

v4 在 `AudioEditPanel` 引入 fade 滑杆（[本规范 §2.5](#25-ui-入口)）。后续若 P2 引入时间线 fade handle 拖拽（参考 CapCut Desktop / FCP），本规范预定义磁吸点：

| fade-in handle 拖动位置 | 磁吸目标 |
|---|---|
| 拖到 0 | 磁吸到 0（无 fade）|
| 拖到 fadeOut 反向位置 | 磁吸到 `(duration - fadeOut)` 上限（避免 fade 段重叠）|

| fade-out handle 拖动位置 | 磁吸目标 |
|---|---|
| 拖到段尾 | 磁吸到 0（无 fade）|
| 拖到 fadeIn 反向位置 | 磁吸到 `(duration - fadeIn)` 上限 |

复用 v3 磁吸阈值（10pt 触发距离）+ 触觉反馈 `UIImpactFeedbackGenerator(style: .light)`。

### 4.3 滑杆磁吸（本期实现项）

`AudioEditPanel` 的 fade 滑杆在拖动时在以下值有粘附效果（吸附 0.1s 范围）：

- 0（无 fade）
- 0.5s（短淡入）
- 1.0s（标准淡入）
- 2.0s（最长淡入，上限）

触觉反馈 `UISelectionFeedbackGenerator`。

### 4.4 时间线 fade handle 拖拽

本期不实现（[V4-initiation.md](V4-initiation.md) §2.3 未列入）。`AudioEditPanel` 双滑杆已能满足 P1 验收。

---

## 五、数据模型变更

**无任何字段新增 / 删除 / 重命名**。`AudioContent.fadeInDuration/fadeOutDuration` + `EditorTrack.isMuted/isLocked/isHidden` 均已在；本期仅消费现有字段、补全链路。

---

## 六、UI 草图总览

### 6.1 TrackLabelsView 行右侧三图标

```
┌─ TrackLabelsView ────────────────────┐
│ ┌─ Ruler spacer ─────────────────┐  │
│ ├────────────────────────────────┤  │
│ │ 🎬 主轨   🔇      —      —          │  │ ← 主轨：仅 mute 可点
│ ├────────────────────────────────┤  │
│ │ 💬 字幕1  🔊  🔒︎  👁          │  │ ← 高亮 = 启用
│ ├────────────────────────────────┤  │
│ │ T 文本1   🔊  🔓  👁           │  │
│ ├────────────────────────────────┤  │
│ │ 🎵 音频1  🔇  🔓  👁  + 新建        │  │ ← 最后一条音频轨：+ 按钮
│ └────────────────────────────────┘  │
└──────────────────────────────────────┘
```

图标位置：每行右侧水平排列，宽度 44pt 圆形点击区，间距 4pt。

### 6.2 AudioEditPanel 淡化段

```
┌─ AudioEditPanel ─────────────────────────────────────────┐
│ ┌─ 基本控制 ────────────────────────────────────────┐    │
│ │ 音量      [────●─────]  100%                        │    │
│ │ 静音      [○]                                       │    │
│ └─────────────────────────────────────────────────┘    │
│ ┌─ 淡化（v4 新增）──────────────────────────────────┐    │
│ │ 淡入      [──●───────]  0.5s                        │    │
│ │ 淡出      [────●─────]  1.0s                        │    │
│ └─────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

---

## 七、关键文件与改动量

| 文件 | 改动 |
|---|---|
| [Rendering/CompositionBuilder.swift](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) | 音频 mix 增加 `setVolumeRamp` 调用（fade in/out）；isHidden / isMuted 共同硬置 0；isHidden 轨字幕 / 文本 / 视频叠加层 skip |
| [Store/EditorStore.swift](../../Sources/TimelineKit/Store/EditorStore.swift) | 新增 `mutateAudioFade(segmentID:fadeIn:fadeOut:)` / `setTrackLocked(id:isLocked:)` / `setTrackHidden(id:isHidden:)` |
| [Views/AudioEditPanel.swift](../../Sources/TimelineKit/Views/AudioEditPanel.swift) | 新增「淡化」段落（fadeIn / fadeOut 双滑杆，含粘附点）|
| [Views/ClipEditorViewController.swift TrackLabelsView](../../Sources/TimelineKit/Views/ClipEditorViewController.swift) | 每行追加 mute / lock / hide 三图标按钮，点击 toggle 对应 store API |
| [Views/TrackCanvasView.swift SegmentBlockView](../../Sources/TimelineKit/Views/TrackCanvasView.swift) | 手势识别器开始前检查 `ownerTrack.isLocked`；isHidden 时 alpha=0.4 灰显 |
| [Views/TextEditPanel.swift](../../Sources/TimelineKit/Views/TextEditPanel.swift) / [Views/SegmentReplacePanel.swift](../../Sources/TimelineKit/Views/SegmentReplacePanel.swift) | isLocked 时隐藏破坏性按钮（删除 / 替换 / 批量 / 复制粘贴）|

**不改动**：v1 / v2 / v3 其他文件；数据模型；磁吸阈值（沿用 v3）。

---

## 八、风险与边界

### 8.1 setVolumeRamp 与 setVolume 共存

`AVMutableAudioMixInputParameters` 允许混用 `setVolume(_:at:)` 与 `setVolumeRamp(...)`。本规范约定：

- fadeIn > 0 时段：仅 `setVolumeRamp`，不 setVolume
- 平段：单点 `setVolume(vol, at: plateauStart)`
- fadeOut > 0 时段：仅 `setVolumeRamp`

避免 ramp 与 instant 在同一时间点冲突；按 AVFoundation 文档，后写入者覆盖。

### 8.2 isHidden 轨道导出端跳过

导出端语义采纳剪映（不渲染）。理由详见 [competitive-benchmarks-v4.md](competitive-benchmarks-v4.md) §7.3。spec 必须明示：

- 视频叠加层（overlay kind）：CompositionBuilder skip
- 字幕 / 文本：SubtitleLayerBuilder + SubtitleFrameBuilder skip
- 音频：audio mix 硬 `setVolume(0)`

**主视频轨**：永远不能 isHidden（数据层 isMainTrack=true → UI 不显示眼睛图标）。

### 8.3 isLocked 与「应用到本轨同类」批量

[bulk-style-apply-spec.md](bulk-style-apply-spec.md) §6.3 已规约：源片段所在轨道 isLocked 时按钮 disabled；API 调用 return 0。

### 8.4 fadeIn + fadeOut > duration 的边界

UI 层硬约束滑杆 max；store API 端再次防御性 clamp：`fadeIn = min(fadeIn, duration / 2)`，`fadeOut = min(fadeOut, duration - fadeIn)`。极端边界自动收敛到「无平段」（plateau = 0）。

### 8.5 多轨叠音的 fade 加性

多条音频轨同时 fade in / fade out 时，AVAudioMix 自动叠加各轨的瞬时 volume → 最终输出是各轨 volume 之和（不超过 1.0 由 AVAudioMix 内部限制）。无需特殊处理。

### 8.6 旧草稿兼容

无字段变更。旧草稿的 `fadeInDuration / fadeOutDuration` 默认 0（与 v3 行为一致——无 fade）。`isLocked / isHidden` 默认 false（与 v3 行为一致——不锁定 / 不隐藏）。

---

## 九、验收

### 9.1 功能（淡入淡出）

| Case | 验收 |
|---|---|
| C1 | 选中音频段 → 拖 fadeIn 滑杆到 1.0s → 预览播放该段时音量从 0 渐变到 100% 持续 1s |
| C2 | 同上设 fadeOut = 0.5s → 段尾 0.5s 音量从 100% 渐变到 0 |
| C3 | 同时设 fadeIn=1.0 + fadeOut=0.5，段长 5s → 平段 3.5s 音量恒定 |
| C4 | fadeIn=2.0, fadeOut=2.0, 段长 3s → UI 自动 clamp 到 fadeIn=1.5, fadeOut=1.5（duration/2 上限）|
| C5 | 段静音 (isMuted) → 即使 fadeIn>0，整段无声 |
| C6 | 导出视频解码 PCM 音频包络 → 与预览 envelope 一致 |

### 9.2 功能（轨道控制）

| Case | 验收 |
|---|---|
| C7 | 点击字幕轨锁图标 → 锁定；该轨所有段拒绝长按 / drag / trim |
| C8 | 锁定后尝试 trim → 触觉警告反馈；trim 不发生 |
| C9 | 锁定段选中后 → TextEditPanel 隐藏「删除」「替换」「批量」「复制粘贴样式」按钮 |
| C10 | 点击眼睛图标隐藏字幕轨 → 该轨字幕在预览中消失；canvas 内段块 alpha=0.4 |
| C11 | 隐藏后导出 → 输出视频不包含该轨字幕 |
| C12 | 隐藏音频轨 → 输出视频该轨音频静音 |
| C13 | 隐藏 overlay 视频轨 → 输出视频该轨叠加层不渲染 |
| C14 | 主轨永远不能隐藏 → 主轨 labels 行无眼睛图标 |
| C15 | 静音轨（已 v3 实现）→ 输出视频该轨音频静音（回归保持）|

### 9.3 性能

| 操作 | 标准 |
|---|---|
| `mutateAudioFade` mutate + audio mix 重建 | ≤ 30ms |
| `setTrackLocked / setTrackHidden` mutate + UI 重绘 | ≤ 16ms |
| 隐藏一条字幕轨重绘字幕图层 | ≤ 8ms |

### 9.4 兼容

| Case | 标准 |
|---|---|
| 加载 v1/v2/v3 旧草稿 | `fadeInDuration/fadeOutDuration` = 0（无 fade）；`isLocked/isHidden` = false |
| 保存草稿 → 重启加载 | 字段保持 |
| 撤销隐藏 / 锁定 | undo 还原状态 |

---

## 十、固定交互约束（V3 已锁，本规范沿用）

| 约束 | 应用 |
|---|---|
| 轨道点击仅唤起快捷栏，不遮挡编辑区 | 三图标点击不改变选中段；锁定 / 隐藏后用户仍能选中段查看（解除隐藏前提）|
| 文本字幕共用 `TextEditPanel` | 锁定时两类 segment 编辑面板隐藏破坏性按钮的逻辑一致 |
| 不重建 AVComposition（特定路径）| `setTrackLocked / setTrackHidden` 走 `mutateSubtitle` 不重建；`mutateAudioFade` 与 v3 音量调节同路径，会触发 audio mix 重建（compositionVersion++）|
| 向下完全兼容 | 无字段变更 |
| 单条 undo entry | 每次按钮点击 = 一条 undo entry |
| 安卓 / iOS 双端一致 | 三图标位置、淡化滑杆范围、磁吸点在本 spec 固定 |
