# 转场系统规范（V7）

> 版本：v7.0
> 状态：规范定稿，待实现
> 优先级：P0（V7 第一批，阻塞所有后续 spec）
> 依赖：
> - v2 [transition-spec.md](../v2/transition-spec.md)：时长约束 / overlap 模型 / 数据结构基础
> - v6 [transition-compat-spec.md](../v6/transition-compat-spec.md)：关键帧 overlap 期间行为
> - v6 [image-layer-rendering-spec.md](../v6/image-layer-rendering-spec.md)：ImageLayerComposer
> - [LayerResolver.swift](../../Sources/TimelineKit/Runtime/LayerResolver.swift)：当前 resolve 逻辑
> - [TimelineRenderer.swift](../../Sources/TimelineKit/Runtime/TimelineRenderer.swift)：当前 blend 逻辑

---

## 一、覆盖范围与实现顺序

本 spec 覆盖 V7 M1-M3 的三件，**必须严格按此顺序实现**：

| 里程碑 | 内容 | 交付门槛 |
|---|---|---|
| **M1 先做** | 黑屏根因修复：LayerResolver 扩展，四种内容组合均能正确构造 TransitionInfo；**只用 crossFade** | 0 黑帧，overlay/text 不丢失，crossFade 稳定 |
| **M2 再做** | TransitionComposer 唯一出口：抽出 `TransitionComposer.render`，TimelineRenderer 内部无任何转场逻辑 | TimelineRenderer 里找不到任何 `CIDissolveTransition` / preset 名称 |
| **M3 最后做** | TransitionPresetRegistry + 首批 4 个稳定预设：crossFade / fadeThroughBlack / slideLeft / pushLeft | 每个预设 × 4 种内容组合通过验收；blurFade / zoomIn / slideRight / pushRight 进 M6 |

**在 M1 完成（四种组合 0 黑帧）之前，不开始 M2。在 M2 完成（单出口确立）之前，不开始 M3。**

---

## 二、黑屏根因修复：LayerResolver 扩展

### 2.1 当前问题代码

`LayerResolver.swift:282-293`（V6 现状）：

```swift
if let fgSpec = imageLayerMap[seg.id],
   let bgSpec = imageLayerMap[nextSeg.id] {
    resolvedTransition = TransitionInfo(
        outgoing: fgSpec,
        incoming: bgSpec,
        rawProgress: rawProgress,
        easing: trans.easing
    )
}
// 以下四种情况全部静默跳过 → 黑屏：
// video→image: imageLayerMap[seg.id] == nil（seg 是视频）
// image→video: imageLayerMap[nextSeg.id] == nil
// video→video: 两者都 nil
```

### 2.2 V7 修复后的 TransitionInfo

**`Sources/TimelineKit/Runtime/LayerResolver.swift`** 中的 `TransitionInfo` 扩展（**不是新增文件，是修改现有 `struct TransitionInfo`**）：

```swift
public struct TransitionInfo: Sendable {
    /// Outgoing (fading-out) image layer. nil if outgoing segment is video.
    public let outgoing: ImageLayerSpec?

    /// Incoming (fading-in) image layer. nil if incoming segment is image.  // V7 改 optional
    public let incoming: ImageLayerSpec?

    /// Outgoing video layer. nil if outgoing segment is image.  // V7 新增
    public let outgoingVideo: VideoLayerSpec?

    /// Incoming video layer. nil if incoming segment is image.  // V7 新增
    public let incomingVideo: VideoLayerSpec?

    /// Linear progress 0→1.
    public let rawProgress: Float
    public let easing: EditorTransition.Easing

    /// Preset identifier. Resolved from EditorTransition.presetID ?? type→preset mapping.
    public let presetID: String  // V7 新增；默认 "crossFade"
}
```

### 2.3 V7 修复后的 LayerResolver resolve 逻辑

替换 `LayerResolver.swift:282-293`（精确替换此 if 块）：

