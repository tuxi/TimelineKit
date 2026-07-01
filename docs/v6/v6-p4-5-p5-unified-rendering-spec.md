# TimelineKit V6 P4.5 / P5 统一渲染阶段需求与问题分析

> 版本：v6-p4.5-p5（问题分析稿）  
> 日期：2026-05-20  
> 前置：P4 source-level VideoOutput 已落地，seek 闪黑基本解决，image+video 混合主轨可用  
> 关联：[timeline-runtime-architecture.md](timeline-runtime-architecture.md)、[layer-rendering-rules-spec.md](layer-rendering-rules-spec.md)

---

## 一、P4 完成状态确认

### 已落地的核心变更

| 组件 | 文件 | P4 状态 |
|---|---|---|
| `TimelineRenderer` | `Runtime/TimelineRenderer.swift` | ✅ @MainActor，CIImage 合成，CVPixelBufferPool |
| `LayerResolver` | `Runtime/LayerResolver.swift` | ✅ 纯函数，timeline → ResolvedFrame |
| `TimelineClock` | `Runtime/TimelineClock.swift` | ✅ CADisplayLink 驱动 |
| `AVPlayerItemVideoOutputProvider` | `Rendering/VideoFrameProvider.swift` | ✅ source-level CVPixelBuffer |
| `CompositionCoordinator` | `Rendering/CompositionCoordinator.swift` | ✅ hasAnyVisual 路径接入 Runtime |
| `TimelinePreviewView` | `Views/TimelinePreviewView.swift` | ✅ AVSampleBufferDisplayLayer |

### P4 已解决的问题

- ✅ seek 拖动闪黑（source-level 输出消除 composition-level 延迟）
- ✅ 图片在前、视频在后的主轨黑屏（LayerResolver 时间映射与 CompositionBuilder 对齐）
- ✅ image + video 混合主轨预览基本可用
- ✅ 转场播放冻结（V5.1 trackB mutable 引用 bug 修复保留）

---

## 二、P4.5 遗留问题根因分析

P4.5 目标：在进入 P5 全面架构工作之前，关闭 P4 引入或暴露的三类边界问题。这些问题不需要新增文件，仅需修改现有 Runtime + Provider 代码。

---

### BUG-1：视频片段首帧 / 尾帧黑屏

**现象**

- 播放至主轨 t=0 时（首帧）：初始停留黑屏，点击播放后恢复
- 播放至视频片段尾部时：尾帧黑屏
- 两个视频片段交界处：1-3 帧黑屏闪烁（无转场时尤为明显）

**根因分析**

根因有三层，互相叠加：

**层 1：段边界时间语义（LayerResolver 与 VideoLayerComposer 均适用）**

`LayerResolver.resolve()` 第 250 行：
```swift
guard compositionTime >= segStart && compositionTime < segEnd else { continue }
```

`VideoLayerComposer.evaluate()` + `VideoFrameProvider.frame()` 第 229 行：
```swift
guard compositionTime >= start, compositionTime < end else { return nil }
```

两处均使用严格 `< end`（开区间）。这是正确的——两个相邻片段 `[0,5)` 和 `[5,10)` 保证无重叠。问题不在此。

**层 2：段切换时 sourceFrame 清空引发空窗（核心根因）**

`AVPlayerItemVideoOutputProvider.updateActiveSegmentIfNeeded()` 在检测到 `SegmentKey` 变化时：
```swift
source.lastFrame = nil           // 清空缓存帧
source.didStartPlaybackForSegment = false
source.pendingSeekTime = nil
```

随后 `issueSeek(source:to:activePlayback:)` 异步发起 seek：
```swift
source.player.seek(to: time, ...) { [weak source] _ in
    source?.pendingSeekTime = nil
    // 完成回调 — 可能在 1-3 个渲染帧后才触发
}
```

seek 异步完成期间，`frame()` 的三条恢复路径依次失败：
1. `reusableLastFrame` → lastFrame=nil，失败
2. `reusableEndFrame` → 位于段头（非段尾），失败  
3. forced copy → seek 未完成，`AVPlayerItemVideoOutput` 尚无新帧，返回 nil

结果：段切换后 1-3 帧返回 nil → `VideoLayerComposer` 返回 nil → `TimelineRenderer` 跳过该层 → 黑帧。

**层 3：preload() 未预热 sourceStartTime**

`preload(videoSpecs:)` 当前仅调用 `requestNotificationOfMediaDataChange`，未对每个 spec 的 `sourceStartTime` 发起预热 seek。导致：
- 初次进入编辑器时，所有视频段的初始帧未就绪
- 第一次 `renderFrameAndFlush()` 调用 → nil → 50ms deferred retry（`scheduleDeferredSeekRender`），偶现首帧黑

**修复方向（P4.5）**

修复点 A — `updateActiveSegmentIfNeeded` 不清空 `lastFrame`：

