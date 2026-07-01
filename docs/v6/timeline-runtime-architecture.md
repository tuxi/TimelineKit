# TimelineKit V6 Timeline Runtime 架构重调研

> 版本：v6.1（架构调研稿）
> 状态：调研定稿，待技术评审后决策执行路径
> 触发背景：AVPlayer + AVVideoCompositing 在 image-only segment 的 seek/play 不一致问题持续，图片动画 play 路径静止、sentinel hack 无法彻底解决
> 关联文档：[image-realtime-playback-issue-analysis.md](image-realtime-playback-issue-analysis.md)（当前问题归档）、[V6-initiation.md](V6-initiation.md)（V6 总立项）

---

## 一、V6 当前问题复盘

### 1.1 现象

当前 V6 实现路径：

```
ImageLayerSpec → ImageLayerComposer.evaluate(at:)
→ UnifiedCompositorInstruction.imageLayers
→ AVVideoCompositing (UnifiedCompositor.startRequest)
→ AVPlayer → AVPlayerLayer → 屏幕
```

测试发现：
- **seek 拖动**：图片动画（ImageMotion / Image3D）可以看到明显运动
- **点击播放**：图片动画几乎静止或表现异常
- 即使强制 `translationX = 100 * sin(localTime)`，seek 有效，play 仍不稳定
- UnifiedCompositor.startRequest 日志显示播放期间持续在被调用，且每次 compositionTime 都不同——说明 **compositor 在正确计算，但结果没有被展示**

### 1.2 已确认根因（Metadata Bugs）

**[image-realtime-playback-issue-analysis.md](image-realtime-playback-issue-analysis.md) 已定位三个 instruction metadata 错误：**

| Bug | 当前错误值 | 应为 | 影响 |
|---|---|---|---|
| `containsTweening` | `false`（默认值，从未对图片层设为 true）| `true`（只要 imageLayers 非空）| AVFoundation 播放路径可能复用上一帧 compositor 输出，不重新调用 startRequest |
| `enablePostProcessing` | `false`（仅转场/调色设为 true）| `true`（图片层非空时）| AVFoundation 可能跳过 post-processing compositor 调用路径 |
| `requiredSourceTrackIDs` | 始终包含 `foregroundTrackID` | 纯图片 instruction 应为 `[]` | instruction 声明依赖一个没有 source sample 的 track，AVFoundation 行为未定义 |

**这三个 bug 是可以修复的。** 修复后，当前 AVVideoCompositing 架构在 image-only segment 的 play/seek 一致性应该改善。

### 1.3 修复是否足够？

修复 metadata bugs 是**必要条件**，但**不充分**。即使修复后，以下结构性问题仍然存在：

1. **SentinelAsset hack 不可废除**：只要图片 segment 没有真正的 AVAssetTrack，就必须插入 1×1 像素的 sentinel 视频帧来"欺骗" AVFoundation 调用 compositor。这个 hack 的维护成本和脆弱性是固有的。

2. **AVFoundation 仍控制调用时机**：`containsTweening=true` 是 hint，不是保证。AVFoundation 有权力在任何时候缓存或跳过 compositor 调用（例如：内存压力时的降帧策略、设备温控时的性能降级）。

3. **播放/导出不一致的结构性根源**：播放路径由 `AVPlayer` + `AVPlayerItem` 驱动；导出路径由 `AVAssetExportSession` 或 `AVAssetWriter` 驱动。两者都经过 `AVVideoCompositing`，但调用语义、缓冲策略、帧投递频率可能不同。

4. **图层扩展困难**：未来贴纸（StickerLayer）、字幕（TextLayer 完整版）、特效（EffectLayer）都会遇到同样的问题——它们也没有 AVAssetTrack，也需要 sentinel hacks。

5. **调试困难**：AVFoundation 是黑盒。当 compositor 输出正确但屏幕不更新时，调试路径极长（已经花了若干 Fix 轮次证明这一点）。

---

## 二、AVPlayer + AVVideoCompositing 方案边界分析

### 2.1 AVVideoCompositing 的设计假设

Apple 在设计 `AVVideoCompositing` 协议时的假设：

```
假设 1: 所有媒体源 = AVAssetTrack（视频轨道）
假设 2: Compositor 的职责 = 把多个视频帧混合为一帧
假设 3: 调用时机 = 由 AVPlayer 的内部 render clock 决定
假设 4: containsTweening = 播放路径的优化 hint（不是强制语义）
假设 5: 合成结果 = 可缓存用于下一帧（若帧内容不变）
```

TimelineKit V6 的图片图层打破了全部 5 个假设：

```
实际 1: 图片没有 AVAssetTrack → 需要 sentinel hack
实际 2: 图片帧由 compositor 凭空生成，不是混合 → 无 sourceFrame 可用
实际 3: 图片帧每毫秒都不同（关键帧动画）→ 不能复用
实际 4: containsTweening=true 之后 AVFoundation 仍可能优化 → 已观察到 play 静止
实际 5: 图片动画帧绝对不能缓存 → 与 AVFoundation 假设冲突
```

### 2.2 问题不会因一次修复而消失

当前已经历的修复轮次：

| 轮次 | 修复内容 | 遗留 |
|---|---|---|
| Fix A | 每层独立 cover-fit 到 canvasRect | imageLayers 为空时仍有 bug |
| Fix B | safeScale + AnimationMacro 真 Ken Burns 模型 | play 静止仍存在 |
| Fix C | BlackOut 播放路径黑屏生效 | sentinel 路径不稳定 |
| Fix D | overlay 图片图层关键帧 + composition 时钟对齐 | 局部改善，根因未变 |
| Fix E | localTime 时间契约 | 部分时序问题改善 |
| Fix G | sentinel 帧过滤（isSentinelFrame）| sentinel 仍需存在 |
| **待做** | containsTweening / enablePostProcessing / requiredSourceTrackIDs | 这三个是当前症状的直接原因 |