```swift
// V7：支持四种内容类型组合的转场
if i + 1 < mainSegs.count {
    let nextSeg = mainSegs[i + 1]
    let transStart = insertionTimes[i + 1]
    let transEnd   = transStart + trans.duration

    if compositionTime >= transStart && compositionTime < transEnd {
        let elapsed     = compositionTime - transStart
        let rawProgress = Float(elapsed / trans.duration).clamped(0...1)

        // Resolve presetID：优先用 EditorTransition.presetID，fallback 到 type 映射
        let presetID = trans.presetID ?? TransitionPresetRegistry.presetID(for: trans.type)

        resolvedTransition = TransitionInfo(
            outgoing:      imageLayerMap[seg.id],       // nil if video
            incoming:      imageLayerMap[nextSeg.id],   // nil if video
            outgoingVideo: videoLayerMap[seg.id],       // nil if image
            incomingVideo: videoLayerMap[nextSeg.id],   // nil if image
            rawProgress:   rawProgress,
            easing:        trans.easing,
            presetID:      presetID
        )
        // 至少有一侧 spec 存在才构造 TransitionInfo（防止两侧 segment 均未 resolve）
        // outgoing + incoming + outgoingVideo + incomingVideo 全为 nil 的情况：
        // segment 素材 URL 不存在（materialID 查不到）→ 保持 resolvedTransition = nil，
        // TimelineRenderer 的末態停驻逻辑接管，比黑屏更好
        if resolvedTransition?.hasValidContent == false {
            resolvedTransition = nil
        }
    }
    continue  // 无论是否构造了 resolvedTransition，都 skip outgoing segment 的 body layer
}
```

**`TransitionInfo` 辅助计算属性**：

```swift
extension TransitionInfo {
    /// 至少有一侧有有效内容（image 或 video）
    var hasValidContent: Bool {
        outgoing != nil || incoming != nil || outgoingVideo != nil || incomingVideo != nil
    }
    /// 出帧侧有效
    var hasOutgoing: Bool { outgoing != nil || outgoingVideo != nil }
    /// 入帧侧有效
    var hasIncoming: Bool { incoming != nil || incomingVideo != nil }
}
```

---

## 三、Overlay / Text 在转场期间的处理规则

### 3.1 核心原则

**转场效果只作用于主轨 main visual。Overlay / Text / Subtitle 层不参与转场，按自身 timeRange 独立渲染，叠加在转场结果之上。**

这是防止「文字随主画面闪、丢失或重复出现」的唯一可靠方式。

### 3.2 渲染合成顺序

`TimelineRenderer.renderFrame` 的合成顺序（M1 修复后维持此顺序）：

```
Step 1: 黑色背景底图 (composite base)
Step 2: 所有 z < 0 的 overlay 层（按 zIndex 从低到高）
Step 3: TransitionComposer.render → 主轨转场帧（仅含 main visual）
Step 4: 所有 text / subtitle 层（按 zIndex 从低到高，叠在转场之上）
```

```
转场期间画布栈（示意）：

[ text/subtitle (z = 10) ]   ← 不受转场影响，按 timeRange 正常渲染
[ overlay (z = -1)       ]   ← 不受转场影响，按 timeRange 正常渲染
[ TransitionComposer     ]   ← 仅混合 outgoing main + incoming main
[ 黑色背景               ]
```

### 3.3 LayerResolver 的职责划分

`LayerResolver.resolve` 返回的 `ResolvedFrame` 在 transition zone 内应当：

- `frame.transition`：非 nil（包含 outgoing/incoming 的 image/video spec + presetID）
- `frame.layers`：**只包含 overlay / text / subtitle 层**，不含主轨 main segment 的 body layer

主轨 main segment 的 body layer 在 transition zone 内被 `continue` 跳过（现有逻辑）——这是正确的，不需要改。Overlay / text 层的添加逻辑在主轨循环外（`LayerResolver.swift:315-335`），同样正确，不需要改。

**M1 验收时必须覆盖的用例**：overlay segment 或 text segment 的 timeRange 与 transition zone 重叠时，该层在 transition zone 内是否正常出现在 `frame.layers` 中。

### 3.4 TransitionComposer 的职责边界

`TransitionComposer.render` 的职责是**混合两个主轨帧**（outgoing + incoming），输出一个合成 `CIImage`。

禁止在 `TransitionComposer` 内部：
- 对 overlay / text / subtitle 层做任何处理
- 对 overlay / text 层的 opacity / position / blur 做任何修改
- 将 overlay 帧纳入转场的 dissolve / slide / push 计算

