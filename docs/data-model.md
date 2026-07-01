# TimelineKit — 数据模型规范

## 顶层结构

```
EditorTimeline
├── canvas: EditorCanvas          // 画布尺寸
├── tracks: [EditorTrack]         // 所有轨道，按 zPosition 排序
├── materials: MaterialsPool      // 素材库 [UUID: EditorAsset]
├── transitions: [EditorTransition]  // 转场（独立存储）
└── metadata: EditorMetadata      // 来源信息
```

---

## 时间系统

**规则：所有时间都是从 timeline 起点（0.0）开始的绝对秒数。**

| 类型 | 时间类型 | 说明 |
|---|---|---|
| `EditorSegment.targetRange` | 绝对 | clip 在 timeline 上的位置 |
| `EditorSegment.sourceRange` | 绝对（源内） | 用源素材的哪段（trim） |
| `EditorTransition.duration` | 时长（非绝对） | 转场持续时间 |
| `Keyframe.time` | 绝对 | 关键帧触发时间 |

**服务端格式的 `start_offset` / `end_offset`（相对 scene.start）在 import 时展开为绝对时间，export 时折叠回相对格式。**

---

## EditorTrack

```swift
struct EditorTrack {
    let id: UUID
    var kind: Kind         // .video | .overlay | .text | .subtitle | .audio | .adjustment
    var label: String
    var isMuted: Bool
    var isLocked: Bool
    var isHidden: Bool
    var zPosition: Int     // 合成层级，越高越靠上
    var segments: [EditorSegment]  // 按 targetRange.start 排序
}
```

**轨道 kind 对应关系：**

| Kind | 服务端 layer type | z_index 范围 |
|---|---|---|
| `.overlay` | image_motion / image_3d with z < 0 | < 0 |
| `.video` | ai_video / image_motion with z ≥ 0 | 0 |
| `.text` | text | ≥ 1 |
| `.subtitle` | subtitle track items | 独立 |
| `.audio` | audio.bgm / audio.voice | 独立 |
| `.adjustment` | 未来：调色滤镜 | 特殊 |

---

## EditorSegment

```swift
struct EditorSegment {
    let id: UUID
    var materialID: UUID        // → MaterialsPool

    var sourceRange: TimeRange? // nil = 使用素材全部时长
    var targetRange: TimeRange  // 在 timeline 上的绝对位置

    var speed: Double           // 1.0 正常，0.5 慢放
    var transform: SegmentTransform
    var blendMode: BlendMode
    var keyframes: KeyframeSet
    var content: SegmentContent // 类型化内容

    var leadingTransitionID: UUID?   // 进入转场
    var trailingTransitionID: UUID?  // 退出转场

    // 服务端回写用
    var sourceSceneID: String?
    var sourceZIndex: Int?
}
```

### sourceRange vs targetRange

```
源素材（10秒视频）：
  |----0---------10----|
  
sourceRange = (2.0, 3.0)  → 使用 2~5 秒这段
       ↓
targetRange = (8.0, 3.0)  → 放在 timeline 的第 8~11 秒处

时间线：
  |----0---8---11----------|
            ↑↑↑↑↑ 这3秒播放源素材的2~5秒
```

---

## EditorAsset / MaterialsPool

```swift
struct EditorAsset {
    let id: UUID
    var type: AssetType
    var localURL: URL?     // 优先使用
    var remoteURL: URL?
    var nativeDuration: Double?
}

enum AssetType {
    case image
    case video
    case generatedVideo(provider: String, model: String)  // AI 生成视频
    case audio
    case voiceOver
    case placeholder  // AI 生成中，暂无 URL
}
```

**替换素材只需改 MaterialsPool 中的 asset.localURL 或 remoteURL，所有引用该 materialID 的 segment 自动生效。**

---

## SegmentContent

按轨道类型选择 case：

```swift
enum SegmentContent {
    case video(VideoContent)       // ai_video → .video track
    case image(ImageContent)       // image_motion / image_3d → .video or .overlay
    case text(TextContent)         // text layer → .text track
    case subtitle(SubtitleContent) // 字幕 → .subtitle track
    case audio(AudioContent)       // bgm/voice → .audio track
}
```

### TextContent（最常编辑的类型）

```swift
struct TextContent {
    var text: String                // 文字内容
    var style: TextStyle            // 字号/颜色/背景等
    var position: NormalizedPoint   // x,y 归一化 0-1
    var anchor: AnchorPoint         // center / top_left / ...
    var enterAnimation: TextAnimation?
    var exitAnimation: TextAnimation?
}
```

`position.x = 0.5, position.y = 0.15` 表示水平居中，距离顶部 15%。

---

## KeyframeSet

```swift
struct KeyframeSet {
    var opacity:  [Keyframe<Double>]
    var position: [Keyframe<NormalizedPoint>]
    var scale:    [Keyframe<Double>]
    var rotation: [Keyframe<Double>]   // 弧度
}

struct Keyframe<Value> {
    var time: Double    // 绝对秒
    var value: Value
    var easing: Easing  // linear / easeIn / easeOut / easeInOut
}
```

当 `keyframes.isEmpty` 时，使用 `SegmentTransform` 的静态值。关键帧和静态 transform 互斥。

---

## EditorTransition

```swift
struct EditorTransition {
    let id: UUID
    var type: TransitionType          // fade / slideLeft / zoom ...
    var duration: Double
    var easing: Easing
    var leadingSegmentID: UUID        // 转场前的 segment
    var trailingSegmentID: UUID       // 转场后的 segment
}
```

**转场不挂在 clip 上，单独存储。删除 clip 时检查并移除对应 transition，避免悬空引用。**

---

## EditorStore (状态管理)

```swift
@MainActor @Observable
class EditorStore {
    private(set) var timeline: EditorTimeline
    var selection: SelectionState

    // 所有修改必须通过 mutate()
    func mutate(_ label: String, _ body: (inout EditorTimeline) -> Void)
    func undo()
    func redo()

    // 便捷操作
    func deleteSegment(id: UUID)
    func trimSegment(id: UUID, newTargetRange: TimeRange)
    func moveSegment(id: UUID, to newStart: Double)
    func updateTextContent(segmentID: UUID, text: String)
    func updateTextPosition(segmentID: UUID, position: NormalizedPoint)
    func updateTextStyle(segmentID: UUID, style: TextStyle)
}
```

**Undo 实现：`EditorTimeline` 是 value type，每次 `mutate()` 前 copy 到 undoStack，undo 时整体还原。最多保留 50 步。**