**规律**：每轮修复改善一个表象，但下一个表象随即出现。这不是代码质量问题，而是架构层面的阻抗不匹配。

### 2.3 AVVideoCompositing 方案的合理应用场景

`AVVideoCompositing` 在以下场景是正确工具：

```
✅ 视频 + 视频转场（两段视频间的 crossfade / wipe）
✅ 视频调色（Color Grading：brightness / contrast / saturation / LUT）
✅ 视频 + 简单静态叠加（字幕烘焙、静态 watermark）
✅ 视频 overlay（画中画，两路都有 AVAssetTrack）
```

**不适合的场景**：

```
❌ 图片原生动画（无 AVAssetTrack 源）
❌ 复杂关键帧驱动的图层（需要精确的帧级时间控制）
❌ 实时生成的内容（粒子、程序化纹理）
❌ 需要完全确定性的预览/导出一致性
```

---

## 三、主流剪辑器 Layer Runtime 调研

### 3.1 剪映 / CapCut（字节跳动 Effect SDK）

**底层渲染模型**：完全自研 GPU Render Loop，不依赖 AVFoundation compositor。

```
时钟：CADisplayLink (iOS) / Choreographer (Android)
  ↓
主时钟 currentTime
  ↓
Effect SDK resolveLayers(at: currentTime)
  ↓ (并行)
VideoFrameProvider.decodedFrame(at: time) — VideoToolbox 解码，预解一帧
ImageTextureCache.texture(for: url)       — CIImage → Metal texture，LRU 缓存
TextRenderer.render(layer: textLayer)     — Core Text → Metal texture
  ↓
Metal Command Buffer：合成所有图层
  ↓
CAMetalLayer（预览）/ CVPixelBuffer（导出）
  ↓
AVAudioPlayer / AVAudioEngine（音频独立，时间戳同步）
```

**关键特征**：
- 图片、视频、文字、贴纸、特效 **统一为 Layer**，在同一 render pass 合成
- 视频是 **VideoLayer**（提供像素帧），不是整个播放器
- AVPlayer 完全不参与画面渲染，仅在部分场景用于音频（或完全用 AVAudioEngine）
- 草稿文件（`draft_content.json`）中图片和视频共享 `transform + keyframes` 数据结构

### 3.2 Final Cut Pro（Apple 内部）

**底层渲染模型**：自研 Metal Render DAG，`AVVideoCompositing` 仅用于与 AVFoundation 边界交换数据，内部合成完全走 Metal。

```
Master Clock（精确 CMTime）
  ↓
Timeline.resolveLayers(at:) → DAG 节点列表（按 z-order）
  ↓ (异步提前解码)
VideoNode.decodedTexture(at:)     — Metal texture pool
ImageNode.texture(url:)           — 常驻 Metal texture（不重解码）
TextNode.render(string:, style:)  — Core Text → Metal
EffectNode.apply(filter:)         — Metal compute shader
  ↓
Metal Command Encoder：逐节点绘制（z-order 排序后逐层 composited(over:)）
  ↓
ProMotion Display（120fps CAMetalLayer）
  ↓
Export：同一套 DAG，frameAt(time:) 驱动 AVAssetWriter 逐帧写入
```

**关键特征**：
- **预览和导出共用同一套 renderFrame(at:)** — "所见即所得"
- Ken Burns（Still Image motion）= ImageNode + KeyframeSet，实时在 Metal 里 transform
- 转场 = 专用 EffectNode，叠加于两个 clip node 之上，不冻结底层 keyframes
- `AVVideoCompositing` 在 FCP 中的作用：仅作为 ProRes/H.264 轨道读入的解码桥接，不作为合成引擎

### 3.3 LumaFusion（iPad/iPhone）

**底层渲染模型**：混合架构，AVVideoCompositing + CADisplayLink 双轨。

```
主轨视频段落：
  AVVideoCompositing (自定义 Metal compositor) → AVPlayer 播放
  
图片 / 贴纸 / 文字 / 特效：
  CADisplayLink → Metal renderer → CAMetalLayer overlay（叠加于 AVPlayerLayer 上方）
  
时间同步：
  CADisplayLink callback 读取 AVPlayer.currentTime → 对齐两套系统
```

**关键特征**：
- LumaFusion **没有**把图片图层交给 AVVideoCompositing 处理
- 图片层用独立的 Metal render loop，通过 player.currentTime 做时间同步
- 这是**混合架构的代价**：两套渲染系统的同步存在 1 帧以内的抖动风险

### 3.4 DaVinci Resolve（专业级，参考）

**底层渲染模型**：完全自研，Fusion 合成引擎 + OpenFX 插件接口。

```
Timeline Clock → Graph Processor → Node DAG (Fusion) → GPU composite → Viewer
Export: AVAssetWriter / FFmpeg → 同一 Node DAG 驱动
```

**关键特征**：对 iOS 移动端参考价值有限，但证明了：专业剪辑器=自研引擎，没有依赖平台 compositor 的。

### 3.5 核心调研结论

**针对用户原始问题的回答：**