`TimelineRenderer` 在 Step 3 得到 `TransitionComposer` 输出后，Step 4 再叠加 text 层——这个分层架构保证文字始终清晰、不闪。

---

## 四、TransitionPresetRegistry

### 3.1 接口设计

**新增文件：`Sources/TimelineKit/Rendering/TransitionPresetRegistry.swift`**

```swift
/// Catalog of all available transition presets.
/// Presets are value types — registered once at app launch, immutable at runtime.
public enum TransitionPresetRegistry {

    // MARK: - Registration

    /// Register a custom preset. Must be called before first use (typically at app launch).
    public static func register(_ preset: any TransitionPreset) { ... }

    /// Look up a preset by ID. Returns nil if not found.
    public static func preset(for id: String) -> (any TransitionPreset)? { ... }

    /// All registered preset IDs in display order.
    public static var allIDs: [String] { ... }

    /// Preset IDs grouped by category for UI display.
    public static var byCategory: [(category: TransitionCategory, ids: [String])] { ... }

    // MARK: - Compatibility Mapping

    /// Map a legacy TransitionType to a presetID (for old drafts without presetID field).
    public static func presetID(for type: EditorTransition.TransitionType) -> String {
        switch type {
        case .fade:      return "crossFade"
        case .dissolve:  return "crossFade"
        case .slideLeft:  return "slideLeft"
        case .slideRight: return "slideRight"
        case .slideUp:    return "slideUp"    // fallback: crossFade if unimplemented
        case .slideDown:  return "slideDown"  // fallback: crossFade if unimplemented
        case .zoom:       return "zoomIn"
        case .wipe:       return "crossFade"  // fallback
        }
    }
}

public enum TransitionCategory: String, CaseIterable {
    case basic       = "基础"
    case motion      = "移动"
    case zoom        = "缩放"
    case blur        = "模糊"
    case stylized    = "风格化"   // 预留，V7 P2+
}
```

### 3.2 TransitionPreset 协议

```swift
/// A transition preset defines the visual effect for blending two frames.
public protocol TransitionPreset: Sendable {
    /// Unique identifier, e.g. "crossFade", "slideLeft".
    var presetID: String { get }

    /// Display name (localized).
    var displayName: String { get }

    /// Category for UI grouping.
    var category: TransitionCategory { get }

    /// Render the transition between outgoing and incoming frames at `progress` (0→1, already eased).
    ///
    /// outgoing = fading-out (main visual) frame.
    /// incoming = fading-in  (main visual) frame.
    /// Both frames are cropped to canvasSize. Returns the composited main-visual result.
    ///
    /// Called ONLY by TransitionComposer — never called directly by TimelineRenderer or exporters.
    /// Overlay / text layers must NOT be passed to this method.
    func render(
        outgoing: CIImage,
        incoming: CIImage,
        progress: Float,
        canvasSize: CGSize,
        context: CIContext
    ) -> CIImage
}
```

### 4.3 首批 4 个稳定 Preset 实现（M3）

> blurFade / zoomIn / slideRight / pushRight 进 M6，不在此实现。

#### 3.3.1 CrossFadePreset

```swift
struct CrossFadePreset: TransitionPreset {
    let presetID    = "crossFade"
    let displayName = "叠化"
    let category    = TransitionCategory.basic

    func render(outgoing: CIImage, incoming: CIImage, progress: Float,
                canvasSize: CGSize, context: CIContext) -> CIImage {
        // CIDissolveTransition: time=0 → outgoing, time=1 → incoming
        return outgoing.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: incoming,
            kCIInputTimeKey:        progress
        ])
    }
}
```

#### 3.3.2 FadeThroughBlackPreset

```swift
struct FadeThroughBlackPreset: TransitionPreset {
    let presetID    = "fadeThroughBlack"
    let displayName = "闪黑"
    let category    = TransitionCategory.basic

    func render(outgoing: CIImage, incoming: CIImage, progress: Float,
                canvasSize: CGSize, context: CIContext) -> CIImage {
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: canvasSize))
        if progress < 0.5 {
            // 前半段：outgoing → black
            let t = Float(progress / 0.5)
            return outgoing.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: black,
                kCIInputTimeKey:        t
            ])
        } else {
            // 后半段：black → incoming
            let t = Float((progress - 0.5) / 0.5)
            return black.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: incoming,
                kCIInputTimeKey:        t
            ])
        }
    }
}
```

