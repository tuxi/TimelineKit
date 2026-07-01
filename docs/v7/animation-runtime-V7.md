# V7 Animation Runtime 核心架构规范

> 版本：v7.1
> 状态：规范定稿
> 优先级：P0（Animation Runtime 基座；在 M1-M3 转场系统稳定后推进）
> 依赖：
>   - [transition-system-spec.md](transition-system-spec.md)（三层架构已验证，本规范平行建立）
>   - [animation-draft-compat-V7.md](animation-draft-compat-V7.md)（DraftStore 集成）
>   - [competitive-benchmarks-animation-V7.md](competitive-benchmarks-animation-V7.md)（调研依据）

---

## 一、背景：为什么 V7 要建 Animation Runtime

### 1.1 现状问题

V6 完成了「图片 Ken Burns 动画」的架构（`ImageAnimationPresetRegistry` + `KeyframeEvaluator`），但存在以下结构性缺陷：

**问题 1：动画绑定了素材类型**

```swift
// 现状：只有 ImageAnimationPreset，不适用于视频
ImageAnimationPresetRegistry.keyframes(for: preset, duration: duration) // ← 只能图片用
```

视频片段没有等价的动画机制。未来 text / sticker / overlay 支持动画时，又会独立出 `TextAnimation` / `StickerAnimation`，彻底炸裂。

**问题 2：只有「组合」类动画，没有「入场/出场」**

现有 `ImageAnimationPreset` 全部是全程时长动画（Ken Burns 类），占据整个 clip duration。没有独立的入场（前 N 秒渐入）和出场（后 N 秒渐出）机制。

**问题 3：没有三层架构**

服务端直接传 `animationPresetID`（客户端实现细节），服务端与 preset 实现强耦合。转场系统 V7 M5 已通过 `TransitionSemantic` 验证了三层架构的正确性，动画系统必须同构。

**问题 4：image_3d 是 TimelineImporter 里的特判**

`TimelineImporter` 对 `SCamera` / `SImageAnimation` / `SDepthModel` 有三处特判逻辑，生成不同的 `KeyframeSet`。这些本质上都是「clip 级别的组合动画」，应该统一进 `AnimationSemantic`。

### 1.2 V7 Animation Runtime 的目标

V7 不是「做更多动画」，而是**建立 TimelineKit 的统一动画架构基座**：

1. **统一动画模型**：`ClipAnimation` 适用于所有内容类型（图片 / 视频 / 未来的 text / sticker）
2. **三层架构**：Server Intent → `AnimationSemantic` → RuntimePreset（与转场系统同构）
3. **入场/出场/组合**：三类动画时序，互不干扰
4. **单出口**：`AnimationComposer.apply(...)` 是 Preview 和 Export 共用的唯一动画渲染出口
5. **不改 duration**：动画只影响渲染，不修改 `segment.targetRange`
6. **DraftStore 稳定**：`ClipAnimation` 字段作为 `EditorSegment` 的扩展字段，`decodeIfPresent` 向下兼容

---

## 二、三层架构

```
Server Intent（服务端描述意图，随服务端迭代变动）
        ↓  AnimationSemantic.from(server:)
AnimationSemantic（客户端稳定语义，只描述"做什么"，不关心"怎么做"）
        ↓  AnimationSemantic.resolvedPresetID
RuntimePreset（客户端实现细节，可重构、可多端差异化）
```

**与转场系统同构：**

| 系统 | Server Intent | Client Semantic | Runtime Preset |
|---|---|---|---|
| 转场 | `STransition.type` | `TransitionSemantic` | `TransitionPreset` |
| **动画（V7 新建）** | `SAnimation.type` | **`AnimationSemantic`** | **`AnimationPreset`** |

**架构约束（禁止打破）：**
1. 服务端不持有 presetID：服务端 JSON 只描述语义意图
2. Semantic 层只增不改：已有 case 禁止改名或删除（旧数据永久可解析）
3. `resolvedPresetID` 是唯一的 semantic→preset 映射出口
4. 未知 intent 必须 fallback + log，不允许静默 crash 或无效果

---

## 三、数据模型

### 3.1 ClipAnimation（新增，附加在 EditorSegment）