| 问题 | 结论 |
|---|---|
| 图片动画是预生成视频还是实时图层动画？| **全行业统一答案：实时图层动画**。只有 TimelineKit V5 是预合成 MP4 的异类。 |
| 播放预览由 AVPlayer 驱动，还是自研 RenderLoop？| 剪映/CapCut/FCP：**自研 RenderLoop**。LumaFusion：混合（视频轨 AVPlayer，图片轨 DisplayLink）。 |
| 视频素材在剪辑器里是主播放源，还是只是 VideoLayer texture source？| **VideoLayer texture source**。视频帧只是合成器的一个输入，不是驱动者。 |
| 图片、文字、贴纸、特效是否统一抽象为 Layer？| **是**。全行业统一模型：每个轨道上的每段内容 = 一个 Layer，共享 transform + keyframes 数据结构。 |
| 预览和导出是否共用同一套 renderFrame(time)？| **是（专业工具的标配）**。"预览所见 = 导出所得"只有当两者走同一个 renderFrame 实现时才有保证。 |

---

## 四、DreamAI Timeline Runtime 目标架构

### 4.1 核心原则

```
Timeline owns rendering.
AVPlayer only handles audio + video decoding.
Layer owns visual state.
Renderer owns frame output.
```

### 4.2 模块全景

```
┌──────────────────────────────────────────────────────────┐
│                    TimelineRuntime                        │
│                                                          │
│  TimelineClock ──────────────────┐                       │
│  (CADisplayLink / CMClock)       │                       │
│                                  ▼                       │
│  LayerResolver ◄── EditorTimeline                        │
│  (at: CMTime)                    │                       │
│       │                          │                       │
│       ▼                          │                       │
│  [LayerRenderDescriptor]         │                       │
│  (z-ordered, time-filtered)      │                       │
│       │                          │                       │
│       ▼                          │                       │
│  FrameRenderer                   │                       │
│  ├── VideoFrameProvider ◄─────── AVPlayerItemVideoOutput │
│  ├── ImageTextureCache ◄──────── CIImage(contentsOf:)    │
│  ├── TextRenderer ◄────────────── Core Text              │
│  ├── StickerRenderer ◄──────────  (future)               │
│  └── EffectRenderer ◄───────────  (future)               │
│       │                          │                       │
│       ▼                          │                       │
│  CIImage composition chain       │                       │
│  (bg layers → video → fg layers) │                       │
│       │                          │                       │
│       ├──── PreviewOutput ────► MTKView / CALayer         │
│       └──── ExportOutput ─────► AVAssetWriter            │
│                                                          │
│  AudioSync                                               │
│  ├── AVAudioEngine (for BGM/SFX)                         │
│  └── AVPlayer (for video native audio, muted for video)  │
└──────────────────────────────────────────────────────────┘
```

### 4.3 关键角色职责

**TimelineClock**：
- 播放模式：`CADisplayLink` 以 vsync 为节拍，推进 `currentTime`
- 暂停/seek：直接设置 `currentTime`，下一次 render 调用时生效
- 导出模式：for 循环 `currentTime += 1/fps`，不依赖 DisplayLink

**LayerResolver**：
- 输入：`EditorTimeline` + `CMTime`
- 输出：`[LayerRenderDescriptor]`（按 zPosition 升序，过滤出时间范围内的所有 layer）
- 纯函数，无副作用，可并行调用

**FrameRenderer**：
- 对每个 `LayerRenderDescriptor` 调用对应的渲染器
- 按 z-order 用 `CIImage.composited(over:)` 叠加
- 最终 `CIContext.render(to: CVPixelBuffer)` 输出

**VideoFrameProvider**：
- P4 预览主线使用 `AVPlayerItemVideoOutput`，直接取得系统解码后的 `CVPixelBuffer`
- 导出路径后续由 `AVAssetReader` provider 承担，预览和导出共享 protocol 而非同一个底层实现
- 提供 `decodedPixelBuffer(for url: URL, at compositionTime: CMTime) -> CVPixelBuffer?`

**ImageTextureCache**：
- `CIImage` LRU 缓存，与当前 `ImageLayerComposer.imageCache` 完全一致
- 生命周期绑定到 `TimelineRuntime` 实例

**AudioSync**：
- 视频素材的原生音频：从 `AVAsset` 提取，用 `AVAudioEngine` 播放（或保持 muted AVPlayer 仅解码画面）
- BGM / 配音：`AVAudioEngine` 节点
- 时间同步：所有音频节点共享一个 `AVAudioEngine` 的 `AVAudioTime` 时钟，与 `TimelineClock.currentTime` 对齐

---

## 五、Layer 数据模型

### 5.1 通用 Layer 接口

```swift
protocol TimelineLayer: Sendable {
    var id: UUID { get }
    var timeRange: CMTimeRange { get }
    var zPosition: Int32 { get }
    var transform: LayerTransform { get }   // 基础 transform（无动画时的静止值）
    var keyframes: KeyframeSet? { get }     // 动画关键帧（nil = 静止）
    var blendMode: LayerBlendMode { get }
    var opacity: Float { get }
}

struct LayerTransform: Sendable {
    var position: NormalizedPoint = .init(x: 0.5, y: 0.5)
    var scale: Float = 1.0
    var rotation: Float = 0.0
    var anchor: CGPoint = .init(x: 0.5, y: 0.5)
}
```

### 5.2 VideoLayer

```swift
struct VideoLayer: TimelineLayer {
    var id: UUID
    var timeRange: CMTimeRange
    var zPosition: Int32
    var transform: LayerTransform
    var keyframes: KeyframeSet?
    var blendMode: LayerBlendMode = .normal
    var opacity: Float = 1.0

    // 视频素材来源
    var sourceURL: URL
    var trimRange: CMTimeRange      // clip 在素材内的 trim 区间
    var speed: Float = 1.0         // 播放速度

    // 调色
    var colorAdjustment: SegmentAdjustment = .identity
}
```

**VideoLayer 的职责**：
- 提供解码后的像素帧（via VideoFrameProvider）
- 参与时间轴合成（和其他 Layer 平等）
- **不**是整个播放系统；AVPlayer 不再驱动画面

### 5.3 ImageLayer