#### 3.3.3 SlideLeftPreset / SlideRightPreset

```swift
struct SlidePreset: TransitionPreset {
    let presetID: String
    let displayName: String
    let category = TransitionCategory.motion
    let direction: Direction  // .left or .right

    enum Direction { case left, right }

    func render(outgoing: CIImage, incoming: CIImage, progress: Float,
                canvasSize: CGSize, context: CIContext) -> CIImage {
        let w = canvasSize.width
        let offset = CGFloat(progress) * w
        let dx: CGFloat = direction == .left ? -offset : offset

        // 出帧：向方向移动，最终完全移出画面
        let outgoingTranslated = outgoing.transformed(by: .init(translationX: dx, y: 0))
        // 入帧：从反方向进入
        let incomingDx: CGFloat = direction == .left ? (w - offset) : (-w + offset)
        let incomingTranslated = incoming.transformed(by: .init(translationX: incomingDx, y: 0))

        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        // Composite: incoming on top of outgoing (incoming enters from one side)
        return incomingTranslated
            .cropped(to: canvasRect)
            .composited(over: outgoingTranslated.cropped(to: canvasRect))
    }
}

// 注册时创建两个实例
let slideLeft  = SlidePreset(presetID: "slideLeft",  displayName: "左移", direction: .left)
let slideRight = SlidePreset(presetID: "slideRight", displayName: "右移", direction: .right)
```

#### 3.3.4 PushLeftPreset / PushRightPreset

Push 与 Slide 的区别：Push 中两帧同步移动，同一方向，感觉像「推」；Slide 中入帧静止、出帧移动（或反之）。Push 更接近剪映「推进」效果。

```swift
struct PushPreset: TransitionPreset {
    let presetID: String
    let displayName: String
    let category = TransitionCategory.motion
    let direction: Direction

    enum Direction { case left, right }

    func render(outgoing: CIImage, incoming: CIImage, progress: Float,
                canvasSize: CGSize, context: CIContext) -> CIImage {
        let w = canvasSize.width
        let offset = CGFloat(progress) * w
        let canvasRect = CGRect(origin: .zero, size: canvasSize)

        switch direction {
        case .left:
            // 出帧向左移动；入帧从右侧同步进入（两帧接壤）
            let outTranslated = outgoing.transformed(by: .init(translationX: -offset, y: 0))
            let inTranslated  = incoming.transformed(by: .init(translationX: w - offset, y: 0))
            return inTranslated.cropped(to: canvasRect)
                .composited(over: outTranslated.cropped(to: canvasRect))
        case .right:
            let outTranslated = outgoing.transformed(by: .init(translationX: offset, y: 0))
            let inTranslated  = incoming.transformed(by: .init(translationX: -w + offset, y: 0))
            return inTranslated.cropped(to: canvasRect)
                .composited(over: outTranslated.cropped(to: canvasRect))
        }
    }
}
```

#### 3.3.5 ZoomInPreset

```swift
struct ZoomInPreset: TransitionPreset {
    let presetID    = "zoomIn"
    let displayName = "放大"
    let category    = TransitionCategory.zoom

    func render(outgoing: CIImage, incoming: CIImage, progress: Float,
                canvasSize: CGSize, context: CIContext) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

        // 出帧：在画布中心放大（1.0 → 1.3），同时 opacity 1 → 0
        let scale = 1.0 + CGFloat(progress) * 0.3
        let outScaled = outgoing
            .transformed(by: scaleTransform(scale: scale, center: center, size: canvasSize))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(1 - progress))
            ])
            .cropped(to: canvasRect)

        // 入帧：直接以 opacity 0→1 淡入（不缩放）
        let inFaded = incoming
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(progress))
            ])
            .cropped(to: canvasRect)

        return inFaded.composited(over: outScaled)
    }

    private func scaleTransform(scale: CGFloat, center: CGPoint, size: CGSize) -> CGAffineTransform {
        // 以 center 为锚点缩放
        return CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -center.x, y: -center.y)
    }
}
```

#### 3.3.6 BlurFadePreset