```swift
/// A single clip-level animation (entrance / exit / combo).
/// Stored per-segment. Does NOT modify targetRange.
public struct ClipAnimation: Identifiable, Sendable, Hashable, Codable {

    public let id: UUID

    /// Stable semantic intent. Written by server or user selection.
    public var semantic: AnimationSemantic

    /// Which phase of the clip this animation applies to.
    public var timing: AnimationTiming

    /// Duration in seconds. Clamped to [0.1, min(2.0, segDuration * 0.5)] at runtime.
    /// For combo animations: ignored (uses full segment duration).
    public var duration: Double

    /// Optional directional qualifier. Nil = semantic default.
    public var direction: AnimationDirection?

    /// Effect intensity 0.0-1.0. Nil = preset default (1.0).
    public var intensity: Float?

    public init(
        id: UUID = UUID(),
        semantic: AnimationSemantic,
        timing: AnimationTiming,
        duration: Double,
        direction: AnimationDirection? = nil,
        intensity: Float? = nil
    ) { ... }
}

public enum AnimationTiming: String, Sendable, Hashable, Codable, CaseIterable {
    case `in`    = "in"     // 入场：clip 开始后 N 秒内
    case out     = "out"    // 出场：clip 结束前 N 秒内
    case combo   = "combo"  // 组合：全程；与 in/out 互斥（见 §3.3）
}

public enum AnimationDirection: String, Sendable, Hashable, Codable {
    case left, right, up, down
}
```

### 3.2 EditorSegment 扩展

```swift
// 在 EditorSegment.CodingKeys 新增 animations case
private enum CodingKeys: String, CodingKey {
    // ... 原有 keys 不变 ...
    case animations  // ← V7 新增
}

// 在 init(from decoder:) 新增（decodeIfPresent，旧草稿 nil = 无动画）
self.animations = try c.decodeIfPresent([ClipAnimation].self, forKey: .animations) ?? []

// 属性定义（在原有属性后）
/// V7: clip-level animations (in / out / combo). Empty = no animations.
public var animations: [ClipAnimation] = []
```

**向下兼容承诺：**
- 旧草稿（v1-v6）无 `animations` 字段 → `decodeIfPresent` 返回 nil → 默认 `[]` → 完全正常加载，行为与之前一致
- 无任何字段删除或重命名

### 3.3 动画互斥规则

```
入场 + 出场 = 允许同时存在（各自独立）
组合 alone = 允许
组合 + 入场 = ❌ 禁止（combo 优先，UI 层强制）
组合 + 出场 = ❌ 禁止（combo 优先，UI 层强制）
同类型重复（两个 in）= ❌ 禁止（后者覆盖前者）
```

```swift
// EditorSegment 辅助方法
public extension EditorSegment {
    var inAnimation: ClipAnimation?    { animations.first(where: { $0.timing == .in }) }
    var outAnimation: ClipAnimation?   { animations.first(where: { $0.timing == .out }) }
    var comboAnimation: ClipAnimation? { animations.first(where: { $0.timing == .combo }) }

    mutating func setAnimation(_ anim: ClipAnimation) {
        if anim.timing == .combo {
            animations = [anim]  // combo 清除 in/out
        } else {
            animations.removeAll { $0.timing == anim.timing || $0.timing == .combo }
            animations.append(anim)
        }
    }

    mutating func removeAnimation(timing: AnimationTiming) {
        animations.removeAll { $0.timing == timing }
    }
}
```

---

## 四、AnimationSemantic

```swift
import os.log

/// Stable, intent-level description of a clip animation effect.
///
/// Three-layer architecture (parallel to TransitionSemantic):
/// ```
/// server JSON field (raw, may change over time)
///         ↓
/// AnimationSemantic (stable — captures visual intent, never the implementation)
///         ↓
/// runtime presetID (client-internal, free to refactor)
/// ```
public enum AnimationSemantic: String, Sendable, Hashable, Codable, CaseIterable {

    // MARK: - Entrance (入场)
    case fadeIn         = "fade_in"
    case slideInLeft    = "slide_in_left"
    case slideInRight   = "slide_in_right"
    case slideInUp      = "slide_in_up"
    case slideInDown    = "slide_in_down"
    case zoomIn         = "zoom_in"

    // MARK: - Exit (出场)
    case fadeOut        = "fade_out"
    case slideOutLeft   = "slide_out_left"
    case slideOutRight  = "slide_out_right"
    case zoomOut        = "zoom_out"

    // MARK: - Combo (组合，全程时长)
    case slowZoom       = "slow_zoom"    // 缓慢放大（Ken Burns 迁移）
    case drift          = "drift"        // 漂浮位移（Ken Burns 迁移）
    case float          = "float"        // 垂直浮动（呼吸感）