```swift
// 删除：source.lastFrame = nil
// 原因：reusableLastFrame 的 delta < 0.1s 窗口自动拒绝非近邻帧
// 不同 URL 的 SourceOutput 独立，无跨 URL 污染风险
```

`lastFrame` 保留后，`reusableLastFrame` 依然只接受 delta < 0.1s 的帧（新段头 sourceTime ≈ sourceStartTime，旧段尾 time ≈ 旧段尾，delta 通常 >> 0.1s → 正确拒绝）。但同一 URL 不同 trim 切换时，若旧段尾 time 恰好靠近新段头 sourceStartTime（delta < 0.1s），会临时复用上一帧——这在视觉上是正确行为（帧连续，无黑屏）。

修复点 B — `preload()` 添加预热 seek：

```swift
func preload(videoSpecs: [VideoLayerSpec]) {
    for spec in videoSpecs {
        let source = sourceOutput(for: spec.assetURL)
        source.item.preferredForwardBufferDuration = 1
        source.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        // 预热：将 source player 定位到该 spec 的起始 sourceTime
        let seekTime = CMTime(seconds: spec.sourceStartTime, preferredTimescale: 600)
        if source.player.currentItem?.status == .readyToPlay {
            source.player.seek(to: seekTime, toleranceBefore: .zero,
                               toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600)) { _ in }
        }
    }
}
```

修复点 C — `reusableLastFrame` 窗口在段切换后适当放宽：

段切换第一帧：`reusableLastFrame` delta 阈值临时扩大到 0.2s（而不是永久），以应对 seek 延迟。可通过在 `sourceFrame()` 中传入"是否刚切换段"标志实现。

---

### BUG-2：Timeline Runtime 渲染触发条件和时钟驱动源存在系统性缺陷

> **修正说明**：原始分析将此 BUG 归因为"音频比图片长导致尾部黑屏"，属于对现象的局部描述。真正根因是 Timeline Runtime 的三个核心设计缺陷，导致"纯图片 / 无主轨视频 / 仅文字"等场景下渲染完全不工作，而非只有尾部黑屏。

**真实现象（完整列表）**

1. 新建剪辑器，只导入图片素材（无音频），无法正常播放预览——画面停在第 0 帧
2. 主轨无视频，无音频，只有 text / subtitle 段落时，Timeline Runtime 不被激活
3. 删除主轨全部素材，仅保留 text / subtitle，理论上应显示"黑底 + 文字"，实际全黑
4. 主轨仅图片 + 无音频时：`player.currentTime()` 永远为 0，CADisplayLink 驱动但画面不变
5. 主轨仅图片 + 有音频时：可播放，但主轨图片尾部（超过 image segEnd 的时间段）黑屏

**根因分析（四条独立缺陷）**

---

**缺陷 A：`hasAnyVisual` 条件过窄，仅检查主轨 image/video**

位置：`CompositionCoordinator.rebuild()` 第 141 行

```swift
let mainSegs = timeline.mainTrack?.segments ?? []
let hasAnyVisual = !mainSegs.isEmpty && mainSegs.contains {
    switch $0.content { case .image, .video: return true; default: return false }
}
```

当 `hasAnyVisual == false` 时，直接跳过 Timeline Runtime 激活：
```swift
} else {
    timelineClock?.stop()
    store?.usesTimelineRuntime = false
    videoFrameProvider.invalidate()
}
```

**结论**：text-only、subtitle-only、overlay-only、空主轨 + 有音频 等场景，Timeline Runtime 根本不会被激活。这些场景退回 AVPlayer 路径，而 AVPlayer 路径下没有 TimelineRenderer 渲染文字/字幕，画面全黑。

---

**缺陷 B：纯图片 + 无音频时，AVMutableComposition 零轨道 → 播放器时钟不前进**

位置：`CompositionBuilder.build()` 第 152 行，`isImageOnlyMainTrack` early return 分支

```swift
if isImageOnlyMainTrack(timeline) {
    let (audioMix, audioTrackMap) = try await buildAudio(
        timeline:      timeline,
        composition:   composition,
        totalDuration: totalDuration
    )
    return CompositionResult(...)
}
```

`buildAudio` 仅在存在 audio 轨道段时才向 `AVMutableComposition` 添加 track。无音频段时：

```
composition.tracks = []          // 零轨道
composition.duration = .zero     // AVFoundation 动态计算
```

`AVPlayerItem(asset: composition)` 的 duration = 0 → AVPlayer 加载后立即触发 `endObserver` → `store.isPlaying = false`。

后续 `onRenderTick()` 的守卫：
```swift
guard store?.isPlaying == true else { return }
let compositionTime = player.currentTime().seconds  // 永远是 0
```