```swift
struct BlurFadePreset: TransitionPreset {
    let presetID    = "blurFade"
    let displayName = "模糊叠化"
    let category    = TransitionCategory.blur

    func render(outgoing: CIImage, incoming: CIImage, progress: Float,
                canvasSize: CGSize, context: CIContext) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)

        // 出帧：模糊半径 0→12 + opacity 1→0
        let blurRadius = CGFloat(progress) * 12.0
        let outBlurred = outgoing
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blurRadius])
            .cropped(to: canvasRect)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(1 - progress))
            ])

        // 入帧：opacity 0→1（不模糊，清晰入场）
        let inFaded = incoming
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(progress))
            ])
            .cropped(to: canvasRect)

        return inFaded.composited(over: outBlurred)
    }
}
```

### 3.4 兼容映射表（旧 TransitionType → presetID）

```swift
extension TransitionPresetRegistry {
    static func presetID(for type: EditorTransition.TransitionType) -> String {
        switch type {
        case .fade:       return "crossFade"
        case .dissolve:   return "crossFade"
        case .slideLeft:  return "slideLeft"
        case .slideRight: return "slideRight"
        case .slideUp:    return fallbackIfUnregistered("slideUp")
        case .slideDown:  return fallbackIfUnregistered("slideDown")
        case .zoom:       return "zoomIn"
        case .wipe:       return fallbackIfUnregistered("wipeLeft")
        }
    }

    // fallback: if the target presetID isn't registered yet, return "crossFade"
    private static func fallbackIfUnregistered(_ id: String) -> String {
        return preset(for: id) != nil ? id : "crossFade"
    }
}
```

---

## 五、TransitionComposer

### 5.1 职责

`TransitionComposer` 是 `TimelineRenderer` 和 `ExportFrameProvider` 的**唯一**转场混合出口：

- 接收 `TransitionInfo`（来自 `LayerResolver`）
- 将 outgoing / incoming 的 CIImage（image 或 video 侧的帧）通过 `TransitionPresetRegistry` 查找对应预设
- 调用 `TransitionPreset.render`
- 不持有状态，所有方法为纯函数
- **只混合主轨 main visual；overlay / text 层由 TimelineRenderer 在 Step 4 单独叠加**

### 5.2 实现

**新增文件：`Sources/TimelineKit/Rendering/TransitionComposer.swift`**

```swift
#if canImport(UIKit)
import CoreImage
import CoreMedia

public enum TransitionComposer {

    /// Render the transition between two main-track frames.
    ///
    /// THIS IS THE ONLY ENTRY POINT for transition blending in both Preview and Export.
    /// TimelineRenderer and ExportFrameProvider must NOT contain any if-dissolve / if-slide logic.
    /// Overlay / text layers are NOT passed here — they are composited by the caller AFTER this call.
    ///
    /// - Parameters:
    ///   - info: Resolved transition from LayerResolver. Contains image/video specs + progress.
    ///   - compositionTime: CMTime used to pull video frames via VideoLayerComposer.
    ///   - canvasSize: Output frame size.
    ///   - context: Shared CIContext (Metal-backed).
    /// - Returns: Main-visual transition CIImage, or nil if both sides have no content.
    @MainActor
    public static func render(
        _ info: TransitionInfo,
        at compositionTime: CMTime,
        canvasSize: CGSize,
        context: CIContext
    ) -> CIImage? {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)

        // Resolve outgoing frame (image takes priority over video for same slot)
        let outgoingFrame: CIImage? = resolveFrame(
            image: info.outgoing,
            video: info.outgoingVideo,
            at: compositionTime
        )?.cropped(to: canvasRect)

        // Resolve incoming frame
        let incomingFrame: CIImage? = resolveFrame(
            image: info.incoming,
            video: info.incomingVideo,
            at: compositionTime
        )?.cropped(to: canvasRect)

        // Apply easing to rawProgress
        let easedProgress = EasingLUT.evaluate(
            kind: easingKind(info.easing),
            at: Double(info.rawProgress)
        )

        // Look up preset, fallback to crossFade if not found
        let preset = TransitionPresetRegistry.preset(for: info.presetID)
            ?? TransitionPresetRegistry.preset(for: "crossFade")!

        switch (outgoingFrame, incomingFrame) {
        case (let fg?, let bg?):
            return preset.render(
                outgoing: fg,
                incoming: bg,
                progress: Float(easedProgress),
                canvasSize: canvasSize,
                context: context
            )
        case (let fg?, nil):
            // Outgoing-only: fade out
            return fg.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(1 - easedProgress))
            ]).cropped(to: canvasRect)
        case (nil, let bg?):
            // Incoming-only: fade in
            return bg.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(easedProgress))
            ]).cropped(to: canvasRect)
        case (nil, nil):
            return nil
        }
    }

    // MARK: - Private

    private static func resolveFrame(
        image: ImageLayerSpec?,
        video: VideoLayerSpec?,
        at time: CMTime
    ) -> CIImage? {
        if let spec = image {
            return ImageLayerComposer.evaluate(spec: spec, at: time)
        }
        if let spec = video {
            // VideoLayerComposer returns CVPixelBuffer; bridge to CIImage
            if let pb = VideoLayerComposer.evaluate(spec: spec, at: time) {
                return CIImage(cvPixelBuffer: pb)
            }
        }
        return nil
    }

    private static func easingKind(_ easing: EditorTransition.Easing) -> EasingKind {
        switch easing {
        case .linear:    return .linear
        case .easeIn:    return .easeIn
        case .easeOut:   return .easeOut
        case .easeInOut: return .easeInOut
        }
    }
}
#endif
```

