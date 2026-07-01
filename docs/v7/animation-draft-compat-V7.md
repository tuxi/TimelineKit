# V7 Animation Runtime：DraftStore 集成与 Importer 边界

> 版本：v7.1
> 状态：规范定稿
> 优先级：P0（与 animation-runtime-V7.md Am1 同步落地）
> 依赖：
>   - [animation-runtime-V7.md](animation-runtime-V7.md)（ClipAnimation 数据模型）
>   - docs/timeline-draft-store-unification-plan.md（DraftStore 归一化前提）

---

## 一、背景

动画字段是 V7 Animation Runtime 的持久化边界。草稿中保存的是：

- `AnimationSemantic`（稳定语义，不是 presetID）
- `duration`（秒）
- 可选的 `direction` / `intensity`

**不保存** baked keyframe（这是 Premiere/FCP 的策略，对 AI 场景不适用）。

---

## 二、EditorSegment 新增字段的 Codable 实现

### 2.1 CodingKeys 变更

```swift
// EditorSegment.swift
private enum CodingKeys: String, CodingKey {
    case id, materialID, sourceRange, targetRange, speed, transform
    case blendMode, keyframes, content
    case leadingTransitionID, trailingTransitionID
    case adjustment, sourceSceneID, sourceZIndex
    case userZOrder
    case animations  // ← V7 新增（必须加到 encode / decode 两处）
}
```

### 2.2 init(from decoder:) 变更

```swift
// 在已有字段解码之后追加（decodeIfPresent，旧草稿 nil → []）
self.animations = try c.decodeIfPresent([ClipAnimation].self, forKey: .animations) ?? []
```

### 2.3 encode(to encoder:) 变更

```swift
// 在 EditorSegment 的 encode 中追加
if !animations.isEmpty {
    try c.encode(animations, forKey: .animations)
}
// 注意：animations 为空时不写入字段，保持草稿体积最小
```

### 2.4 ClipAnimation 完整 Codable 实现

```swift
extension ClipAnimation: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, semantic, timing, duration, direction, intensity
    }

    public init(from decoder: Decoder) throws {
        let c         = try decoder.container(keyedBy: CodingKeys.self)
        self.id        = try c.decode(UUID.self,               forKey: .id)
        self.semantic  = try c.decode(AnimationSemantic.self,  forKey: .semantic)
        self.timing    = try c.decode(AnimationTiming.self,    forKey: .timing)
        self.duration  = try c.decode(Double.self,             forKey: .duration)
        self.direction = try c.decodeIfPresent(AnimationDirection.self, forKey: .direction)
        self.intensity = try c.decodeIfPresent(Float.self,              forKey: .intensity)
    }
}
```

---

## 三、向下兼容规则

| 草稿版本 | `animations` 字段 | 加载结果 |
|---|---|---|
| v1-v6 旧草稿 | 不存在 | `decodeIfPresent` → nil → `[]` → 无动画 |
| V7 新草稿（有动画）| `[ClipAnimation, ...]` | 正常解码 |
| V7 新草稿（无动画）| 字段不写入 | `decodeIfPresent` → nil → `[]` |

**兼容承诺：**
- 旧草稿 100% 正常加载，行为与 V6 完全一致
- `animationPresetID`（旧 ImageContent 字段，如有）保持原有解码路径，不影响新 `animations` 字段

---

## 四、ImageContent.animationPresetID 迁移策略（M6）

当前 `SegmentContent.image(ImageContent)` 中有 `animationPresetID: String?` 字段，对应 `ImageAnimationPreset`。

**M6 迁移路径：**

```
旧草稿 animationPresetID = "slow_zoom_in"
          ↓ V7 DraftStore load
ImageAnimationPreset.slowZoomIn
          ↓ legacyToAnimationSemantic(preset:)
AnimationSemantic.slowZoom  （timing = .combo）
          ↓ 写入 EditorSegment.animations
ClipAnimation(semantic: .slowZoom, timing: .combo, duration: segment.duration)
```

迁移函数（M6 实现，Phase 1 暂不需要）：

```swift
// 在 DraftStore.load 或专用 migration 函数中调用
private static func migrateLegacyAnimation(_ segment: inout EditorSegment) {
    guard segment.animations.isEmpty else { return }  // 已有新字段，跳过

    if case .image(let content) = segment.content,
       let oldPresetID = content.animationPresetID,
       let oldPreset = ImageAnimationPreset(rawValue: oldPresetID) {

        if let semantic = oldPreset.animationSemantic {
            let anim = ClipAnimation(
                semantic: semantic,
                timing: .combo,
                duration: segment.targetRange.duration
            )
            segment.animations = [anim]
        }
    }
}

extension ImageAnimationPreset {
    var animationSemantic: AnimationSemantic? {
        switch self {
        case .none:           return nil
        case .slowZoomIn:     return .slowZoom
        case .slowZoomOut:    return .slowZoom        // 方向反，M6 通过 direction 区分
        case .panLeft:        return .drift
        case .panRight:       return .drift
        case .panUp:          return .drift
        case .panDown:        return .drift
        case .gentlePush:     return .slowZoom
        case .gentlePullBack: return .slowZoom
        case .depthPush:      return .depthPush
        case .depthPull:      return .depthPull
        case .depthPanLeft:   return .depthPanLeft
        case .depthPanRight:  return .depthPanRight
        case .depthPanUp:     return .drift
        case .depthPanDown:   return .drift
        case .depthOrbitLeft: return .depthPanLeft
        case .depthOrbitRight: return .depthPanRight
        }
    }
}
```