**结论**：图片 + 无音频时，AVPlayer 无内容可播，`player.currentTime()` 恒为 0，CADisplayLink 60fps 触发但 compositionTime 永不推进，图像永远停在 t=0 的第一帧。

---

**缺陷 C：`LayerResolver.resolve()` 遇到空 mainSegs 提前返回**

位置：`LayerResolver.swift` 第 137 行

```swift
let mainSegs = (timeline.mainTrack?.segments ?? [])
    .sorted { $0.targetRange.start < $1.targetRange.start }

guard !mainSegs.isEmpty else { return .empty }  // ← 全部非主轨层被丢弃
```

当主轨为空（或主轨不存在）时，overlay / text / subtitle 轨道的所有 segment 均被静默丢弃，返回空帧。这导致即使 Timeline Runtime 已激活，"主轨空 + 有 text/overlay"的场景也只能看到黑屏。

---

**缺陷 D：时钟源绑定到 `player.currentTime()`，与 AVPlayer 内容耦合**

位置：`CompositionCoordinator.onRenderTick()` 第 254 行

```swift
let compositionTime = player.currentTime().seconds
```

整个 Timeline Runtime 的渲染时间轴依赖 `player.currentTime()` 推进。这在以下场景失效：

| 场景 | player.currentTime() 的表现 |
|---|---|
| 图片 + 有音频 | ✅ 正常前进（音频轨提供时长） |
| 图片 + 无音频 | ❌ 恒为 0（composition 无轨道） |
| 视频 + 有音频 | ✅ 正常 |
| 纯文字 / 纯 overlay（hasAnyVisual=false）| ❌ Runtime 未激活，无时钟 |

**正确语义**：Timeline Runtime 应当拥有独立的时钟，不依赖 AVPlayer 的内容是否有 duration。AVPlayer 负责音频播放和音频同步，画面时钟由 `TimelineClock` 管理（见 timeline-runtime-architecture.md §7.1）。

---

**正确渲染规则（P0-D 确认）**

```
当前时间有 image / video 主画面        → 渲染主画面（含 overlay/text 叠加）
当前时间无主画面，有 text/subtitle/sticker → 黑底 + overlay
当前时间无任何视觉层，有 audio         → 黑屏 + 继续播放音频（无需视觉渲染）
当前时间什么都没有                     → 真正空帧（达到 timeline.duration）
```

`timeline.duration = max(all tracks segments.targetRange.end)` 已正确（含所有轨道）。问题不在 duration 计算，在于渲染触发和时钟驱动。

---

**修复方向（P4.5 + P5 分层）**

**P4.5 快速修复（不引入独立 TimelineClock 时钟）**

修复点 A — 放宽 `hasAnyVisual` 条件：

```swift
// 当前（错误）：只检查主轨 image/video
let hasAnyVisual = !mainSegs.isEmpty && mainSegs.contains { ... }

// 修改为：timeline 存在任何可见内容即激活 Runtime
let hasAnyVisual = timeline.duration > 0 && timeline.tracks.contains {
    !$0.isHidden && !$0.segments.isEmpty
}
```

修复点 B — `CompositionBuilder` 确保 composition 始终有时长锚点轨道：

当 `isImageOnlyMainTrack` 或任何会产生零轨道 composition 的路径时，添加一条 `timeline.duration` 长的静音音频轨，确保 `AVPlayer` 能报告正确的 playback 时长：

```swift
// 在 isImageOnlyMainTrack 分支，buildAudio 完成后：
if composition.tracks.isEmpty {
    // 无任何素材轨道，添加静音占位轨保证 player 能报告时长
    addSilentAudioAnchor(to: composition, duration: totalDuration)
}
```

`addSilentAnchor` 实现：向 composition 添加一条 1 sample 的静音 audio track，时长 = totalDuration，音量设为 0。这是 AVFoundation 的标准做法，不影响最终音频输出。

修复点 C — 移除 `LayerResolver.resolve()` early return：

```swift
// 删除：guard !mainSegs.isEmpty else { return .empty }
// mainSegs 为空时，继续执行；overlay/text 层的时间解析不依赖 mainSegs
```

修复点 D — `LayerResolver` 全轨道解析（P5-B 先行部分）：

移除 early return 后，当前 overlay 轨道已能被解析。text / subtitle 轨道的解析为 P5-B 新增，P4.5 暂不引入。

修复点 E — 末態停驻（图片主轨尾部）：

这是"图片 + 有音频"场景下的尾部黑屏（原始分析中的正确部分）。`player.currentTime()` 超过最后图片 segEnd 后，LayerResolver 返回 empty。

推荐方案：`TimelineRenderer` 缓存最后一次成功渲染的 `CVPixelBuffer`。当 `LayerResolver` 返回 `.empty` 且 `compositionTime <= timeline.duration` 时，复用缓存帧展示（末態停驻）。此方案不修改 `ImageLayerComposer` 的时间守卫，边界清晰。

