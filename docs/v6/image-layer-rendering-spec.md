# 图片原生图层渲染规范（v6）

> 版本：v6.0
> 状态：规范定稿，待实现
> 优先级：P0-A（架构打底第一阶段，所有后续里程碑的前置）
> 对标产品：剪映 iOS / CapCut / FCP / LumaFusion（全部不用 prebake MP4）
> 依赖：
> - v1 [avfoundation-rendering-architecture.md](../v1/avfoundation-rendering-architecture.md)：UnifiedCompositor 基线架构
> - v6 [competitive-benchmarks-v6.md](competitive-benchmarks-v6.md) §1 / §6：图片渲染架构与 compositor 选型定档
> - [CompositionBuilder.swift:672-697](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) `resolveSegmentURL`（要废除的图片 prebake 入口）
> - [UnifiedCompositor.swift:96-354](../../Sources/TimelineKit/Rendering/UnifiedCompositor.swift)（要扩展的核心组件）
> - [StaticImageRenderer.swift](../../Sources/TimelineKit/Rendering/StaticImageRenderer.swift)（要废弃的组件，仅保留代码作历史参考）

---

## 一、覆盖范围

本规范覆盖 V6 P0-A「图片原生图层渲染」的全部设计与约束：

1. **废除 prebake MP4 路径**：CompositionBuilder 不再对图片段落调用 StaticImageRenderer
2. **定义 ImageLayerSpec**：作为图片图层的负载数据模型，挂载到 UnifiedCompositorInstruction
3. **实现 ImageLayerComposer**：图片图层求值器，输入 ImageLayerSpec + 当前 compositionTime，输出 CIImage
4. **扩展 UnifiedCompositor**：在 `startRequest` 中识别 imageLayers 并走新渲染分支
5. **性能策略**：CIImage lazy chain、CVPixelBuffer pool、CIContext 共享、降级路径

---

## 二、废除旧逻辑

### 2.1 下线 CompositionBuilder 的图片 prebake 分支

**现状**（[CompositionBuilder.swift:672-697](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift)）：

```swift
// 旧代码（V5，要被 V6 废除）
func resolveSegmentURL(_ seg: EditorSegment) async throws -> URL {
    switch seg.content {
    case .image(let img):
        return try await StaticImageRenderer.shared.render(
            imageURL: img.url,
            content: img,
            duration: seg.targetRange.duration,
            fps: timeline.canvas.fps,
            renderSize: canvas.renderSize
        )
    // ...
    }
}
```

**V6 改造**：

- 删除 `.image / .image_motion / .image_3d` 三个 case 的 prebake 调用
- 图片段落不再返回 MP4 URL；改为在 unified 指令构造阶段（`buildVideoTrackUnified`）生成 `UnifiedCompositorInstruction` 并携带 `imageLayers: [ImageLayerSpec]`
- 图片段落的 `requiredSourceTrackIDs` 设为 `[]`（空数组），告诉 compositor 本指令无 AVAssetTrack 源
- `resolveSegmentURL` 方法只保留 `.video / .ai_video / .audio` 分支

### 2.2 下线静态图 / 动效图差异化 fps 逻辑

StaticImageRenderer 行 105 的差异化 fps（静态 1fps vs 动效全 fps）是 prebake 时期针对「静态图节约编码性能」的优化。废除 prebake 后这个分支完全消除——**所有图片图层统一按 canvas.fps 出帧**，帧率不再由内容类型决定。

**收益**：转场时序不再受 fps 跳变影响；帧级一致性由 canvas.fps 唯一保证。

### 2.3 下线 sentinel 帧 + 临时文件缓存

StaticImageRenderer 行 173-207 的 sentinel 帧、行 66-73 的 `/tmp/img_{key}.mp4` 缓存全部随静态渲染器下线。替换策略见 [transition-compat-spec.md](transition-compat-spec.md) §4。

---

## 三、ImageLayerSpec — 图片图层负载数据模型

### 3.1 结构定义

新建文件：`Sources/TimelineKit/Rendering/ImageLayerComposer.swift`（开头定义）。

