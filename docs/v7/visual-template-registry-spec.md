# 视觉模板注册表基座规范（V7）

> 版本：v7.0
> 状态：规范定稿，待实现
> 优先级：P1（M4 / M6，P0 转场系统上线后执行）
> 依赖：
> - [transition-system-spec.md](transition-system-spec.md)：TransitionPresetRegistry 作为四件之一
> - v6 [ai-timeline-mapping-spec.md](../v6/ai-timeline-mapping-spec.md)：AnimationMacro 与 ImageAnimationPresetRegistry 的关系
> - v6 [keyframe-animation-spec.md](../v6/keyframe-animation-spec.md)：KeyframeSet 数据模型
> - [ServerTimelineSchema.swift](../../Sources/TimelineKit/Conversion/ServerTimelineSchema.swift)：服务端 transition 字段

---

## 一、目标：统一视觉模板基座

V7 的核心命题之一：**以后服务端生成 timeline 时，不应该随意给自由参数，而应该尽量引用客户端已验证的 presetID**。

实现这一目标需要四件注册表形成统一基座：

| 注册表 | 职责 | V6/V7 状态 |
|---|---|---|
| `ImageAnimationPresetRegistry` | 图片动画预设（zoom_in / pan_left 等） | V6 AnimationMacro 已有雏形；V7 完整化接口 |
| `Image3DPresetRegistry` | 图片 3D 假 3D 运镜预设（image_3d 系列） | V6 image_3d 雏形；V7 完整化接口 |
| `TransitionPresetRegistry` | 转场预设 | V7 P0 新建（见 transition-system-spec.md §3）|
| `TimelineTemplateConverter` | 服务端 timeline 字段 → 客户端 presetID 映射 | V7 P1 新建 |

---

## 二、统一注册表接口规范

四件注册表遵循同一接口模式（方便未来统一管理 + 运营下发预设）：

### 2.1 通用 VisualPreset 协议

```swift
/// Base protocol for all visual presets (animation / transition / 3D).
public protocol VisualPreset: Sendable {
    /// Unique stable identifier (used in drafts + server references).
    var presetID: String { get }

    /// Localized display name for UI.
    var displayName: String { get }

    /// Category string for UI grouping (registry-specific enum).
    var categoryRawValue: String { get }
}
```

### 2.2 通用 VisualPresetRegistry 骨架

```swift
/// Thread-safe registry for any VisualPreset type.
/// Uses actor isolation — all mutations are serialized.
public actor VisualPresetRegistryStore<Preset: VisualPreset> {
    private var presets: [String: Preset] = [:]
    private var order: [String] = []

    public func register(_ preset: Preset) {
        presets[preset.presetID] = preset
        if !order.contains(preset.presetID) {
            order.append(preset.presetID)
        }
    }

    public func preset(for id: String) -> Preset? {
        presets[id]
    }

    public var allIDs: [String] { order }
}
```

实际暴露的三个注册表（`TransitionPresetRegistry` 已在 transition-system-spec.md 定义）：

```swift
public enum ImageAnimationPresetRegistry {
    // ... 包装 VisualPresetRegistryStore<ImageAnimationPreset>
}

public enum Image3DPresetRegistry {
    // ... 包装 VisualPresetRegistryStore<Image3DPreset>
}
```

### 2.3 ImageAnimationPresetRegistry（V6 完整化）

V6 `AnimationMacro` 已经能把 `motionPreset` 展开为关键帧序列，但这些展开规则是散落在 AnimationMacro 内部的 switch-case，没有对外暴露的 registry 接口。V7 把它规范化：

```swift
public protocol ImageAnimationPreset: VisualPreset {
    /// Expand this preset into a KeyframeSet for the given duration.
    func expand(duration: Double) -> KeyframeSet
}

public enum ImageAnimationPresetRegistry {
    // 内置预设（对应 V6 AnimationMacro 的 6 个 motionPreset）：
    // zoom_in / zoom_out / pan_left / pan_right / pan_up / pan_down

    public static func register(_ preset: any ImageAnimationPreset)
    public static func preset(for id: String) -> (any ImageAnimationPreset)?
    public static func expand(presetID: String, duration: Double) -> KeyframeSet?
}
```