**P5 根本修复（独立时钟）**

P5 应将 `CompositionCoordinator.onRenderTick()` 中的时间来源从：
```swift
let compositionTime = player.currentTime().seconds  // 旧：AVPlayer 驱动
```
改为：
```swift
let compositionTime = timelineClock.currentTime     // 新：TimelineClock 自管
```

`TimelineClock` 在 `start()` 时基于系统时钟推进 `currentTime`（CADisplayLink.timestamp 差值累加），在 `stop()` / seek 时重置。AVPlayer 仅用于音频播放和同步，不再作为画面时间源。这与 `timeline-runtime-architecture.md §7.1` 的设计完全一致。

---

### BUG-3：image_3d / image_motion 动画过程中底部露黑

**现象**

- image_3d（2.5D parallax）动画过程中底部有时露黑边
- image_motion（pan/zoom 预设）在特定纵横比图片下偶现边缘露出

**根因分析**

`ImageLayerComposer.motionSafetyMargin()` 当前算法（第 226-250 行）：

```swift
// 位移取 max(|dx|, |dy|)
for p in kf.position {
    let dx = abs(p.value.x - 0.5)
    let dy = abs(p.value.y - 0.5)
    margin = max(margin, CGFloat(max(dx, dy)))
}
// scale < 1 时补 (1-s)/2
for s in kf.scale {
    if sv < 1.0 { margin = max(margin, (1.0 - sv) * 0.5) }
}
```

**缺陷一：位移与缩小未叠加**

当 animation 同时有 **位移 + 缩小** 时，margin 应为两者之和，而非取 max。

`applyDepthEffect` 中 pan_left：
- 结束时：position.x = 0.5 + panOffset = 0.5 + intensity，scale = 1.0 → margin_pos = intensity
- 开始时：position.x = 0.5，scale = 1.0 + intensity*0.5 → margin_scale = 0（scale > 1，不贡献 margin）
- `margin = max(intensity, 0) = intensity` → 看似正确

但 **zoom_out** 场景（scale 从 1+Z 降到 1.0）：
- scale 结束值 = 1.0，不触发 `sv < 1.0` 分支 → margin_scale = 0
- 实际上 scale 从 1.3 缩到 1.0 时，图片确实在收缩，但因结束值 = 1.0 未贡献 margin

**正确规则**：margin_scale 应由 scale 的**最小值**（而不仅是 < 1.0 判断）决定：
```
margin_scale = max(0, (1.0 - minScale) / 2.0)
```
当 minScale = 1.0（不缩小）→ 0；当 minScale = 0.95 → 0.025。

**缺陷二：斜向位移被低估**

斜向 pan（dx=0.06, dy=0.06）时，当前 margin = max(0.06, 0.06) = 0.06。但实际上需要对 x 和 y 方向分别保证覆盖：
- x 方向需 margin ≥ 0.06
- y 方向需 margin ≥ 0.06
- 当前 `fitTransform` 对 x/y 分别计算 safe scale 并取 max，所以取 max(safeX, safeY) 也分别满足

实际上 `fitTransform` 公式：
```swift
safe = max(baseScale,
    (W + 2*W*safeMargin)/imgW,    // x 方向
    (H + 2*H*safeMargin)/imgH)    // y 方向
```
使用同一个 `safeMargin`，x/y 同等放大。若 x/y 位移不同，应分别计算 x/y 的 safe scale。

**缺陷三：image_3d 深度合成层的 margin 未独立计算**

`AnimationMacro.applyDepthEffect` 为一个 KeyframeSet 生成位移+缩放关键帧。当 image_3d 展开为 3 个独立图层（前景/中景/背景，各有不同速率的位移）时，每层的 safeMargin 必须独立计算。

当前架构中 image_3d 仍作为单层渲染（未展开为 3 层），此缺陷在 P5 多轨道展开时才完整修复。

**P4.5 修复方向（不展开为 3 层）**

修复 `motionSafetyMargin`：

```swift
static func motionSafetyMargin(for keyframes: KeyframeSet?) -> CGFloat {
    guard let kf = keyframes, !kf.isEmpty else { return 0 }
    var marginX: CGFloat = 0
    var marginY: CGFloat = 0

    // 位移：分 x/y 轴独立计算
    for p in kf.position {
        marginX = max(marginX, CGFloat(abs(p.value.x - 0.5)))
        marginY = max(marginY, CGFloat(abs(p.value.y - 0.5)))
    }

    // 缩小：基于所有 scale 关键帧的最小值（含结束值 = 1.0）
    let minScale = kf.scale.map { CGFloat($0.value) }.min() ?? 1.0
    let scaleMargin = max(0, (1.0 - minScale) / 2.0)

    // 叠加（位移 + 缩小可同时发生）
    marginX += scaleMargin
    marginY += scaleMargin

    let margin = max(marginX, marginY)
    return margin > 0 ? margin + 0.02 : 0
}
```