### 4.3 TimelineRenderer 修改（精确替换）

**`Sources/TimelineKit/Runtime/TimelineRenderer.swift:144-168`**

替换 `// ── Step 2: Apply transition blend` 块：

```swift
// ── Step 2: Render transition (main visual only) ─────────────────────────
// V7: ALL transition logic lives in TransitionComposer; zero if-dissolve / if-slide here.
// Overlay / text layers are composited in Step 3 (after this block).
if let trans = frame.transition {
    let mainVisual = TransitionComposer.render(
        trans,
        at: cmTime,
        canvasSize: canvasSize,
        context: ciContext
    )
    if let mainVisual {
        composite = mainVisual.composited(over: composite)
    }
    // nil = both sides empty →末態停驻 already handled at top of renderFrame.
}
```

删除原有代码（`applyEasing` 私有方法也可删除，因为 easing 已移入 `TransitionComposer`）：

```swift
// 删除以下私有方法（V7 不再需要）：
// private func applyEasing(_ progress: Float, easing: EditorTransition.Easing) -> Float
```

---

## 六、EditorTransition 模型扩展

**`Sources/TimelineKit/Models/EditorTransition.swift`** — V7 追加字段：

```swift
public struct EditorTransition: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var type: TransitionType
    public var duration: Double
    public var easing: Easing
    public var leadingSegmentID: UUID
    public var trailingSegmentID: UUID

    // V7 新增（均为 decodeIfPresent 容错，旧草稿 nil）：

    /// Resolved preset identifier (e.g. "crossFade", "slideLeft").
    /// Nil in old drafts → mapped via TransitionPresetRegistry.presetID(for: type).
    public var presetID: String?

    /// Directional hint for slide/push/wipe transitions.
    /// Nil → preset's default direction.
    public var direction: Direction?

    /// Effect intensity 0.0–1.0. Nil → preset default (1.0).
    public var intensity: Float?

    public enum Direction: String, Sendable, Hashable, Codable {
        case left, right, up, down
    }

    // 扩展 TransitionType（V7 新增 case）：
    public enum TransitionType: String, Sendable, Hashable, Codable, CaseIterable {
        case fade
        case slideLeft   = "slide_left"
        case slideRight  = "slide_right"
        case slideUp     = "slide_up"
        case slideDown   = "slide_down"
        case zoom
        case dissolve
        case wipe
        // V7 新增（与 presetID 对应）：
        case crossFade   = "cross_fade"
        case fadeThroughBlack = "fade_through_black"
        case pushLeft    = "push_left"
        case pushRight   = "push_right"
        case zoomIn      = "zoom_in"
        case blurFade    = "blur_fade"
    }
}
```

---

## 七、App Launch 注册

在 `TimelineKit` 模块初始化时（或 `TimelineRenderer.init` 中）执行一次注册：