```swift
struct ImageLayer: TimelineLayer {
    var id: UUID
    var timeRange: CMTimeRange
    var zPosition: Int32
    var transform: LayerTransform
    var keyframes: KeyframeSet?     // Ken Burns / ImageMotion / Image3D 展开后的关键帧
    var blendMode: LayerBlendMode = .normal
    var opacity: Float = 1.0

    // 图片素材
    var sourceURL: URL
    var contentFit: ContentFit = .cover

    // 调色
    var colorAdjustment: SegmentAdjustment = .identity
}
```

**ImageLayer 渲染流**（renderFrame 中）：
```
ImageTextureCache.ciImage(for: sourceURL)
  → KeyframeEvaluator.evaluate(keyframes:, at: localTime)
  → fitTransform(mode: contentFit, safeMargin: motionSafetyMargin(keyframes))
  → ciImage.transformed(by: combined)
  → 如果 colorAdjustment 非 identity → applyAdjustments(...)
  → 输出 CIImage，extent ≈ canvasRect
```

### 5.4 TextLayer

```swift
struct TextLayer: TimelineLayer {
    var id: UUID
    var timeRange: CMTimeRange
    var zPosition: Int32
    var transform: LayerTransform
    var keyframes: KeyframeSet?
    var blendMode: LayerBlendMode = .normal
    var opacity: Float = 1.0

    // 文字内容
    var text: String
    var style: TextStyle             // font / size / color / alignment / shadow 等

    // 动画
    var entranceAnimation: TextAnimation?   // fade-in / slide / typewriter 等
    var exitAnimation: TextAnimation?
}
```

**注意**：`TextLayer` 替代当前的 `SubtitleRenderFrame` 模型（预烘焙 CIImage）。在 Timeline Runtime 中，字幕/文字都是实时渲染的 Layer，不需要预烘焙。

### 5.5 AudioLayer

```swift
struct AudioLayer {
    var id: UUID
    var timeRange: CMTimeRange

    var sourceURL: URL
    var trimRange: CMTimeRange
    var volume: Float = 1.0
    var speed: Float = 1.0
    var fadeInDuration: Double = 0
    var fadeOutDuration: Double = 0
}
```

**AudioLayer 不参与画面渲染**，由 `AudioSync` 独立处理。

### 5.6 未来 Layer 类型（V6.1+）

```swift
struct StickerLayer: TimelineLayer { ... }  // 贴纸/表情
struct EffectLayer: TimelineLayer { ... }   // 滤镜/遮罩/粒子/转场
```

---

## 六、renderFrame(at:) 设计

### 6.1 函数签名

```swift
actor TimelineRenderer {

    /// 渲染时间轴在 `time` 时刻的完整画面到 `output` 像素缓冲区。
    /// - 可在后台线程调用（actor 保证串行）
    /// - 播放模式：由 CADisplayLink callback 调用
    /// - 导出模式：for 循环顺序调用
    func renderFrame(
        at time: CMTime,
        into output: CVPixelBuffer
    ) async throws
}
```

### 6.2 渲染流程（伪代码）

```swift
func renderFrame(at time: CMTime, into output: CVPixelBuffer) async throws {
    let canvasRect = CGRect(origin: .zero, size: renderSize)

    // 1. 解析当前帧涉及的所有图层（按 z-order 升序）
    let layers = layerResolver.resolve(at: time)   // O(n)，纯函数

    // 2. 渲染每一层为 CIImage
    var renderedLayers: [(zPosition: Int32, image: CIImage)] = []

    for layer in layers {
        let localTime = (time - layer.timeRange.start).seconds
        let layerImage: CIImage?

        switch layer {
        case let vl as VideoLayer:
            // 从 VideoFrameProvider 取解码帧
            if let pixelBuf = await videoFrameProvider.frame(for: vl, at: time) {
                var img = CIImage(cvPixelBuffer: pixelBuf)
                img = coverFit(img, to: canvasRect)
                let (motion, opacity) = KeyframeEvaluator.evaluate(vl.keyframes, at: localTime)
                img = img.transformed(by: motion)
                img = applyOpacity(img, opacity: opacity * vl.opacity)
                if !vl.colorAdjustment.isIdentity { img = applyColor(vl.colorAdjustment, to: img) }
                layerImage = img.cropped(to: canvasRect)
            } else {
                layerImage = nil
            }

        case let il as ImageLayer:
            // 从 ImageTextureCache 取 CIImage
            if let baseCI = imageCache.ciImage(for: il.sourceURL) {
                let safeMargin = motionSafetyMargin(for: il.keyframes)
                var img = fitTransform(il.contentFit, baseCI, canvasRect, safeMargin)
                let (motion, opacity) = KeyframeEvaluator.evaluate(il.keyframes, at: localTime, canvasSize: renderSize)
                img = img.transformed(by: motion)
                img = applyOpacity(img, opacity: opacity * il.opacity)
                if !il.colorAdjustment.isIdentity { img = applyColor(il.colorAdjustment, to: img) }
                layerImage = img.cropped(to: canvasRect)
            } else {
                layerImage = nil
            }

        case let tl as TextLayer:
            layerImage = textRenderer.render(tl, at: localTime, canvasRect: canvasRect)

        default:
            layerImage = nil
        }

        if let img = layerImage {
            renderedLayers.append((layer.zPosition, img))
        }
    }

    // 3. 按 z-order 合成（bg → ... → fg）
    guard let bottomLayer = renderedLayers.first else {
        // 全黑帧
        let black = CIImage(color: .black).cropped(to: canvasRect)
        ciContext.render(black, to: output, bounds: canvasRect, colorSpace: nil)
        return
    }

    var composed = bottomLayer.image
    for i in 1 ..< renderedLayers.count {
        composed = renderedLayers[i].image.composited(over: composed)
    }

    // 4. 输出
    ciContext.render(composed, to: output, bounds: canvasRect, colorSpace: nil)
}
```