修改 `fitTransform` 以支持 x/y 独立 margin（P4.5 可先用 max margin 统一，P5 再拆分）。

---

## 三、P5 架构目标确认

P5 是 Timeline Runtime 的"统一渲染"收口阶段，将当前分散的渲染路径合并为单一真相源。

### P5 核心原则（来自 timeline-runtime-architecture.md 第 4 节）

```
Timeline owns rendering.
AVPlayer only handles audio + video decoding.
Layer owns visual state.
Renderer owns frame output.
```

### P5 不能打破的约束

1. **P0-D 渲染规则**（layer-rendering-rules-spec.md）全部生效：末態停驻、空主轨黑底+overlay、全局帧率对齐。
2. **Preview/Export 同源**：`TimelineRenderer.renderFrame(at:)` 是唯一视觉真相，两条路径共用。
3. **不动 V1-V5 已锁的 EditorTimeline 数据模型**（KeyframeSet、EditorSegment、ContentFit 等）。
4. **不在 P5 引入 Metal 着色器**：继续使用 CIImage + CIContext Metal-backed context。

---

## 四、P5 分项需求（P5-A ～ P5-E）

### P5-A：Timeline 语义统一

**目标**：LayerResolver 的 `timeline.duration` 语义与 `EditorTimeline.duration` 完全一致。

**当前状态**：`LayerResolver.resolve()` 第 137 行提前返回（见 BUG-2 修复），且不处理空主轨的 overlay/sticker/text 层。

**P5-A 需求**：

1. 移除 `guard !mainSegs.isEmpty else { return .empty }` early return（BUG-2 已含）。
2. 即使 mainSegs 为空，也要解析并返回 overlay/sticker/text 层（目前仅处理 .image/.video overlay）。
3. 末態停驻：最后一个主轨段结束后，持续显示最后帧直到 `timeline.duration`。
4. "全黑"仅发生于 `activeLayers.isEmpty && compositionTime <= timeline.duration`。

**空主轨正确行为**（P0-D 规则）：
- 有 overlay / text / subtitle / sticker → 显示在黑底上
- 全空 → 黑屏（正确，不是 bug）

---

### P5-B：LayerResolver 全轨道化

**目标**：LayerResolver 解析所有视觉轨道，不仅仅是主轨 + overlay 轨。

**当前 LayerResolver 处理的轨道类型**：
- ✅ `isMainTrack`：image / video
- ✅ `.overlay` 轨道：image / video
- ❌ text / subtitle 轨道
- ❌ sticker 轨道

**P5-B 需求**：

`LayerContent` enum 扩展（`Runtime/LayerContent.swift`）：

```swift
public enum LayerContent: Sendable {
    case image(ImageLayerSpec)
    case video(VideoLayerSpec)
    case text(TextLayerSpec)      // P5 新增
    // case sticker(StickerLayerSpec)  // V6.1+ 保留
}
```

`LayerResolver.resolve()` 新增 text 轨道遍历：

```swift
for track in timeline.tracks(ofKind: .text).filter({ !$0.isHidden }) {
    for seg in track.segments {
        guard case .text(let tc) = seg.content else { continue }
        let start = compStartFor(seg)
        let end = start + seg.targetRange.duration
        if compositionTime >= start && compositionTime < end {
            let spec = TextLayerSpec(from: tc, seg: seg, at: compStart)
            activeLayers.append(ResolvedLayer(content: .text(spec), zIndex: seg.zPosition))
        }
    }
}
```

`TimelineRenderer.renderFrame(at:)` 新增 `.text` case 分派到 `TextLayerComposer.evaluate()`。

**TextLayerComposer**（新增文件）：核心是 CoreText → CIImage 渲染，复用已有 `TextStyle` 数据模型。P5 实现最小可用版本（纯文字，无动画），字幕/动画入场为 V6.1+。

---

### P5-C：VideoLayer 边界稳定

**目标**：消除全部视频段边界黑帧，包括首帧、尾帧、段间交界。

这是 BUG-1 的完整修复，P4.5 修复基础上进一步完善：

**需求 C-1：preload 预热 + 段切换 lastFrame 保留**（见 BUG-1 修复点 A/B）

**需求 C-2：尾帧钳制（clamp）**

`VideoFrameProvider.frame()` 在 `compositionTime` 接近 `end`（`end - compositionTime < 1 frame = 1/60s`）时，不依赖 `hasNewPixelBuffer`，直接尝试强制复用 `lastFrame`：

```swift
// 尾帧 clamp：在 segEnd 前最后一帧的窗口内，优先复用 lastFrame
let frameWindow = 1.0 / 60.0  // 1 frame
if compositionTime.seconds >= end.seconds - frameWindow {
    if let lastFrame = source.lastFrame { return lastFrame.buffer }
}
```