```swift
// TimelineKit.swift — 在 TimelineKit.setup() 内调用
// M3 首批 4 个稳定预设；blurFade / zoomIn / slideRight / pushRight 在 M6 追加
func registerDefaultTransitions() {
    TransitionPresetRegistry.register(CrossFadePreset())
    TransitionPresetRegistry.register(FadeThroughBlackPreset())
    TransitionPresetRegistry.register(SlidePreset(presetID: "slideLeft", displayName: "左移",    direction: .left))
    TransitionPresetRegistry.register(PushPreset(presetID:  "pushLeft",  displayName: "推进·左", direction: .left))
    // M6 追加：slideRight / pushRight / zoomIn / blurFade
}
```

---

## 八、验收标准

| 验收项 | 具体标准 | 验证方式 |
|---|---|---|
| 图片→图片转场不黑屏 | transition zone 内每帧 `TransitionInfo.hasValidContent == true` | 截 5 帧（progress ≈ 0.1/0.3/0.5/0.7/0.9）均有内容 |
| 图片→视频转场不黑屏 | `TransitionInfo.outgoing != nil && incomingVideo != nil` | 同上 |
| 视频→图片转场不黑屏 | `outgoingVideo != nil && incoming != nil` | 同上 |
| 视频→视频转场不黑屏 | `outgoingVideo != nil && incomingVideo != nil` | 同上 |
| crossFade 视觉一致 | 与 V6 dissolve 对比，同 progress 帧 diff ≤ 1px | 逐像素 compare |
| fadeThroughBlack | progress=0.5 时输出为纯黑（R=G=B=0） | 截帧 + 像素采样 |
| slideLeft | progress=0.5 时左半画面为出帧、右半为入帧；边界连续无缝隙 | 截帧检查边界像素 |
| pushLeft | progress=0.5 时出帧 x 偏移 = -w/2；入帧 x 偏移 = +w/2 | 截帧 + 像素坐标验证 |
| _(M6)_ zoomIn | progress=0.5 时出帧 scale ≈ 1.15，opacity ≈ 0.5；入帧 opacity ≈ 0.5 | 截帧目视 |
| _(M6)_ blurFade | progress=0.5 时出帧模糊明显（radius ≈ 6）；入帧 opacity ≈ 0.5 清晰 | 截帧目视 |
| **overlay 不参与转场** | overlay segment 在 transition zone 内独立渲染，位置 / opacity / 内容不受主轨转场影响 | overlay 文字在转场前中后位置固定，不随主画面 slide / dissolve |
| **text / subtitle 不参与转场** | text segment 在 transition zone 内独立渲染，叠加在 TransitionComposer 输出之上 | 文字不闪、不丢、不重复 |
| **TransitionComposer 内无 overlay 处理** | 审查 TransitionComposer.swift：不含任何 overlay / text spec 引用 | grep "overlay\|text\|subtitle" TransitionComposer.swift → 无命中 |
| Preview = Export | 同一 compositionTime 的帧差异 ≤ 2px | ffprobe 帧数正确 + 逐帧截图比较 |
| Preview = Export | 同一 compositionTime 的帧差异 ≤ 2px | ffprobe 帧数正确 + 逐帧截图比较 |
| 旧草稿兼容 | `EditorTransition.type == .fade` 的旧草稿打开后转场效果 = crossFade | 用 V6 导出的草稿加载 |
| 未知 presetID fallback | `presetID = "nonexistent"` → 使用 crossFade，不崩溃 | 构造错误 presetID 的 EditorTransition |
| blurFade 帧耗时（A12）| ≤ 20ms | Xcode Instruments Time Profiler |
| crossFade 帧耗时 | ≤ 8ms | 同上 |

---

## 九、V7 固定约束重申

> 实现本 spec 时须遵守（来源：V7-initiation.md §八）：
>
> - **`TransitionComposer.render` 是唯一出口**：TimelineRenderer / ExportFrameProvider 内部不得有任何 `if dissolve / if slide / CIDissolveTransition` 逻辑
> - **转场不冻结 KeyframeEvaluator**：overlap 期间两侧 clip 关键帧继续独立求值
> - **所有 TransitionType case 必须有 preset 或 fallback**：不允许静默丢弃
> - **服务端不认识的转场 fallback 到 crossFade + 打日志**
> - **转场仅作用于主轨（videoTrack）片段之间**（v2 约束）
> - **转场时长 min=0.2s / max=3.0s**（v2 约束）
> - **50/50 overlap 无 Handle 模型**（v2 约束）