### 6.3 转场在 Timeline Runtime 中的处理

转场不是一个独立的 "instruction"，而是两个 clip 的 **overlap 时间段**，在 LayerResolver 中被解析为两个活跃 Layer + 一个 TransitionDescriptor：

```swift
struct TransitionDescriptor {
    var clampedRange: CMTimeRange     // 转场的时间区间
    var exitLayer: AnyTimelineLayer   // 离开的片段（前一个）
    var enterLayer: AnyTimelineLayer  // 进入的片段（后一个）
    var type: TransitionType          // crossfade / wipe / etc.
    var easing: EasingCurve
}
```

在 renderFrame 中，转场被处理为一个特殊的 EffectLayer，它读取两个 layer 的 CIImage，叠加混合后输出。两个 layer 的关键帧求值**完全正常进行**，不受转场影响。

---

## 七、预览播放链路

### 7.1 完整链路

```
用户点击"播放"
  ↓
TimelineClock.play()
  → CADisplayLink.add(to: .main, forMode: .common)
  → CADisplayLink.preferredFrameRateRange = .init(minimum: 30, maximum: 60, preferred: 60)
  ↓
每个 vsync 帧（~16.67ms）
  → CADisplayLink callback
  → currentTime += delta (由 CADisplayLink.timestamp - lastTimestamp 决定)
  → CVPixelBufferPool.allocate() → outputBuffer
  → TimelineRenderer.renderFrame(at: currentTime, into: outputBuffer)
  ↓
渲染完成
  → previewView.enqueue(outputBuffer)  // MTKView.draw 或 AVSampleBufferDisplayLayer
  → audioSync.seek(to: currentTime)    // 对齐音频播放位置（首次播放或 seek 后）
```

### 7.2 预览输出层选型

| 选项 | 延迟 | 复杂度 | 推荐场景 |
|---|---|---|---|
| **MTKView**（Metal texture 路径）| 最低（GPU→display 直通）| 高（需写 Metal 着色器）| 高性能预览 |
| **AVSampleBufferDisplayLayer**（CVPixelBuffer 队列）| 低（系统自动 present）| 中（enqueue API）| **V6 首选** |
| `CALayer.contents = CIImage` | 高（CPU 路径）| 低 | 不推荐 |

**V6 首选 `AVSampleBufferDisplayLayer`**：
- 接受 `CVPixelBuffer` 直接入队，不需要 Metal 着色器
- 系统处理 vsync 对齐和 display 时机
- 与 AVFoundation 音频系统天然兼容（同为 AVFoundation 家族）
- API 简单，与当前 `CIContext.render(to: CVPixelBuffer)` 输出格式完全匹配

```swift
class TimelinePreviewView: UIView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    func enqueue(_ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) {
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        guard let sampleBuffer = pixelBufferToSampleBuffer(pixelBuffer, timing: &timingInfo) else { return }
        displayLayer.enqueue(sampleBuffer)
    }
}
```

### 7.3 Seek 处理

```
用户拖动进度条（seek to T）
  ↓
TimelineClock.seek(to: T)
  → 暂停 CADisplayLink（如果正在播放）
  → currentTime = T
  → VideoFrameProvider.flush()（清空视频帧预解码缓存）
  ↓
单帧渲染
  → TimelineRenderer.renderFrame(at: T, into: buffer)
  → previewView.enqueue(buffer)
  ↓（如果之前是播放状态）
  → TimelineClock.play()（恢复播放）
```

**Seek 的一致性保证**：seek 和 play 路径完全相同——都调用 `TimelineRenderer.renderFrame(at:)`。图片动画在 seek 和 play 下的行为**结构性保证一致**（消灭当前 seek/play 不一致问题的根源）。

---

## 八、导出链路

### 8.1 与预览共用渲染核心

```swift
class VideoExporter {
    func export(
        timeline: EditorTimeline,
        config: ExportConfig,
        to outputURL: URL
    ) async throws {
        let renderer = TimelineRenderer(timeline: timeline, renderSize: config.resolution.size)
        let writer = AVAssetWriter(url: outputURL, fileType: .mp4)
        // ... setup writer inputs ...

        let frameCount = Int(timeline.duration * config.fps.value)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(config.fps.value))

        for i in 0 ..< frameCount {
            let time = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(config.fps.value))

            // 同一个 renderFrame，导出路径使用
            try await renderer.renderFrame(at: time, into: pixelBuffer)

            // 写入 AVAssetWriter
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }
        // ... finalize ...
    }
}
```

### 8.2 预览和导出的一致性保证

| 组件 | 预览 | 导出 | 一致性 |
|---|---|---|---|
| `TimelineRenderer.renderFrame(at:)` | ✅ | ✅ | **完全相同的代码路径** |
| `LayerResolver.resolve(at:)` | ✅ | ✅ | 完全相同 |
| `KeyframeEvaluator.evaluate(at:)` | ✅ | ✅ | 完全相同 |
| `ImageTextureCache` | ✅（LRU 复用）| ✅（LRU 复用）| 相同缓存 |
| `VideoFrameProvider` | ✅（实时 decode）| ✅（按序 decode）| 同一实现，不同调用频率 |
| `CIContext` | ✅ | ✅ | 共享同一个 Metal-backed context |
| 像素输出 | `AVSampleBufferDisplayLayer` | `AVAssetWriter adaptor` | 不同 sink，相同 pixel content |

**"预览所见 = 导出所得"** 在此架构中是代码层面的结构性保证，不再依赖两套实现的对齐。

---

## 九、视频素材解码策略