**需求 C-3：首帧首次渲染钳制**

段切换第一帧：若 localTime < 0.05s 且无可用帧，Preview 不允许自动回退到 `AVAssetImageGenerator`。fallback 会掩盖 `AVPlayerItemVideoOutput` 的 ready、seek、replay、time mapping 问题，并重新引入高内存与发热风险。

当前 P4/P5 过渡期的策略是：

- active playback：保留 last displayed/source frame，限频重挂 output 并 seek 到当前 sourceTime
- paused seek：保持 last displayed frame，等待 source seek completion / deferred retry 成功后再 replace
- 若仍无法取到目标帧，显式打印 frame miss / stale displayTime 日志，不静默兜底

后续若需要 deterministic seek，可评估 **Preview 专用 paused-seek reader cache / hybrid provider**，但该路径必须与播放态 `AVPlayerItemVideoOutput` 明确分层。

**需求 C-4：transition overlap 期间帧保护**

当 `LayerResolver` 检测到 transition zone 时，outgoing layer 的最后一帧和 incoming layer 的第一帧均通过 `VideoLayerComposer` 独立求值，不依赖 AVPlayerItemVideoOutput 的实时 buffer（两者均可能在 transition 期间出现 buffer miss）。

推荐：transition 期间对 outgoing/incoming 均启用 `reusableEndFrame` / preload 路径。

**需求 C-5：Preview provider 状态机重审**

2026-05-26 最新诊断显示：导出路径已稳定，但 Preview / FullScreenPreview 仍在播放、seek、replay 中偶发黑屏或卡帧。问题集中在 `PreviewFrameProvider` 的 realtime source player 同步，而非 `TimelineRenderer` 合成。

典型日志：

```text
hasNewPixelBuffer=false
reason=no new pixel buffer and no reusable source frame

reason=forced copy returned stale displayTime=4.1250
sourceTime=5.0033
```

解释：

- `hasNewPixelBuffer=false` 在播放中是正常状态，但如果没有可复用 frame，就会暴露为黑屏。
- `forced copy returned stale displayTime` 表示 `AVPlayerItemVideoOutput` 返回了旧 PTS 的帧；显示它会错帧/卡帧，拒绝它又会造成 video layer miss。
- 多 source hidden `AVPlayer` 与主 `AVPlayer` audio/clock 分离，进入 segment、seek、replay 时需要手动 seek/play/pause/preroll/reattach output。任一环节未同步，都会出现“音频继续、画面卡住或黑屏”。

P5-C 需要把 provider 状态机作为正式任务，而不是继续堆局部兜底：

| 状态 | 输入事件 | 预期动作 |
|---|---|---|
| inactive source | 进入 segment | reattach output（如需要）+ seek(sourceStart/localTime) + active playback 时 playImmediately |
| active playback | display tick | 不逐帧 seek，只取 output；miss 时短窗口 reuse；连续 stale/miss 时限频 recovery |
| paused seek | 用户拖动时间线 | 保持 last displayed frame；source seek 完成后 replace；不提前 flush preview layer |
| replay | duration -> 0 | 显式 playbackActive=true；重置 display enqueue time；source seek/play 与主 player 同步 |
| foreground resume | app 回前台 | force render + delayed render；必要时重建 output，不清空 displayed frame |

验收指标：

- 三段视频连续播放 30 次，无可见黑屏；允许短暂持帧但不能黑底。
- paused seek 连续拖动 50 次，预览区不全黑；目标帧在 200ms 内替换。
- replay 30 次，无“有声音但画面卡第一帧”。
- 全屏预览与编辑器预览行为一致。

---

### P5-D：Ken Burns / image_3d 修复

**目标**：图片动画全程不露黑边。

**需求 D-1：motionSafetyMargin 修复**（见 BUG-3 修复方向）

修改 `ImageLayerComposer.motionSafetyMargin(for:)` 为 x/y 分轴 + 累加 scaleMargin 逻辑。

**需求 D-2：fitTransform 支持 x/y 独立 margin**

当前 `fitTransform` 使用单一 `safeMargin`，对 x/y 同等放大。精确实现应分轴：

```swift
static func fitTransform(
    mode: ContentFit,
    imageExtent: CGRect,
    canvasSize: CGSize,
    safeMarginX: CGFloat = 0,  // 新增
    safeMarginY: CGFloat = 0   // 新增
) -> CGAffineTransform {
    ...
    let safeX = max(baseScale, (W + 2*W*safeMarginX) / imgW)
    let safeY = max(baseScale, (H + 2*H*safeMarginY) / imgH)
    let scale = max(safeX, safeY)   // 保持 uniform scaling
    ...
}
```

**需求 D-3：image_3d 正确 Ken Burns 路径**

