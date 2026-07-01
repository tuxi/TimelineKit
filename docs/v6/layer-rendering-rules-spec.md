# 分层渲染规则固化规范（v6）

> 版本：v6.0
> 状态：规范定稿，待实现
> 优先级：P0-D（架构打底第四阶段，依赖 P0-A / P0-B / P0-C 全部跑通）
> 对标产品：剪映 / CapCut / FCP / LumaFusion（均强制关键帧末态停驻 + 空段黑屏 + overlay 透出）
> 依赖：
> - v6 [image-layer-rendering-spec.md](image-layer-rendering-spec.md)：imageLayers 渲染基础设施
> - v6 [keyframe-animation-spec.md](keyframe-animation-spec.md)：末态求值器返回最后关键帧值
> - [CompositionBuilder.swift](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift)：unified instruction 构造（§2 规则实现地）
> - [UnifiedCompositor.swift](../../Sources/TimelineKit/Rendering/UnifiedCompositor.swift)：compositor 层 §2-§5 规则执行地
> - memory: `project_timelinekit_v5_1.md` 中 V5.1 三项遗留（天然消解点）

---

## 一、覆盖范围

本规范定义 V6 unified compositor 下 **图片图层（及与其他图层共存时）的硬渲染规则**，全部在 unified 单一路径下固化：

1. **主轨道按时序逐帧实时绘制规则**
2. **超出主轨道画面时长区间的叠加/黑屏规则**
3. **动画末态停驻规则**
4. **全局帧率对齐规则**
5. **V5.1 三项遗留的消解声明**

---

## 二、规则 1 — 主轨道按时序逐帧实时绘制

### 2.1 规则

无论主轨道为视频（AVAssetTrack）还是图片（imageLayers），compositor 必须在 `compositionTime` 落在 instruction 时间区间内时输出对应的帧。不存在「跳过一些帧」「使用上一帧」的情况。

### 2.2 实现

- UnifiedCompositor 的 `startRequest` 接收 `request.compositionTime`
- 按 instruction 的 timeRange 筛选激活的图层
- 视频段落：`request.sourceFrame(byTrackID:)`
- 图片段落：`ImageLayerComposer.evaluate(at: compositionTime)`
- 输出当前时间的渲染结果

### 2.3 与 V5 的差异

V5 的 sentinel 帧 + `setOpacity(0, at: mainVideoEnd)` 在 unified 路径下是「靠 AVFoundation 的 layer 缓存隐式显示 sentinel 帧最后一刻的快照」。V6 去掉 sentinel 帧，主轨尾段时间由规则 2 的 `isBlackOut` 显式处理。

---

## 三、规则 2 — 主轨道结束后的黑屏与 overlay 透出

### 3.1 规则

在 composition 时间线上，`compositionTime >= mainVideoEnd` 之后：

- **存在 overlay 图层、且其 timeRange 覆盖此时间** → overlay 图层正常渲染，背景为黑屏
- **不存在 overlay 图层** → 全黑屏
- **不存在任何覆盖此时间的图层** → 全黑屏

### 3.2 mainVideoEnd 计算

保持 V5.1 的 `max(targetRange.end)` 方法（非 `segments.last`）：

```swift
let mainVideoEnd = mainSegments.map { $0.targetRange.end }.max() ?? .zero
```

`mainSegments` = 所有 `kind == .main` 且 `!isHidden` 的非空轨道上的段落。

### 3.3 Compositor instruction 拆分

**规则 2 的 instruction 构造逻辑**（在 CompositionBuilder 中）：

```
将 composition 时间线切分为两个 instruction：
  A. [0, mainVideoEnd]：layerInstructions = [所有 main + overlay 图层的组合]
  B. [mainVideoEnd, totalDuration]：
     - 有 overlay 覆盖 → layerInstructions = [overlay 指令], backgroundColor = black
     - 无 overlay 覆盖 → isBlackOut = true, requiredSourceTrackIDs = []
```

### 3.4 图片作为 overlay 的透出

图片图层（来自 `.overlay` track 的 `.image / .image_motion / .image_3d` 段落）在 compositor 层与视频 overlay 完全一致——`ImageLayerComposer.evaluate` 按 overlay 图层的自身 timeRange 和 keyframes 求值。

---

## 四、规则 3 — 动画末态自然停驻收尾帧

### 4.1 规则

当关键帧在 `timeFraction = 1.0` 处定义了最终值（position / scale / rotation / anchor / opacity），在 segment 的 timeRange 结束时刻、以及在后续的转场 overlap 区间内，该值必须保持——不倒回、不回溯、不跳变到前一个关键帧的值。

### 4.2 实现原理

KeyframeEvaluator 的插值函数在 `t >= lastPoint.timeFraction` 时返回 `lastPoint.value`。这使得 segment 末尾自动停在最后一个关键帧值——无需 sentinel 帧、无需 opacity 钳层。

### 4.3 与 V5 的差异