---

## 五、TimelineImporter 动画字段解码

### 5.1 服务端动画字段定义（SAnimation）

服务端 `ServerTimelineSchema.swift` 新增：

```swift
// ServerTimelineSchema.swift
struct SAnimation: Decodable, Sendable {
    let type: String
    let timing: String?       // "in" / "out" / "combo"；nil → 按 type 名称推断
    let duration: Double?     // 秒；nil → 使用 preset 默认时长（0.5s for in/out）
    let direction: String?    // "left" / "right" / "up" / "down"
    let intensity: Float?
}

struct SSegment: Decodable, Sendable {
    // ... 原有字段 ...
    let animations: [SAnimation]?   // ← V7 新增（optional，旧服务端不传）
    // 兼容：旧字段 imageAnimation / imageMotion / camera 继续保留直到 M6 清理
}
```

### 5.2 TimelineImporter 动画解码逻辑

```swift
// TimelineImporter.swift — importSegment 函数内追加

func importAnimations(from sSegment: SSegment, segmentDuration: Double) -> [ClipAnimation] {
    guard let sAnimations = sSegment.animations, !sAnimations.isEmpty else {
        return legacyAnimationFallback(sSegment: sSegment, segmentDuration: segmentDuration)
    }

    var result: [ClipAnimation] = []
    for sAnim in sAnimations {
        let rawTiming = sAnim.timing ?? inferTiming(from: sAnim.type)
        guard let timing = AnimationTiming(rawValue: rawTiming) else {
            print("[TimelineImporter] Unknown animation timing '\(rawTiming)', skipping")
            continue
        }
        let semantic = AnimationSemantic.from(
            serverType: sAnim.type,
            timing: timing,
            direction: sAnim.direction
        )
        let duration = sAnim.duration ?? defaultDuration(for: timing, segmentDuration: segmentDuration)
        result.append(ClipAnimation(
            semantic: semantic,
            timing: timing,
            duration: duration,
            direction: sAnim.direction.flatMap(AnimationDirection.init),
            intensity: sAnim.intensity
        ))
    }
    return result
}

/// 旧服务端字段（image_3d / image_motion / camera）的迁移映射（M6 清理前兼容）
private func legacyAnimationFallback(sSegment: SSegment, segmentDuration: Double) -> [ClipAnimation] {
    // 现有的 imageAnimation / image_3d 映射逻辑保持不变（不动现有代码）
    // M6 后此函数清空
    return []
}

private func inferTiming(from type: String) -> String {
    let t = type.lowercased()
    if t.contains("_in") || t.hasPrefix("fade_in") || t.hasPrefix("slide_in") { return "in" }
    if t.contains("_out") || t.hasPrefix("fade_out") || t.hasPrefix("slide_out") { return "out" }
    return "combo"
}

private func defaultDuration(for timing: AnimationTiming, segmentDuration: Double) -> Double {
    switch timing {
    case .in, .out: return min(0.5, segmentDuration * 0.4)
    case .combo:    return segmentDuration
    }
}
```

### 5.3 未知类型 fallback 规则

| 场景 | 行为 |
|---|---|
| 未知 `type`（如 `"glitch_in"`）| `AnimationSemantic.from` 返回 `.unknown`；fallback 到 `fadeIn`/`fadeOut`；打日志 |
| 未知 `timing`（如 `"loop"`）| 跳过该动画条目；打日志 |
| `duration` <= 0 或 nil | 使用默认时长（0.5s for in/out，segDuration for combo）|
| `animations` 为 nil | 走 `legacyAnimationFallback`（M6 前兼容路径）|

---

## 六、DraftStore 保存/加载验证清单

| 验收项 | 标准 |
|---|---|
| 旧草稿（v1-v6）加载 | `animations` 字段缺失 → 空数组 → 行为与 V6 一致 |
| 新草稿有动画 | `animations` 字段存在且可正确解码 |
| 新草稿无动画 | `animations` 字段不写入（节省体积）|
| 循环 encode-decode | 写入再读回，所有字段一致（round-trip 验证）|
| AnimationSemantic 未知 case | `decodeIfPresent` 返回 nil（旧版 app 加载新语义）→ 降级为无动画 |
| 草稿大小 | 每个 ClipAnimation 约 +100 bytes；100 个 segment 最多 +10KB，可接受 |

---

## 七、与 DraftStore 归一化计划的关系

`docs/timeline-draft-store-unification-plan.md` 正在推进 DraftStore 归一化。Animation Runtime 的字段设计已考虑与之兼容：

- `ClipAnimation` 是 `EditorSegment` 的内联字段，不是独立 DraftStore 实体
- 当 DraftStore 归一化完成后，`EditorTimeline.encode / decode` 路径统一，`ClipAnimation` 自动受益
- **依赖顺序**：DraftStore 归一化不需要完成才能开始 Animation Runtime；但 DraftStore 归一化后，Animation Runtime 字段的持久化路径会更稳定

---

## 八、不在本文范围

- keyframe 动画的持久化（由现有 `KeyframeSet` 处理，不改动）
- 转场数据的持久化（见 V7-initiation.md §3.2）
- `SegmentContent.image.animationPresetID` 字段的物理删除（M6 清理时单独执行）