    // MARK: - Depth (景深，M6 从 ImageAnimationPreset 迁移)
    case depthPush      = "depth_push"
    case depthPull      = "depth_pull"
    case depthPanLeft   = "depth_pan_left"
    case depthPanRight  = "depth_pan_right"

    // MARK: - Fallback
    /// Intent not recognized — maps to fadeIn (in) / fadeOut (out) / slowZoom (combo).
    case unknown = "unknown"
}
```

### 4.1 Server → Semantic 映射

```swift
private let animationLogger = Logger(subsystem: "TimelineKit", category: "AnimationSemantic")

extension AnimationSemantic {

    public static func from(
        serverType: String,
        timing: AnimationTiming,
        direction: String? = nil
    ) -> AnimationSemantic {
        let type = serverType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dir  = direction?.lowercased()

        switch type {

        // ── Fade family ───────────────────────────────────────────────────────
        case "fade", "fade_in", "fadein", "alpha_in":
            return timing == .out ? .fadeOut : .fadeIn
        case "fade_out", "fadeout", "alpha_out":
            return .fadeOut

        // ── Slide family ─────────────────────────────────────────────────────
        case "slide", "slide_in":
            switch dir {
            case "right": return .slideInRight
            case "up":    return .slideInUp
            case "down":  return .slideInDown
            default:      return .slideInLeft
            }
        case "slide_in_left":   return .slideInLeft
        case "slide_in_right":  return .slideInRight
        case "slide_in_up":     return .slideInUp
        case "slide_in_down":   return .slideInDown
        case "slide_out", "slide_out_left":  return .slideOutLeft
        case "slide_out_right":              return .slideOutRight

        // ── Zoom family ──────────────────────────────────────────────────────
        case "zoom", "zoom_in", "scale_in", "zoomin":
            return timing == .out ? .zoomOut : .zoomIn
        case "zoom_out", "scale_out": return .zoomOut

        // ── Combo / Ken Burns family ─────────────────────────────────────────
        case "slow_zoom", "slowzoom", "ken_burns", "zoom_loop": return .slowZoom
        case "drift", "pan_loop", "pan":                         return .drift
        case "float", "breath", "breathe", "pulse":              return .float

        // ── Depth family ─────────────────────────────────────────────────────
        case "depth_push", "image_3d_push": return .depthPush
        case "depth_pull", "image_3d_pull": return .depthPull
        case "depth_pan_left":              return .depthPanLeft
        case "depth_pan_right":             return .depthPanRight

        // ── Unrecognized ─────────────────────────────────────────────────────
        default:
            animationLogger.warning(
                "[AnimationSemantic] '\(type, privacy: .public)': unrecognized, using unknown"
            )
            return .unknown
        }
    }
}
```

### 4.2 Semantic → Runtime presetID

```swift
extension AnimationSemantic {

    /// Resolve to a registered client presetID.
    /// Falls back to safe defaults if preset not yet registered.
    public func resolvedPresetID(timing: AnimationTiming) -> String {
        let target: String
        switch self {
        case .fadeIn:        target = "fadeIn"
        case .slideInLeft:   target = "slideInLeft"
        case .slideInRight:  target = "slideInRight"
        case .slideInUp:     target = "slideInUp"
        case .slideInDown:   target = "slideInDown"
        case .zoomIn:        target = "zoomIn"
        case .fadeOut:       target = "fadeOut"
        case .slideOutLeft:  target = "slideOutLeft"
        case .slideOutRight: target = "slideOutRight"
        case .zoomOut:       target = "zoomOut"
        case .slowZoom:      target = "slowZoom"
        case .drift:         target = "drift"
        case .float:         target = "float"
        case .depthPush:     target = "depthPush"
        case .depthPull:     target = "depthPull"
        case .depthPanLeft:  target = "depthPanLeft"
        case .depthPanRight: target = "depthPanRight"
        case .unknown:
            // fallback: safe default by timing
            return timing == .out ? "fadeOut" : timing == .combo ? "slowZoom" : "fadeIn"
        }

        if AnimationPresetRegistry.preset(for: target) != nil {
            return target
        }
        let fallback = timing == .out ? "fadeOut" : timing == .combo ? "slowZoom" : "fadeIn"
        animationLogger.debug(
            "[AnimationSemantic] preset '\(target, privacy: .public)' not registered, fallback to \(fallback)"
        )
        return fallback
    }
}
```

---

## 五、AnimationPresetRegistry

```swift
import CoreImage