| 场景 | V5 StaticImageRenderer | V6 |
|---|---|---|
| segment 结束时最后关键帧值 | sentinel 帧 baked in（与 MP4 帧一起硬编码）→ 若 sentinel 丢失或 opacity=0 钳制生效 → 回溯上一帧 | KeyframeEvaluator 自然返回 last.value |
| 转场 overlap 期间 | two clips' original MP4s 同时播放 → 各自 sentinel 决定了尾帧可见性 | each clip's KeyframeEvaluator returns last.value until the clip's instruction ends |
| video→image 过渡 | image MP4 在 sentinel 帧开始处可能闪 frame | image CIImage 以稳定值持续输出到 segment.timeRange.end |

---

## 五、规则 4 — 全局帧率对齐

### 5.1 规则

所有段落（视频 + 图片图层）的帧输出时机统一对齐 `timeline.canvas.fps`（工程全局帧率）。compositor 的 `sourcePixelBufferAttributes` 和 `requiredPixelBufferAttributesForRenderContext` 不因段落类型而改变。

### 5.2 实现

- Canvas fps 在 `CompositionBuilder.build` 时通过 `AVMutableVideoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(canvas.fps))` 传入
- 图片图层在 fps=30 工程中每 33.3ms 被求值一次，输出 CIImage → render to CVPixelBuffer
- 视频图层在 fps=30 工程中从 sourceTrack 提取最近的帧，与图片输出帧时间戳对齐

### 5.3 消除的旧问题

V5 的 StaticImageRenderer 对「静态图使用 fps=1 编码、动效图使用 canvas.fps 编码」导致转场时 fps 跳变。V6 中所有图片图层统一按 canvas.fps 出帧，破坏性差距消失。

---

## 六、V5.1 三项遗留天然消解

### 6.1 unified 路径 overlay 不渲染

**V5.1 状态**：`buildVideoTrackUnified` 不支持 overlay 渲染。带转场的 composition 中 overlay 不可见。

**V6 消解**：V6 起所有图片段落（包括 overlay）强制走 unified 路径，图片 overlay 与视频 overlay 在 compositor 层等权处理。overlay 图层的 `ImageLayerSpec` 按照其 `zPosition` 和 `timeRange` 正常参与每帧合成。

### 6.2 FullScreenPreview + 字幕 + overlay 三者组合不可见

**V5.1 状态**：unified 路径不支持 overlay；FullScreenPreview 走 `renderSubtitles: true` 烘焙字幕到 CIImage，但 overlay 图层在此路径下丢失。

**V6 消解**：V6 统一 unified 路径后，FullScreenPreview 使用的 `CompositionBuilder.build(renderSubtitles: true)` → UnifiedCompositor 在每帧同时处理 imageLayers + video sourceFrame + subtitle CIImage 叠加。三者无一丢失。

### 6.3 v1 trim handle 超 nativeDuration

**V5.1 状态**：image / image_motion / image_3d 的右 handle 在某些情况下可拖到超过 `nativeDuration`。

**V6 消解**：此问题是 prebake MP4 的 `resolutionSegmentsURL` 返回的 MP4 文件 duration 与数据模型 duration 不一致的副作用。V6 废除 prebake 后，图片图层的 timeRange 严格基于 `segment.targetRange`，无 MP4 容器 duration 与模型 duration 脱节的媒介——trim handle 问题自然消解。

---

## 七、规则违反检测（debug 编译期）

### 7.1 帧漏检

在 `#if DEBUG` 下，UnifiedCompositor 维护一个 `lastCompositionTime` 计数器。若相邻两次 `startRequest` 之间的时间差 > `2 / fps`（跳帧 > 2），向日志输出 warning。

### 7.2 imageLayers + sourceTrack 互斥

在 CompositionBuilder 构造 unified instruction 时添加断言：

```swift
assert(instruction.imageLayers.isEmpty || instruction.requiredSourceTrackIDs.isEmpty,
       "V6 rule: imageLayers and sourceTracks are mutually exclusive per instruction")
```

---

## 八、验证点

| 验证项 | 预期行为 | 方法 |
|---|---|---|
| 主轨末段空 | 全黑屏，无尾帧驻留 | AI 工程末尾视觉检查 |
| 主轨末段 + overlay | overlay 正常渲染在黑背景上 | 删除主轨末段 → 仅 overlay 段仍可见 |
| 动画末态停驻 | 末帧不回跳到前一个关键帧 | 截屏 t=0.99, t=1.0 同值 |
| 图片 + 视频 fps 一致 | Metal HUD 显示恒定 fps，无跳变 | fps counter |
| 图片 overlay 可见 | unified 路径 overlay 图片正常 | 拖一个 overlay 图片到工程 → 预览 |
| FullScreen + 字幕 + overlay | 三者共存可见 | 打开全屏预览 → 截屏 |
| trim handle 不超限 | image / image_motion / image_3d 右 handle 严格 ≤ nativeDuration | 尝试拖拽超限 |
| 1 帧不漏 | 时间差 ≤ 2/fps | debug warning 检查 |

---

## 九、V6 固定交互约束重申

> 见 [V6-initiation.md §7](V6-initiation.md)。实现本 spec 时须遵守：
> - **图片图层渲染走唯一 unified 路径**：V6 起 single-pass 路径不再处理图片段落
> - **关键帧时间因子标准化（0~1）**
> - **StaticImageRenderer.swift 保留代码作历史参考**
> - 其他约束全文见 V6-initiation.md §7