V6 `AnimationMacro.expand(motionPreset:depthEffect:duration:)` 在 V7 内部重构为调用 `ImageAnimationPresetRegistry.expand`，保持外部接口签名不变。

### 2.4 Image3DPresetRegistry（V6 完整化）

```swift
public protocol Image3DPreset: VisualPreset {
    /// Expand into a multi-layer 2.5D parallax spec (foreground + background layers).
    func expand(
        imageURL: URL,
        depthData: DepthLayerData,
        duration: Double,
        intensity: Float
    ) -> [ImageLayerSpec]
}

public enum Image3DPresetRegistry {
    // 内置预设（对应 V6 image_3d 雏形）：
    // parallax_center / parallax_left / parallax_right / parallax_up / parallax_down / parallax_zoom

    public static func register(_ preset: any Image3DPreset)
    public static func preset(for id: String) -> (any Image3DPreset)?
}
```

---

## 三、注册表初始化（App Launch）

统一在一处完成四件注册（可放在 `TimelineKit.setup()` 静态方法中）：

```swift
public enum TimelineKit {
    /// Call once at app launch before creating any TimelineRenderer or ExportFrameProvider.
    public static func setup() {
        registerImageAnimationPresets()
        registerImage3DPresets()
        registerTransitionPresets()   // 见 transition-system-spec.md §6
    }

    private static func registerImageAnimationPresets() {
        ImageAnimationPresetRegistry.register(ZoomInAnimationPreset())
        ImageAnimationPresetRegistry.register(ZoomOutAnimationPreset())
        ImageAnimationPresetRegistry.register(PanLeftAnimationPreset())
        ImageAnimationPresetRegistry.register(PanRightAnimationPreset())
        ImageAnimationPresetRegistry.register(PanUpAnimationPreset())
        ImageAnimationPresetRegistry.register(PanDownAnimationPreset())
    }

    private static func registerImage3DPresets() {
        Image3DPresetRegistry.register(ParallaxCenterPreset())
        Image3DPresetRegistry.register(ParallaxLeftPreset())
        Image3DPresetRegistry.register(ParallaxRightPreset())
        Image3DPresetRegistry.register(ParallaxUpPreset())
        Image3DPresetRegistry.register(ParallaxDownPreset())
        Image3DPresetRegistry.register(ParallaxZoomPreset())
    }
}
```

---

## 四、TimelineTemplateConverter：服务端转场 → 客户端 TransitionSpec

### 4.1 职责

`TimelineTemplateConverter` 负责把服务端 timeline JSON 中的 `transition` 字段转换为客户端 `EditorTransition`，包括：

1. `type` / `name` 字符串 → `presetID` 查询
2. 不支持的 type → fallback 到 `crossFade` + 打日志
3. `duration` / `easing` / `direction` / `intensity` 字段透传

### 4.2 服务端转场数据格式（当前 + 规划）

**当前服务端格式**（`ServerTimelineSchema.swift` 中已有）：

```json
{
  "type": "dissolve",
  "duration": 0.5,
  "easing": "ease_in_out"
}
```

**V7 起服务端可能下发的扩展格式**（客户端需能消费）：

```json
{
  "type": "slide_left",
  "name": "左移",
  "duration": 0.4,
  "easing": "ease_in_out",
  "direction": "left",
  "intensity": 0.8
}
```

### 4.3 实现

**新增文件：`Sources/TimelineKit/Conversion/TimelineTemplateConverter.swift`**