当前 `AnimationMacro.applyDepthEffect()` 生成的 pan + counter-zoom 是单层 Ken Burns 模拟，不是真正的 2.5D parallax（3 层）。P5 阶段的目标：

- 继续使用单层 Ken Burns 模拟（不展开 3 层）
- 确保 `pan_direction + intensity` 组合下 safeMargin 计算正确
- 提供对齐 CapCut / 剪映 "parallax" 视觉效果的参数调校

3 层真实 parallax 展开（每层独立 ImageLayer + 独立 KeyframeSet）推迟至 V6.1+。

**需求 D-4：KeyframeEvaluator 末态钳制**

当前 `KeyframeEvaluator.interpolate()` 在 t >= last.time 时返回 last.value（已实现）。确认：
- 末態停驻期间 `localTime` 应钳制为 `segDuration`，不超过最后一个关键帧时间的范围。
- 修改 `ImageLayerComposer.evaluate()` 第 145 行：`let localTime = max(0.0, min(elapsed, totalDuration))` — 已正确。

---

### P5-E：Export 同源

**目标**：导出不再依赖旧的 `AVVideoCompositing` / `AVAssetExportSession` 路径，改用 `TimelineRenderer + AVAssetWriter`。

**当前状态**（`Export/VideoExporter.swift`）：

当前 `VideoExporter` 已进入 P5 provider 拆分阶段：视觉帧由 `TimelineRenderer` 驱动，视频素材帧由 `ExportFrameProvider` 使用 `AVAssetReaderTrackOutput` 顺序读取。根据 V6 架构设计（`timeline-runtime-architecture.md` §8），目标架构：

```swift
class VideoExporter {
    func export(timeline: EditorTimeline, config: ExportConfig, to outputURL: URL) async throws {
        let renderer = TimelineRenderer()
        renderer.update(timeline: timeline, canvasSize: config.resolution.size)

        // 导出路径：顺序遍历帧，不依赖 CADisplayLink
        let frameCount = Int(timeline.duration * config.fps.value)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(config.fps.value))

        // AVAssetWriter setup ...
        for i in 0 ..< frameCount {
            let time = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(config.fps.value))
            guard let pixelBuffer = renderer.renderFrame(at: time.seconds) else { continue }
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }
        // finalize ...
    }
}
```

**需求 E-1：VideoExporter 接入 TimelineRenderer**

`TimelineRenderer` 需新增 export-mode provider 切换：
- Preview：使用 `AVPlayerItemVideoOutputProvider`（当前 P4 路径）
- Export：使用 `ExportFrameProvider` / `AVAssetReaderTrackOutput` 顺序路径

禁止将 `AVAssetImageGenerator` 作为导出主路径。它只适合 thumbnail/debug 单帧场景，不适合作为高帧率导出取帧主力。

**需求 E-2：音频导出独立处理**

`AVAssetWriter` 写入视频帧时，音频轨道通过 `AVAssetReader` 读取所有 audio segment 的 PCM 数据，独立写入 `AVAssetWriterInput(mediaType: .audio)`。

复用 `CompositionBuilder.buildAudioMixOnly` 生成的 `AVAudioMix`，或直接用 `AVAssetReaderAudioMixOutput`。

**需求 E-3：导出与预览一致性验证**

| 帧位置 | Preview（renderFrame）| Export（renderFrame）| 预期一致 |
|---|---|---|---|
| 图片段内任意帧 | ✅ | ✅ | 结构保证 |
| 视频段任意帧 | AVPlayerItemVideoOutput | AVAssetReaderTrackOutput | 解码后 YUV→RGB 结果应相同 |
| 转场叠化帧 | ✅ | ✅ | 结构保证 |
| 末態停驻帧 | ✅ | ✅ | 结构保证 |

---

## 五、P4.5 vs P5 范围边界

| 问题 | P4.5 | P5 |
|---|---|---|
| 视频首帧/尾帧黑屏 | ⚠️ lastFrame / preload / recovery 降低概率 | Preview provider 状态机完整验收 |
| 播放/seek/replay 黑屏或卡帧 | ⚠️ 仍存在，Preview-only | P5-C provider 状态机 + paused-seek deterministic 路径 |
| 纯图片无音频无法播放 | ✅ 静音锚点轨 + `hasAnyVisual` 修复 | TimelineClock 独立时钟（P5 根本修复）|
| 纯图片有音频尾部黑屏 | ✅ 末態停驻（TimelineRenderer 缓存帧）| — |
| 空主轨 text/overlay 全黑 | ✅ `hasAnyVisual` 修复 + LayerResolver early return 移除 | 全轨道文字渲染（P5-B）|
| image_3d / image_motion 露黑 | ✅ motionSafetyMargin 修复 | image_3d 3 层展开（V6.1+）|
| LayerResolver 全轨道解析（text/sticker）| ❌（不含）| ✅ P5-B |
| Export 同源 | ✅ `ExportFrameProvider` 已切到 AVAssetReader 主线 | P5-E 持续补验证矩阵 |
| TextLayerComposer | ❌（不含）| ✅ P5-B |
| TimelineClock 独立时钟 | ❌（不含）| ✅ P5（`TimelineClock.currentTime` 替代 `player.currentTime()`）|
| AVVideoCompositing 废除 | ❌（不含）| ✅ P5 后期 |