```swift
/// 单一图片图层的完整规格——无 AVAssetTrack 源的 CIImage 输出负载
struct ImageLayerSpec: Codable, Sendable {
    /// 图片源文件 URL
    var imageURL: URL
    /// 画布渲染尺寸（用于 fit 计算）
    var renderSize: CGSize
    /// 图片适配模式（cover / contain）
    var contentMode: ImageContentMode
    /// 时间区间（在 composition 中的绝对时间）
    var timeRange: CMTimeRange
    /// 关键帧集合（nil = 无动画的静态图片）
    var keyframes: KeyframeSet?
    /// 图层 z-order 排序键（越大越上层）
    var zPosition: Int32
    /// 不透明度（0-1），可与关键帧中的 opacity 叠加
    var baseOpacity: Float
}
```

**关键字段语义**：

- `imageURL`：可以是本地相册 URL、AI 下发 URL、或预下载后的磁盘路径
- `renderSize`：从 `EditorCanvas.renderSize` 复制；用于统一计算 fit transform
- `timeRange`：CMTimeRange(start: segment.targetRange.start, duration: segment.targetRange.duration)。compositor 在 `compositionTime` 落在此区间内时才求值此图层
- `keyframes`：nil → 静态图（使用 baseScale + identity transform）；非 nil → KeyframeEvaluator 在每帧计算复合变换矩阵
- `zPosition`：多图层合成顺序键；值越大越上层；parallax 利用不同 zPosition 排列前景 / 中景 / 背景
- `baseOpacity`：无关键帧时的静态不透明度；有关键帧时与 `KeyframeSet.opacity` 相乘

### 3.2 替代旧的 resolveSegmentURL → AVAssetTrack 流

**对比旧模型**：

```
V5:  URL → StaticImageRenderer.render → MP4 → AVURLAsset → AVAssetTrack → AVMutableComposition.insertTimeRange
V6:  URL → ImageLayerSpec (data payload) → UnifiedCompositorInstruction.imageLayers → ImageLayerComposer.evaluate(at:) → CIImage
```

不再经过 AVAssetTrack、不再创建 MP4 临时文件、不再经过 VideoToolbox 编解码。

### 3.3 Codable 兼容

`ImageLayerSpec` 实现 Codable：`imageURL` 编码为 `url.absoluteString`，解码时 `URL(string:)` 还原；`CMTimeRange` 编码为 `(start.seconds, duration.seconds)` pair。

---

## 四、ImageLayerComposer — 图片图层求值器

### 4.1 核心接口

```swift
actor ImageLayerComposer {
    /// 为指定时间求值单个图片图层的 CIImage
    /// - Parameters:
    ///   - spec: 图层规格
    ///   - compositionTime: 当前合成时间（composition 绝对时间）
    ///   - ciContext: 共享的 CIContext
    /// - Returns: CIImage（未合成到输出 buffer），spec.timeRange 不包含 compositionTime 时返回 nil
    func evaluate(
        spec: ImageLayerSpec,
        at compositionTime: CMTime,
        ciContext: CIContext
    ) async -> CIImage?
}
```

### 4.2 内部求值步骤

```
Step 1: timeRange check —— compositionTime 不在 [start, end) → return nil
Step 2: load CIImage(contentsOf: spec.imageURL) —— Apple 内置 RAW/HEIF/ProRAW 解码，lazy
Step 3: fitTransform(spec.contentMode, ciImage.extent, spec.renderSize) → baseScale + centerOffset
Step 4: 如果 spec.keyframes != nil → KeyframeEvaluator.evaluate(keyframes, at: timeFraction) → motionMatrix
Step 5: combined = baseTransform * motionMatrix
Step 6: return ciImage.transformed(by: combined)
```

**Step 3 细节（图片 fit 计算）**——复刻 StaticImageRenderer 行 137-156 的 cover/contain 逻辑：