```swift
/// Converts server-side timeline template fields to client EditorTransition.
public enum TimelineTemplateConverter {

    // MARK: - Transition

    public struct ServerTransitionPayload: Decodable {
        public let type: String?
        public let name: String?
        public let duration: Double?
        public let easing: String?
        public let direction: String?
        public let intensity: Float?
    }

    /// Convert a server transition payload to EditorTransition.
    /// Falls back to crossFade if the type is unknown.
    public static func transition(
        from payload: ServerTransitionPayload,
        leadingSegmentID: UUID,
        trailingSegmentID: UUID
    ) -> EditorTransition {
        let resolvedPresetID = resolvePresetID(type: payload.type, name: payload.name)
        let resolvedType     = editorTransitionType(presetID: resolvedPresetID)
        let resolvedEasing   = easing(from: payload.easing) ?? .easeInOut
        let resolvedDuration = (payload.duration ?? 0.5).clamped(0.2...3.0)
        let resolvedDirection = direction(from: payload.direction)

        return EditorTransition(
            type:               resolvedType,
            duration:           resolvedDuration,
            easing:             resolvedEasing,
            leadingSegmentID:   leadingSegmentID,
            trailingSegmentID:  trailingSegmentID,
            presetID:           resolvedPresetID,
            direction:          resolvedDirection,
            intensity:          payload.intensity
        )
    }

    // MARK: - Image Animation

    public struct ServerAnimationPayload: Decodable {
        public let type: String?           // e.g. "zoom_in", "pan_left"
        public let scaleFrom: Float?
        public let scaleTo: Float?
        public let translateXFrom: Float?
        public let opacityTo: Float?
    }

    /// Convert SImageAnimation fields to ImageAnimationPreset expand call.
    /// If type is recognized: expand via registry.
    /// If type is unrecognized: return default zoom_in expansion.
    public static func imageAnimationKeyframes(
        from payload: ServerAnimationPayload,
        duration: Double
    ) -> KeyframeSet? {
        let presetID = payload.type.flatMap { serverTypeToAnimationPresetID($0) } ?? "zoom_in"
        return ImageAnimationPresetRegistry.expand(presetID: presetID, duration: duration)
    }

    // MARK: - Private

    private static let serverTypeToPresetID: [String: String] = [
        "dissolve":        "crossFade",
        "fade":            "crossFade",
        "cross_fade":      "crossFade",
        "crossfade":       "crossFade",
        "fade_black":      "fadeThroughBlack",
        "fade_to_black":   "fadeThroughBlack",
        "slide_left":      "slideLeft",
        "slide_right":     "slideRight",
        "slide_up":        "slideUp",
        "slide_down":      "slideDown",
        "push_left":       "pushLeft",
        "push_right":      "pushRight",
        "zoom":            "zoomIn",
        "zoom_in":         "zoomIn",
        "zoom_out":        "zoomOut",
        "blur":            "blurFade",
        "blur_fade":       "blurFade",
        "wipe":            "wipeLeft",
        "wipe_left":       "wipeLeft",
        "wipe_right":      "wipeRight",
    ]

    private static func resolvePresetID(type: String?, name: String?) -> String {
        // 1. Try type string
        if let raw = type?.lowercased().replacingOccurrences(of: "-", with: "_") {
            if let mapped = serverTypeToPresetID[raw] {
                return mapped
            }
            // 2. Try direct presetID (server sends exact registered ID)
            if TransitionPresetRegistry.preset(for: raw) != nil {
                return raw
            }
        }
        // 3. Fallback
        print("[TimelineTemplateConverter] Unknown transition type='\(type ?? "nil")', fallback to crossFade")
        return "crossFade"
    }

    private static func editorTransitionType(presetID: String) -> EditorTransition.TransitionType {
        switch presetID {
        case "crossFade":        return .crossFade
        case "fadeThroughBlack": return .fadeThroughBlack
        case "slideLeft":        return .slideLeft
        case "slideRight":       return .slideRight
        case "pushLeft":         return .pushLeft
        case "pushRight":        return .pushRight
        case "zoomIn":           return .zoomIn
        case "blurFade":         return .blurFade
        default:                 return .crossFade
        }
    }

    private static func easing(from string: String?) -> EditorTransition.Easing? {
        switch string?.lowercased() {
        case "linear":                    return .linear
        case "ease_in", "easein":         return .easeIn
        case "ease_out", "easeout":       return .easeOut
        case "ease_in_out", "easeinout":  return .easeInOut
        default:                          return nil
        }
    }

    private static func direction(from string: String?) -> EditorTransition.Direction? {
        switch string?.lowercased() {
        case "left":  return .left
        case "right": return .right
        case "up":    return .up
        case "down":  return .down
        default:      return nil
        }
    }

    private static func serverTypeToAnimationPresetID(_ type: String) -> String? {
        let map: [String: String] = [
            "zoom_in":   "zoom_in",
            "zoom_out":  "zoom_out",
            "pan_left":  "pan_left",
            "pan_right": "pan_right",
            "pan_up":    "pan_up",
            "pan_down":  "pan_down",
        ]
        return map[type.lowercased()]
    }
}
```