---

## 六、P4.5 修改文件清单

| 文件 | 修改内容 | 预计改动量 |
|---|---|---|
| `Rendering/CompositionCoordinator.swift` | `hasAnyVisual` 放宽为 `timeline.duration > 0 && 有可见 segment` | ~10 行 |
| `Rendering/CompositionBuilder.swift` | `isImageOnlyMainTrack` 分支：composition 零轨道时添加静音锚点轨 | ~20 行 |
| `Runtime/LayerResolver.swift` | 移除 `guard !mainSegs.isEmpty` early return | ~5 行 |
| `Runtime/TimelineRenderer.swift` | 末態停驻：缓存最后非空 CVPixelBuffer，empty frame 且 compositionTime ≤ duration 时复用 | ~20 行 |
| `Rendering/VideoFrameProvider.swift` | `updateActiveSegmentIfNeeded` 不清空 lastFrame；`preload` 预热 seek；尾帧 clamp | ~30 行 |
| `Rendering/ImageLayerComposer.swift` | `motionSafetyMargin` x/y 分轴 + 累加 scaleMargin | ~20 行 |

**无需新增文件**。P5 新增 `TextLayerSpec.swift`、`TextLayerComposer.swift`、`AVAssetReaderVideoFrameProvider.swift`。

---

## 七、P4.5 验收标准（KPI）

| 项目 | 指标 |
|---|---|
| 纯图片无音频 | 进入编辑器后可正常播放，画面随时间推进显示各图片片段 |
| 纯图片有音频 | 图片片段结束后至 timeline 末尾，最后一帧持续展示（末態停驻）|
| 视频首帧 | 初始加载后首帧显示时延 ≤ 100ms（含 deferred retry）|
| 视频尾帧 | seek 到任意 segEnd-ε，无黑帧（目视 30 次重复）|
| 段间交界 | 无过渡时两段视频交界处黑帧时长 < 1 frame（16.7ms）|
| 空主轨 + text/overlay | 可见 overlay 图层在黑底上正常渲染（hasAnyVisual 修复后）|
| image_motion 露黑 | 所有 8 个 preset 在 0→10s 动画中不露黑边 |
| image_3d 底部 | pan_down / pan_up intensity=0.15 时底部无黑边 |

---

## 附录 A：关键代码位置速查

| 问题 | 文件 | 关键位置 |
|---|---|---|
| `hasAnyVisual` 条件过窄 | `Rendering/CompositionCoordinator.swift:141` | `let hasAnyVisual = !mainSegs.isEmpty && ...` |
| 零轨道 composition（图片+无音频）| `Rendering/CompositionBuilder.swift:152` | `if isImageOnlyMainTrack(timeline)` 分支，buildAudio 后无兜底 |
| LayerResolver early return | `Runtime/LayerResolver.swift:137` | `guard !mainSegs.isEmpty else { return .empty }` |
| 时钟来源绑定 AVPlayer | `Rendering/CompositionCoordinator.swift:254` | `let compositionTime = player.currentTime().seconds` |
| 段切换时 lastFrame 清空 | `Rendering/VideoFrameProvider.swift` | `source.lastFrame = nil` in `updateActiveSegmentIfNeeded` |
| preload 未预热 sourceStartTime | `Rendering/VideoFrameProvider.swift` | `func preload(videoSpecs:)` |
| 段时间范围守卫（VideoProvider）| `Rendering/VideoFrameProvider.swift:229` | `guard compositionTime >= start, compositionTime < end` |
| ImageLayerComposer 时间守卫 | `Rendering/ImageLayerComposer.swift:109` | `guard compositionTime >= start, compositionTime < end` |
| motionSafetyMargin 缺陷 | `Rendering/ImageLayerComposer.swift:226` | `static func motionSafetyMargin` |

---

## 附录 B：P5 新增文件预期

| 文件 | 功能 | P5 里程碑 |
|---|---|---|
| `Runtime/TextLayerSpec.swift` | 文字图层数据模型 | P5-B |
| `Rendering/TextLayerComposer.swift` | CoreText → CIImage 渲染 | P5-B |
| `Rendering/AVAssetReaderVideoFrameProvider.swift` | 导出路径顺序解码 | P5-E |
| `Export/VideoExporter+Runtime.swift` | TimelineRenderer 驱动的导出路径 | P5-E |