### 9.1 VideoFrameProvider 设计

> 2026-05-19 P4 更新：P3 mixed timeline 已验证后，实时预览主线从本节早期设想的 `AVAssetReader` 调整为 `AVPlayerItemVideoOutput`。原因是实时预览需要复用系统播放器的硬解调度、缓存和时钟同步；`AVAssetReader` 更适合 P5 导出路径的顺序离线渲染。完整评估见 [video-frame-provider-performance-plan.md](video-frame-provider-performance-plan.md)。

P4 后的 provider 分层：

| 场景 | Provider | 定位 |
|---|---|---|
| 实时预览 | `AVPlayerItemVideoOutputProvider` | P4 主线，输出 `CVPixelBuffer` |
| 导出 | `AVAssetReaderVideoFrameProvider` | P5 引入，顺序离线读取 |
| thumbnail / cover / debug fallback | `AVAssetImageGenerator` | 保留，不作为实时 runtime 默认路径 |
| 高级自定义解码 | `VideoToolboxVideoFrameProvider` | V6.1+ 另行评估 |

P4 的 preview provider 目标接口：

```swift
protocol VideoFrameProviderProtocol: AnyObject {
    func setCanvasSize(_ size: CGSize)
    func prepare(for item: AVPlayerItem, timeline: EditorTimeline)
    func frame(for spec: VideoLayerSpec, at compositionTime: CMTime) -> CVPixelBuffer?
    func seek(to time: CMTime)
    func flush()
    func invalidate()
}
```

`VideoLayerComposer` 不再从 provider 拿 `CGImage`，而是直接走：

```swift
let pixelBuffer = provider.frame(for: spec, at: compositionTime)
let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
```

下面的 `AVAssetReader` 伪代码保留为 P5 导出 provider 的设计参考，不再代表 P4 实时预览主线。

```swift
actor VideoFrameProvider {

    // 每个视频 URL 对应一个 reader 实例
    private var readers: [URL: VideoReader] = [:]

    /// 获取视频在指定时刻的解码帧。
    /// - 播放模式：`currentTime` 单调递增，reader 顺序读帧，预缓冲 1-2 帧
    /// - Seek 模式：`flush()` 后重设 reader 到新时间点
    func frame(for layer: VideoLayer, at compositionTime: CMTime) async -> CVPixelBuffer? {
        let localTime = compositionTime - layer.timeRange.start + layer.trimRange.start
        let reader = readers[layer.sourceURL] ?? makeReader(for: layer)
        return await reader.frame(at: localTime.seconds / Double(layer.speed))
    }

    func flush() {
        readers.values.forEach { $0.reset() }
    }
}

class VideoReader {
    private var assetReader: AVAssetReader?
    private var outputTrack: AVAssetReaderTrackOutput?
    private var frameCache: [(time: Double, buffer: CVPixelBuffer)] = []

    func frame(at time: Double) async -> CVPixelBuffer? {
        // 1. 检查 frameCache 是否已有这一帧
        if let cached = frameCache.first(where: { abs($0.time - time) < 0.001 }) {
            return cached.buffer
        }
        // 2. 从 AVAssetReader 读下一帧
        return readNextFrame()
    }
}
```

### 9.2 视频素材在 Timeline Runtime 中的角色

**关键认知转变**：

```
V5/V6-before：AVPlayer 是驱动者，compositor 是处理器
  AVPlayer.play() → 内部 clock → compositor.startRequest → 画面

V6-after（Timeline Runtime）：TimelineClock 是驱动者，VideoLayer 是数据提供者
  TimelineClock.tick() → renderFrame(at: T) → VideoFrameProvider.frame(for: videoLayer, at: T) → 像素
```

AVPlayer 在 Timeline Runtime 中的残留职责：
- **视频原生音频**：如果视频素材有音轨，通过 `AVAudioEngine` + `AVAudioPlayerNode` 播放（或保持 muted AVPlayer 仅用于提取音频 PCM）
- **不再负责视频帧的 display**：视频帧由 `VideoFrameProvider` 解码，进入 `renderFrame` 参与合成

---

## 十、图片动画与 Image3D 策略

### 10.1 当前 V6 的正确部分（全部保留）

以下组件在 Timeline Runtime 中**完全复用**，无需改动：

| 组件 | 文件 | 复用说明 |
|---|---|---|
| `KeyframeEvaluator` | `Animation/KeyframeEvaluator.swift` | 纯函数，时间无关，直接复用 |
| `EasingCurve` + LUT | `Animation/EasingCurve.swift` | 纯函数，直接复用 |
| `AnimationMacro` | `Animation/AnimationMacro.swift` | 展开预设为 KeyframeSet，直接复用 |
| `ImageLayerComposer.fitTransform` | `Rendering/ImageLayerComposer.swift` | 图片 fit 计算，直接复用 |
| `ImageLayerComposer.motionSafetyMargin` | `Rendering/ImageLayerComposer.swift` | safeMargin 计算，直接复用 |
| `ImageLayerComposer.imageCache` | `Rendering/ImageLayerComposer.swift` | LRU CIImage 缓存，直接复用 |
| `KeyframeSet` + `Keyframe<T>` | `Models/EditorSegment.swift` | 数据模型，直接复用 |
| `ImageLayerSpec` | `Rendering/ImageLayerComposer.swift` | 可升级为 `ImageLayer` 数据模型 |

### 10.2 当前 V6 在 Timeline Runtime 下不需要的部分