### 4.4 TimelineImporter 集成

在 `Sources/TimelineKit/Conversion/TimelineImporter.swift` 的 transition 解码处，替换现有简单映射为 `TimelineTemplateConverter.transition(from:)`：

```swift
// 修改位置（当前 TimelineImporter 中处理 STransition 的代码）：
let transition = TimelineTemplateConverter.transition(
    from: TimelineTemplateConverter.ServerTransitionPayload(
        type:      sTransition.type,
        name:      sTransition.name,
        duration:  sTransition.duration,
        easing:    sTransition.easing,
        direction: sTransition.direction,
        intensity: sTransition.intensity
    ),
    leadingSegmentID:  leadingID,
    trailingSegmentID: trailingID
)
```

---

## 五、服务端 presetID 引用规范（建议）

V7 起，与服务端约定：timeline JSON 中的 transition 字段推荐使用 `presetID` 而非 `type` 字符串，以减少映射歧义：

```json
{
  "preset_id": "crossFade",    // 推荐：直接引用客户端已验证的 presetID
  "type": "dissolve",          // 保留：向后兼容，优先级低于 preset_id
  "duration": 0.5,
  "easing": "ease_in_out"
}
```

`TimelineTemplateConverter` 优先使用 `preset_id` 字段（如果存在），fallback 到 `type` 映射。

---

## 六、验收标准

| 验收项 | 标准 |
|---|---|
| 已知服务端 type 正确映射 | `"dissolve"` → `crossFade`；`"slide_left"` → `slideLeft`；`"blur"` → `blurFade` |
| 未知服务端 type 安全降级 | `"glitch"` → `crossFade` + `print("[TimelineTemplateConverter] Unknown...")`；不抛异常 |
| `preset_id` 优先于 `type` | 服务端同时给 `preset_id = "slideLeft"` 和 `type = "dissolve"` → 使用 slideLeft |
| `intensity / direction` 透传 | 服务端给 `intensity: 0.8` → `EditorTransition.intensity = 0.8` |
| ImageAnimationPresetRegistry.expand | `presetID = "zoom_in", duration = 3.0` → 返回合法 KeyframeSet（非 nil） |
| 未知 animation type fallback | `"ai_morph"` → `zoom_in` 默认展开，不崩溃 |
| 四件注册表 presetID 不重名 | TransitionPresetRegistry 与 ImageAnimationPresetRegistry 的 presetID 命名空间隔离（通过前缀或独立存储） |

---

## 七、V7 固定约束重申

> 见 [V7-initiation.md §八](V7-initiation.md)。实现本 spec 时须遵守：
> - **Preview 和 Export 禁止单独实现转场逻辑**
> - **服务端不认识的转场 fallback 到 crossFade + 打日志**
> - **注册表初始化必须在 `TimelineKit.setup()` 中一次性完成**，不允许延迟注册（防止渲染时 Registry 为空导致 fallback）