```swift
func fitTransform(_ mode: ImageContentMode, imageExtent: CGRect, canvas: CGSize) -> CGAffineTransform {
    let imgW = imageExtent.width
    let imgH = imageExtent.height
    let canvasW = canvas.width
    let canvasH = canvas.height
    let scaleX = canvasW / imgW
    let scaleY = canvasH / imgH

    let scale: CGFloat
    switch mode {
    case .cover:   scale = max(scaleX, scaleY)  // 填满画布，边缘可裁切
    case .contain: scale = min(scaleX, scaleY)  // 全图可见，留黑边
    }

    let dx = (canvasW - imgW * scale) * 0.5
    let dy = (canvasH - imgH * scale) * 0.5
    return CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: dx / scale, y: dy / scale)
}
```

与 StaticImageRenderer 的唯一差异：V5 在 cvPixelBuffer 上做变换，V6 在 CIImage 上做（数学完全相同，少了编码/解码往返）。

### 4.3 性能关键路径

- `CIImage(contentsOf: url)` 是 lazy decoding——不解析全像素，只在最终 `CIContext.render()` 时按输出分辨率采样。这意味着 48MP ProRAW 图片在 1080P canvas 上只读 2MP 像素
- `ciImage.transformed(by:)` 不会立即栅格化，而是累积到一个复合变换矩阵
- Step 5 `combined = base * motion` 是两个 3x3 矩阵的 M34 乘法（核心运算量：9 次 multiply + 6 次 add）

**多图层优化**：多图层逐个 evaluate 后得到 `[CIImage]`，再通过 `CIImage.sourceOverCompositing` 递归合成最终帧。CIImage 的 lazy chain 性质使整条链在 `CIContext.render(finalCI, to: outputBuffer)` 时才一次性求值——不会产生中间 buffer。

---

## 五、UnifiedCompositor 扩展

### 5.1 UnifiedCompositorInstruction 新增字段

在 [UnifiedCompositor.swift 行 33-42](../../Sources/TimelineKit/Rendering/UnifiedCompositor.swift) 的 `UnifiedCompositorInstruction` 结构体中新增：

```swift
/// V6 新增：图片图层负载（无 AVAssetTrack 源的 CIImage 提供者）
var imageLayers: [ImageLayerSpec] = []
```

向后兼容：旧指令（视频段落）imageLayers 为空数组 ≡ 走现有 sourceFrame 路径。

### 5.2 startRequest 分流逻辑

在 [UnifiedCompositor.swift 行 130-156](../../Sources/TimelineKit/Rendering/UnifiedCompositor.swift) 的 `startRequest` 方法开头新增分流：

```swift
// V6: 检测图片图层
if !instruction.imageLayers.isEmpty {
    Task {
        var layerImages: [CIImage] = []
        for spec in instruction.imageLayers.sorted(by: { $0.zPosition < $1.zPosition }) {
            if let ci = await imageLayerComposer.evaluate(spec: spec, at: request.compositionTime, ciContext: context) {
                layerImages.append(ci)
            }
        }
        if layerImages.isEmpty {
            // 当前时间没有激活的图片图层 → 黑屏
            request.finish(with: CompositionError.missingFrame)
            return
        }
        var finalCI = layerImages[0]
        for i in 1..<layerImages.count {
            finalCI = layerImages[i].composited(over: finalCI)  // 上层叠下层
        }
        // 字幕烘焙（复用 V5 已有逻辑）
        if let subCI = instruction.subtitleImage {
            finalCI = subCI.composited(over: finalCI)
        }
        renderAndFinish(finalCI, at: request.compositionTime, to: request, pool: bufferPool)
    }
    return
}

// 旧路径：sourceFrame（视频段落）—— V5 逻辑不变
```

### 5.3 与现有 sourceFrame 路径的共存

- 同一 instruction 可同时有 `imageLayers` 和 `foregroundTrackID / backgroundTrackID`？**不允许**：imageLayers 的存在表示此指令为纯图片图层段落，不产生 AVAssetTrack。规范层面由 CompositionBuilder 在构造 instruction 时保证互斥
- 同一 composition 内可以有多个 instruction，部分有 imageLayers（图片段落），部分有 source tracks（视频段落）——这是正常的混合时间轴

### 5.4 isBlackOut 路径保留