// MARK: - AnimationPreset Protocol

/// A single registered animation effect.
/// Implement `apply(to:progress:context:)` to transform the rendered CIImage.
///
/// progress semantics:
///   - in  animation: 0 = clip start (fully hidden/transformed), 1 = normal state
///   - out animation: 0 = fully visible (normal state), 1 = clip end (fully hidden/transformed)
///   - combo animation: 0 = clip start, 1 = clip end (continuous)
public protocol AnimationPreset: Sendable {
    var presetID: String { get }
    var timing: AnimationTiming { get }  // which timing this preset is valid for

    /// Apply animation transform to a fully-composed CIImage.
    /// - Parameters:
    ///   - image: The rendered frame (output of ImageLayerComposer or VideoLayerComposer).
    ///   - progress: Normalized 0.0-1.0 position within the animation window.
    ///   - extent: Canvas bounds (for position-based transforms).
    ///   - context: CIContext (for GPU-accelerated filters).
    /// - Returns: Transformed CIImage. Must not be nil even if no effect applied.
    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage
}

// MARK: - AnimationPresetRegistry

public enum AnimationPresetRegistry {

    private static var _registry: [String: any AnimationPreset] = [:]

    public static func register(_ preset: any AnimationPreset) {
        _registry[preset.presetID] = preset
    }

    public static func preset(for presetID: String) -> (any AnimationPreset)? {
        _registry[presetID]
    }

    /// Must be called once at app launch (before any timeline rendering).
    public static func registerBuiltins() {
        // V7 Phase 1: entrance
        register(FadeInPreset())
        register(SlideInLeftPreset())
        register(SlideInRightPreset())
        register(SlideInUpPreset())
        register(SlideInDownPreset())
        register(ZoomInPreset())
        // V7 Phase 1: exit
        register(FadeOutPreset())
        register(SlideOutLeftPreset())
        register(SlideOutRightPreset())
        register(ZoomOutPreset())
        // V7 Phase 1: combo
        register(SlowZoomComboPreset())
        register(DriftComboPreset())
        register(FloatComboPreset())
    }
}
```

### 5.1 V7 首批预设实现规范

**入场预设（progress: 0→1，0=被遮蔽/位移，1=正常状态）：**

| presetID | opacity | transform | easing |
|---|---|---|---|
| `fadeIn` | 0→1 | identity | easeOut |
| `slideInLeft` | 0→1 | translateX(-W→0) | easeOut |
| `slideInRight` | 0→1 | translateX(+W→0) | easeOut |
| `slideInUp` | 0→1 | translateY(+H→0) | easeOut |
| `slideInDown` | 0→1 | translateY(-H→0) | easeOut |
| `zoomIn` | 0→1 | scale(0.85→1.0) | easeOut |

其中 W = extent.width，H = extent.height。

**出场预设（progress: 0→1，0=正常，1=被遮蔽/位移）：**

| presetID | opacity | transform | easing |
|---|---|---|---|
| `fadeOut` | 1→0 | identity | easeIn |
| `slideOutLeft` | 1→0 | translateX(0→-W) | easeIn |
| `slideOutRight` | 1→0 | translateX(0→+W) | easeIn |
| `zoomOut` | 1→0 | scale(1.0→0.85) | easeIn |

**组合预设（progress: 0→1，全程时长，对应现有 Ken Burns 迁移路径）：**

| presetID | 效果 | 实现方式 |
|---|---|---|
| `slowZoom` | scale 1.0→1.12（全程） | 与 `ImageAnimationPreset.slowZoomIn` 语义一致 |
| `drift` | translateX(-3%→+3%) + scale 1.06→1.0 | 与 `ImageAnimationPreset.panRight` 类似 |
| `float` | translateY 正弦 ±2%，0.5Hz | 呼吸/漂浮感 |

**注意：** 组合预设通过 `AnimationComposer` 渲染，**不再**经过 `ImageAnimationPresetRegistry.keyframes(for:)`——两个系统在 V7 Phase 1 并行存在，M6 完成迁移后 `ImageAnimationPresetRegistry` 可逐步废弃。

---

## 六、AnimationComposer

```swift
import CoreImage
import os.log

private let composerLogger = Logger(subsystem: "TimelineKit", category: "AnimationComposer")