| 组件 | 文件 | 替代方案 |
|---|---|---|
| `SentinelAsset` | `Rendering/SentinelAsset.swift` | 完全废除（无需 AVAssetTrack 填充）|
| `UnifiedCompositorInstruction` | `Rendering/UnifiedCompositor.swift` | 合并到 `LayerRenderDescriptor` |
| `UnifiedCompositor.startRequest` | `Rendering/UnifiedCompositor.swift` | 被 `TimelineRenderer.renderFrame` 替代 |
| `AVVideoCompositing` 协议适配 | `Rendering/UnifiedCompositor.swift` | 不再需要（Timeline Runtime 不走 AVCompositing）|
| `CompositionBuilder`（核心路径）| `Rendering/CompositionBuilder.swift` | 被 `LayerResolver` 替代；AVMutableComposition 仍用于音频 |

### 10.3 Image3D（2.5D Parallax）的处理

Image3D 在 Timeline Runtime 中的处理方式与当前 V6 spec 完全一致（3 层 2D 图层叠加）：

```
SDepthModel + SCamera
  ↓ AnimationMacro.expandDepthEffect(...)
  → 3 个 ImageLayer（前景/中景/背景），各有独立 KeyframeSet
  ↓ LayerResolver.resolve(at:) 返回 3 个 LayerRenderDescriptor
  ↓ renderFrame 中 3 次 ImageLayerComposer.evaluate
  → 3 个 CIImage，按 z-order composited(over:)
```

差异：不再需要把 3 层 ImageLayerSpec 打包进 UnifiedCompositorInstruction.imageLayers，而是直接在 EditorTimeline 中展开为 3 个独立 ImageLayer。

---

## 十一、从现有 V6 迁移到 Timeline Runtime 的阶段计划

### 阶段 0（当前）：修复 AVVideoCompositing Metadata Bugs

**目标**：让现有 V6 image 播放可用，消除 seek/play 不一致的直接症状。

```swift
// UnifiedCompositorInstruction.init 中添加：
let hasImageLayers = !imageLayers.isEmpty
self.enablePostProcessing = isTransition || hasColor || hasImageLayers
self.containsTweening     = hasTransitionTween || hasImageLayers

// 纯图片 instruction 清空 requiredSourceTrackIDs：
if hasImageLayers && backgroundTrackID == nil && fgBuf == nil {
    self.requiredSourceTrackIDs = []
} else {
    var ids: [NSValue] = [NSNumber(value: foregroundTrackID)]
    if let bgID = backgroundTrackID { ids.append(NSNumber(value: bgID)) }
    self.requiredSourceTrackIDs = ids
}
```

**工期**：1 天，低风险
**交付**：图片动画 play 稳定

---

### 阶段 1：设计 Timeline Runtime 最小 MVP

**目标**：实现能跑通单轨 ImageLayer + VideoLayer 的 TimelineRenderer，不连接 UI。

```
新增：
  Sources/TimelineKit/Runtime/TimelineRenderer.swift
  Sources/TimelineKit/Runtime/TimelineClock.swift
  Sources/TimelineKit/Runtime/LayerResolver.swift
  Sources/TimelineKit/Runtime/VideoFrameProvider.swift

复用（不改动）：
  Animation/KeyframeEvaluator.swift
  Animation/AnimationMacro.swift
  Animation/EasingCurve.swift
  Rendering/ImageLayerComposer.swift（fitTransform + imageCache + motionSafetyMargin）
```

**MVP 验证标准**：
- `renderFrame(at: T, into: buffer)` 对纯 ImageLayer 时间轴能正确输出
- ImageMotion / Image3D 在任意 T 的输出与 `KeyframeEvaluator` 预期一致
- 不依赖 AVVideoCompositing，不依赖 SentinelAsset

**工期**：3-5 天

---

### 阶段 2：实现 CADisplayLink 预览播放

**目标**：`TimelinePreviewView`（基于 `AVSampleBufferDisplayLayer`）+ `TimelineClock`（CADisplayLink）实现播放预览。

```
新增：
  Views/TimelinePreviewView.swift   — AVSampleBufferDisplayLayer wrapper
  Runtime/AudioSync.swift           — AVAudioEngine 音频同步

修改：
  Views/FullScreenPreviewController — 接入 TimelineRuntime 替代 AVPlayer
```

**验证标准**：
- 图片动画 play 路径与 seek 路径完全一致（结构保证，不依赖 flag）
- 单图片层预览 ≥ 58fps（iPhone 13）
- Seek 后恢复播放，无跳帧

**工期**：5-7 天

---

### 阶段 3：统一导出链路

**目标**：`VideoExporter` 调用 `TimelineRenderer.renderFrame(at:)`，彻底废除 `AVVideoCompositing` 导出路径。

```
修改：
  Rendering/VideoExporter.swift — 从 AVAssetExportSession 迁移到 AVAssetWriter + TimelineRenderer
  （复用 v5/render-pipeline-unification-spec.md 的 AVAssetWriter 架构）
```

**验证标准**：
- 1080P / 30fps / 60s 导出与预览画面一致（肉眼无差异）
- 导出帧与 renderFrame(at:) 逐帧对比误差为 0（同一帧 = 同一个函数输出）

**工期**：3-5 天

---

### 阶段 4：废除 AVVideoCompositing 路径

**目标**：清理 `SentinelAsset`、`UnifiedCompositorInstruction`、`UnifiedCompositor` 的 AVVideoCompositing 依赖。

```
废除：
  Rendering/SentinelAsset.swift         — 完全删除（Timeline Runtime 不需要）
  Rendering/UnifiedCompositor.swift     — 降级为仅用于音频合成辅助（或完全废除）
  Rendering/CompositionBuilder.swift    — 仅保留 AudioMix 构建部分
```

**保留**：
- `StaticImageRenderer.swift`（历史参考，不调用）
- `AVMutableComposition` 音频轨逻辑（音频仍走 AVFoundation）

**工期**：2-3 天

---