V5.1 引入的 `UnifiedCompositorInstruction.isBlackOut` 路径（主轨结束后的纯黑指令）**完整保留**，不受 imageLayers 改动影响。

---

## 六、CompositionBuilder 改造

### 6.1 移除图片 prebake

在 [CompositionBuilder.swift 行 672-697](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) 的 `resolveSegmentURL`：

- **删除** `.image / .image_motion / .image_3d` 三个 case
- **保留** `.video / .ai_video / .audio` 分支

### 6.2 在 buildVideoTrackUnified 中构造 imageLayers

在 [CompositionBuilder.swift `buildVideoTrackUnified`](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) 中，遍历到图片段落时：

1. 不再调用 `insertTimeRange` 创建 AVAssetTrack
2. 改为构造 `ImageLayerSpec`：
   - `imageURL` = `seg.content.image.url`
   - `renderSize` = `timeline.canvas.renderSize`
   - `contentMode` = `seg.content.image.fit` (cover / contain)
   - `timeRange` = `CMTimeRange(start: seg.targetRange.start, duration: seg.targetRange.duration)`
   - `keyframes` = seg.content.image.keyframes（若有）或 `AnimationMacro.expand(motionPreset: depthEffect: duration:)` 的结果
   - `zPosition` = 从 track.zPosition 派生
   - `baseOpacity` = 1.0（无关键帧默认）
3. UI 层保留 `motionPreset` / `depthEffect` 预设入口，但 runtime 一律展开为 `keyframes`
4. 同一 instruction 下多个 overlay 图片图层合并为一个 `imageLayers` 数组

### 6.3 强制统一走 unified 路径

**V6 新规则**：含图片段落的 composition **强制走 unified 路径**（`buildVideoTrackUnified`），不再有 single-pass 图片分支。

视频-only 的 composition 保留 single-pass 短路优化（不衰退）。

---

## 七、向下兼容

### 7.1 旧草稿加载

旧草稿 (`image_motion / image_3d` 段落的 `ImageContent.keyframes == nil`) 加载时：

1. `TimelineImporter` 或草稿加载逻辑检测 `ImageContent.keyframes == nil`
2. 调用 `AnimationMacro.expand(motionPreset: img.motionPreset, depthEffect: img.depthEffect, duration: seg.targetRange.duration)`
3. 结果赋值到 `ImageContent.keyframes`
4. 后续 V6 渲染管线对旧草稿与新建工程完全一致

### 7.2 旧草稿转场

旧草稿转场在 V5 已通过 `buildVideoTrackUnified` 处理（转场 instruction 与段落 instruction 分开构造）。V6 不改动转场 instruction 的构造逻辑——只替换图片段落的内部渲染方式。

---

## 八、验证点

| 验证项 | 预期行为 | 对照基准 |
|---|---|---|
| 静态相册图能播放 | 图片正常渲染，无 MP4 生成 | `ls /tmp/img_*.mp4` 无新文件 |
| 静态图帧率 | 与 canvas.fps 一致 | Metal Performance HUD 显示 30fps (canvas default) |
| 图片 cover/contain fit | 与 V5 StaticImageRenderer 视觉对齐 | 截屏 diff ≤ 2px |
| 图片段尾视频继续 | 图片时间区间结束后，下个视频段落正常播放 | 无尾帧冻结 |
| AI image_motion（zoom_in × 6 方向）| 动画与 V5 StaticImageRenderer 对齐 | 截屏 3 个时间点 / 12 个组合 diff ≤ 2px |
| 混合时间轴（图片→转场→视频）| 全链路无断帧 | seek 逐帧无 nil |
| overlay 图片 + 字幕 | 字幕叠加于图片之上 | 截屏验证层次正确 |

---

## 九、V6 固定交互约束重申

> 见 [V6-initiation.md §7](V6-initiation.md)。实现本 spec 时须遵守：
> - **图片图层渲染走唯一 unified 路径**
> - **StaticImageRenderer.swift 保留代码作历史参考**（本 spec §2 仅断引用，不物理删除）
> - **CompositionBuilder.build 向后兼容**（renderSize / fps 可选参数不变）
> - 其他约束全文见 V6-initiation.md §7