/// The SINGLE entry point for all clip animation rendering.
/// Called by TimelineRenderer and ExportFrameProvider — never duplicated.
///
/// This composer is additive to the existing layer composing pipeline:
/// ImageLayerComposer / VideoLayerComposer → AnimationComposer → UnifiedCompositor
public enum AnimationComposer {

    /// Apply the active clip animation to a fully-rendered frame.
    ///
    /// - Parameters:
    ///   - image:        The base rendered frame (output of layer composer).
    ///   - segment:      The segment being rendered (provides targetRange + animations).
    ///   - compositionTime: Current composition time in seconds (absolute).
    ///   - extent:       Canvas bounds for position-based transforms.
    ///   - context:      Shared CIContext.
    /// - Returns: Animated frame. Returns `image` unchanged if no animation applies.
    public static func apply(
        to image: CIImage,
        segment: EditorSegment,
        compositionTime: Double,
        extent: CGRect,
        context: CIContext
    ) -> CIImage {
        let segStart = segment.targetRange.start
        let segEnd   = segment.targetRange.end

        // Combo animation takes precedence — check first
        if let combo = segment.comboAnimation {
            let progress = Float((compositionTime - segStart) / segment.targetRange.duration)
            return applyPreset(id: combo.semantic.resolvedPresetID(timing: .combo),
                               to: image, progress: clamp01(progress), extent: extent, context: context)
        }

        // In animation
        if let inAnim = segment.inAnimation {
            let inEnd = segStart + inAnim.effectiveDuration(segment: segment)
            if compositionTime < inEnd {
                let progress = Float((compositionTime - segStart) / inAnim.effectiveDuration(segment: segment))
                return applyPreset(id: inAnim.semantic.resolvedPresetID(timing: .in),
                                   to: image, progress: clamp01(progress), extent: extent, context: context)
            }
        }

        // Out animation
        if let outAnim = segment.outAnimation {
            let outStart = segEnd - outAnim.effectiveDuration(segment: segment)
            if compositionTime >= outStart {
                let progress = Float((compositionTime - outStart) / outAnim.effectiveDuration(segment: segment))
                return applyPreset(id: outAnim.semantic.resolvedPresetID(timing: .out),
                                   to: image, progress: clamp01(progress), extent: extent, context: context)
            }
        }

        return image  // no animation in this time window
    }

    private static func applyPreset(id: String, to image: CIImage,
                                    progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        guard let preset = AnimationPresetRegistry.preset(for: id) else {
            composerLogger.warning("[AnimationComposer] preset '\(id)' not found, skipping")
            return image
        }
        return preset.apply(to: image, progress: progress, extent: extent, context: context)
    }

    private static func clamp01(_ v: Float) -> Float { max(0, min(1, v)) }
}

extension ClipAnimation {
    /// Effective animation duration, clamped to segment constraints.
    func effectiveDuration(segment: EditorSegment) -> Double {
        let maxHalf = segment.targetRange.duration * 0.5
        return min(duration, min(2.0, maxHalf))
    }
}
```

---

## 七、渲染管线集成位置

V7 Animation Runtime 插入到现有渲染管线的**第二层**，在 layer composer 之后、UnifiedCompositor 叠合之前：

```
TimelineRenderer.renderFrame(at compositionTime)
  │
  ├─ LayerResolver.resolve → [LayerSpec] + TransitionInfo?
  │
  ├─ For each LayerSpec:
  │   ├─ ImageLayerComposer.evaluate(imageSpec, time)  → baseCIImage
  │   │   └─ KeyframeEvaluator.evaluate(keyframes)     → transform matrix (Ken Burns)
  │   │
  │   ├─ [V7 新增] AnimationComposer.apply(to:baseCIImage, segment:, time:, extent:, context:)
  │   │                                                 → animatedCIImage
  │   │
  │   └─ animatedCIImage → UnifiedCompositor stack
  │
  ├─ UnifiedCompositor.composite([...]) → compositedFrame
  │
  └─ [如有转场] TransitionComposer.blend(outgoing:incoming:preset:progress:)
                                         → finalFrame