### 阶段 5（V6.1+）：扩展高级能力

按需单独立项：

- **StickerLayer**：贴纸/表情（SVG 或 PNG 序列 → CIImage），直接套入 renderFrame
- **EffectLayer**：CIFilter 链滤镜 / Metal compute shader 特效
- **Mask**：蒙版图层（CIBlendWithMask）
- **Transition**：更多转场类型（wipe / push / flash），替换当前 CIDissolveTransition
- **Image3D 完整 inpainting**：真实深度图分层修补（背景填充）

---

## 十二、最终判断与决策建议

### 12.1 两条路的对比

| 维度 | 继续 AVVideoCompositing | 迁移到 Timeline Runtime |
|---|---|---|
| **短期工作量** | 小（3 个 bug fix）| 大（新增 Runtime 模块）|
| **play/seek 一致性** | 改善（但结构性风险仍在）| **结构性保证** |
| **sentinel hack** | 仍然需要 | 完全废除 |
| **预览/导出一致性** | 依赖两套实现对齐 | **代码级保证** |
| **可扩展性**（贴纸/特效/遮罩）| 每个新 Layer 类型都需要 hack | 添加一个新 renderer 即可 |
| **调试难度** | 高（AVFoundation 黑盒）| 低（全栈自控）|
| **未来 AVFoundation API 变化风险** | 高（依赖内部调度行为）| 低（只用解码 API，稳定）|
| **与竞品架构的对齐** | 背离主流（仅 LumaFusion 局部使用）| 对齐主流（剪映/CapCut/FCP 模型）|

### 12.2 建议路径

**推荐：阶段 0 立即执行 + 阶段 1-4 作为 V6 P1/P2 分批执行**

```
现在（本周）：执行阶段 0
  → 修复 3 个 instruction metadata bugs
  → V6 图片动画播放可用，P0 可发布

V6 P1（后续 2-3 周）：执行阶段 1-2
  → TimelineRenderer MVP + CADisplayLink 预览
  → 并行验证 Timeline Runtime 路径
  → 可在 Feature Flag 下双轨运行（Timeline Runtime / AVVideoCompositing 切换）

V6 P2：执行阶段 3-4
  → 统一导出 + 废除 AVVideoCompositing 路径
  → 完全迁移到 Timeline Runtime
```

**不建议的路径**：

```
❌ 只做阶段 0，不做后续迁移
  → 每个新增的图层类型（贴纸/特效/遮罩）都会重复经历当前的 seek/play 不一致问题

❌ 一次性推翻全部 V6 代码，从零开始写 Timeline Runtime
  → 工程风险极高；当前 V6 中 KeyframeEvaluator / AnimationMacro / ImageLayerComposer 的核心算法全部可以复用
```

### 12.3 最终一句话结论

> AVPlayer + AVVideoCompositing 是正确的视频编解码基础设施，但是错误的时间轴渲染引擎。  
> Timeline Runtime 不是重写，而是把控制权从 AVFoundation 内部调度器还给 TimelineClock，让图片动画和视频帧在同一个确定性的 `renderFrame(at:)` 中被平等对待。

---

## 附录 A：当前 V6 代码复用映射

| 当前文件 | Timeline Runtime 中的命运 |
|---|---|
| `Animation/KeyframeEvaluator.swift` | ✅ 完全复用 |
| `Animation/EasingCurve.swift` | ✅ 完全复用 |
| `Animation/AnimationMacro.swift` | ✅ 完全复用 |
| `Rendering/ImageLayerComposer.swift`（算法部分）| ✅ 复用 fitTransform / motionSafetyMargin / imageCache |
| `Rendering/ImageLayerComposer.swift`（evaluate 函数）| ✅ 整体移入 renderFrame 的 ImageLayer 分支 |
| `Rendering/UnifiedCompositor.swift`（颜色调整）| ✅ applyAdjustments 函数复用 |
| `Rendering/UnifiedCompositor.swift`（subtitleOpacity）| ✅ 字幕淡入淡出逻辑复用 |
| `Rendering/CompositionBuilder.swift`（音频轨）| ✅ 音频 AVMutableComposition 构建复用 |
| `Rendering/SentinelAsset.swift` | ❌ 废除 |
| `Rendering/UnifiedCompositor.swift`（AVVideoCompositing 协议）| ❌ 废除（替换为 renderFrame）|
| `Rendering/CompositionBuilder.swift`（视频合成路径）| ❌ 废除（替换为 LayerResolver）|

---

## 附录 B：与 V6 既有 spec 的关系

| 既有 spec | Timeline Runtime 下的处置 |
|---|---|
| `image-layer-rendering-spec.md`（P0-A）| 核心算法全部保留；`UnifiedCompositorInstruction.imageLayers` 改为 `ImageLayer` 数据模型 |
| `keyframe-animation-spec.md`（P0-B）| 完全保留，KeyframeEvaluator 是 renderFrame 的核心组件 |
| `ai-timeline-mapping-spec.md`（P0-C）| 完全保留，SImageAnimation → KeyframeSet 映射路径不变 |
| `layer-rendering-rules-spec.md`（P0-D）| 规则全部保留，实现从 UnifiedCompositor.startRequest 迁移到 renderFrame |
| `transition-compat-spec.md`（P1）| 转场模型改为 TransitionDescriptor + 双 Layer 在 overlap 期共同渲染 |
| `v5/render-pipeline-unification-spec.md`（P2）| AVAssetWriter 架构保留，作为 ExportOutput sink |
| `v5/fullscreen-preview-spec.md`（P2）| 全屏预览由 TimelinePreviewView + TimelineClock 驱动 |
| `competitive-benchmarks-v6.md` | 结论全部保留；Timeline Runtime 是与竞品架构对齐的必要路径 |