```

**关键约束：**
1. `AnimationComposer.apply` 接收的是 `KeyframeEvaluator` 已经处理过的帧（Ken Burns transform 已应用）
2. 入场/出场动画叠加在 Ken Burns 之上（两者可共存，直到 M6 完成 combo 迁移）
3. `AnimationComposer.apply` 在 `TransitionComposer.blend` **之前**执行（转场混合最后发生）
4. `ExportFrameProvider.frame(at:)` 必须调用相同的 `AnimationComposer.apply`，禁止自行实现动画

---

## 八、与现有 KeyframeEvaluator 的关系

| 系统 | 处理内容 | 时序 | V7 状态 |
|---|---|---|---|
| `KeyframeEvaluator` | 5D transform keyframes（position / scale / rotation / anchor / opacity）| 贯穿全程 segment | 不改动 |
| `ImageAnimationPresetRegistry` | Ken Burns 系列（slowZoomIn / panLeft 等），生成 KeyframeSet | 贯穿全程 | V7 Phase 1 并行保留；M6 迁移后逐步废弃 |
| **`AnimationComposer`（V7 新建）** | 入场/出场/组合 clip 动画，作用于渲染帧 | 仅在动画时窗内 | V7 Phase 1 新建 |

**Phase 1（V7）：** 两套并行存在，互不干扰。
- 图片 Ken Burns：`ImageAnimationPresetRegistry` → `KeyframeEvaluator` → `ImageLayerComposer`（不变）
- 入场/出场：`AnimationComposer`（新建）

**M6 目标：** 将 `ImageAnimationPreset` 全部映射到 `AnimationSemantic.combo`，通过 `AnimationComposer` 统一渲染，`ImageAnimationPresetRegistry` 保留作兼容层（生成 KeyframeSet 路径仍然可用，但新代码不再调用）。

---

## 九、约束（禁止打破）

1. **`AnimationComposer.apply` 是唯一动画渲染出口**：`TimelineRenderer` 和 `ExportFrameProvider` 内部禁止直接写 `if fadeIn / CIAffineTransform / opacity ramp`

2. **动画不允许修改 timeline duration**：
   - `setAnimation` / `removeAnimation` 禁止修改任何 `segment.targetRange`
   - 动画只影响渲染层（opacity / transform），不影响时间轴

3. **Overlay / Text / Subtitle 不参与 clip 动画（Phase 1）**：
   - V7 Phase 1 的 `AnimationComposer.apply` 只调用于主轨和 overlay 图层的 image/video clip
   - text / subtitle / sticker 延后

4. **入场和出场时长之和不超过 clip 时长**：
   - `effectiveDuration` 实现此约束（各自 max = segDuration * 0.5）
   - UI 层同样需要强制约束（见 animation-ui-spec-V7.md §5）

5. **Combo 动画与入场/出场互斥**：
   - `setAnimation` 保证：设置 combo 时清除 in/out；设置 in/out 时清除 combo

6. **未知 semantic 必须 fallback + log，不允许静默无效果**

---

## 十、里程碑

> V7 Animation Runtime 依赖 M1-M3（转场系统）稳定后推进。

| 里程碑 | 内容 | 关键交付 |
|---|---|---|
| **Am1：基座骨架** | `ClipAnimation` + `AnimationSemantic` + `AnimationPresetRegistry` 骨架（只注册 fadeIn / fadeOut）；`EditorSegment.animations` 字段 + DraftStore 验证 | EditorSegment 可持久化 `animations` 字段；旧草稿 100% 正常加载 |
| **Am2：AnimationComposer + 渲染集成** | `AnimationComposer` 插入 `TimelineRenderer` 和 `ExportFrameProvider`；fadeIn / fadeOut 两个预设完整实现 + Preview/Export 验证 | fadeIn / fadeOut 在图片和视频 clip 上均正确渲染；导出一致 |
| **Am3：首批 Phase 1 预设完整** | 补全 slideIn（4 方向）/ zoomIn / slideOut / zoomOut / slowZoom / drift / float | 所有 Phase 1 预设通过图片+视频两种内容类型验证 |
| **Am4：UI 面板** | 入场/出场/组合 Tab + 预设宫格 + 时长 slider + live preview | 用户可在 clip 上添加/更换/删除动画 |
| **Am5：服务端映射** | `AnimationSemantic.from(server:)` + `TimelineImporter` 动画字段解码 | 服务端下发动画 → 正确渲染；未知类型安全降级 |
| **Am6：image_3d / Ken Burns 迁移** | `ImageAnimationPreset` 全部映射到 `AnimationSemantic.combo`；`TimelineImporter` 不再特判 `SCamera` / `SImageAnimation` | `image_3d` 通过 `AnimationSemantic.depthPush` 等路由；`ImageAnimationPresetRegistry` 降级为兼容层 |
