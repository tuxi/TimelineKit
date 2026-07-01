# TimelineKit — 转换规范

## 总体流向

```
服务端 JSON
    ↓ TimelineImporter.importing(from: Data)
EditorTimeline（编辑器内部，不对外暴露格式细节）
    ↓ 用户编辑
EditorTimeline（修改后）
    ↓ DraftStore.save(_:)
本地可编辑草稿（EditorTimeline）
```

`TimelineExporter` 不再用于 App 本地草稿保存。它只用于上传服务端兼容 JSON、调试导出、分享/云同步摘要或旧接口兼容。App 本地可编辑草稿以 `EditorTimeline` 原样写入 `DraftStore`。

---

## Import：ServerTimelineSchema → EditorTimeline

### 场景 → 轨道映射

服务端把所有 layer 嵌套在 scene 里。Import 时把它们展开到对应轨道：

| layer type | z_index | → EditorTrack.kind |
|---|---|---|
| image_motion | < 0 | .overlay（背景模糊层） |
| image_motion | ≥ 0 | .video |
| image_3d | < 0 | .overlay |
| image_3d | ≥ 0 | .video |
| ai_video | 任意 | .video |
| text | ≥ 1 | .text |
| subtitle items | — | .subtitle |
| audio.voice | — | .audio（label = "配音"） |
| audio.bgm | — | .audio（label = "BGM"） |

### 关键时间转换

```
服务端 TextLayer:
  scene.start = 5.0
  layer.start_offset = 0.15
  layer.end_offset   = 2.92

EditorSegment.targetRange:
  start    = scene.start + start_offset = 5.15
  duration = end_offset - start_offset  = 2.77
```

场景级别的 `start` 和 `duration` 直接映射到该场景内 video/overlay segment 的 `targetRange`。

### 转场处理

```
服务端: scene.transition 是"进入本场景时"的转场
Import: 找到该场景的主内容 segment（currID）和上一场景的主内容 segment（prevID）
→ 创建 EditorTransition { leadingSegmentID: prevID, trailingSegmentID: currID }
→ 从 scene 数据中解耦，独立存储
```

### 素材创建规则

| Layer 类型 | EditorAsset.type |
|---|---|
| image_motion.src | .image |
| image_3d.src | .image |
| ai_video.video_url | .generatedVideo(provider, model) |
| audio.voice.url | .voiceOver |
| audio.bgm.url | .audio |
| text（无外部文件） | .placeholder |

---

## Export：EditorTimeline → ServerTimelineSchema

### 轨道 → 场景重组

```
1. 取 .video + .overlay track 的所有 segments
2. 按 sourceSceneID 分组
   - 有 sourceSceneID → 归回原场景
   - 无 sourceSceneID（新增 segment）→ 生成新场景 ID
3. 场景的 start = 组内 segment 的最早 targetRange.start
4. 场景的 duration = 组内 segment 的最大 targetRange.duration
5. .text segment 按 sourceSceneID 归回各场景，startOffset/endOffset 折叠回相对时间
```

### 关键时间逆转换

```
EditorSegment.targetRange:
  start = 5.15, duration = 2.77

所属 scene.start = 5.0

layer.start_offset = targetRange.start - scene.start = 0.15
layer.end_offset   = targetRange.end   - scene.start = 2.92
```

### 字幕处理

字幕 segment 的 `targetRange` 已经是绝对时间，直接输出为 `SSubtitleItem.start` / `.end`，不需要转换。

### 转场重建

```
EditorTransition { leadingSegmentID: A, trailingSegmentID: B }
→ 找到 B 对应的 scene
→ scene.transition = { type, duration, easing }
```

---

## 入口调用示例

### FeatureVideoGen → 打开编辑器

```swift
// 在 FeatureVideoGen 中（知道 VideoTimeline，但不依赖 EditorTimeline）
// 方案一：直接传 JSON Data（最解耦）
let jsonData = try JSONEncoder().encode(videoTimeline)  // 或直接用缓存的原始 JSON
let editorTimeline = try TimelineImporter.importing(from: jsonData, taskID: task.id)
let store = EditorStore(timeline: editorTimeline)

// 方案二：通过 ServerTimelineSchema（略有类型依赖）
let schema = ServerTimelineSchema(...)
let editorTimeline = TimelineImporter.importing(from: schema, taskID: task.id)
```

### 编辑完成 → 保存本地草稿

```swift
// ClipEditorView 的 onDraftSave 回调
ClipEditorView(store: store) { draftID, timeline in
    // 本地草稿保存 EditorTimeline，避免经过服务端 VideoTimeline 格式丢失本地编辑字段。
    Task {
        try await TimelineCache.shared.markDraftSaved(
            taskID: task.id,
            draftID: draftID,
            timeline: timeline
        )
    }
}
```

### 上传/兼容服务端 → 导出 JSON

```swift
// 仅当需要服务端兼容格式时使用 TimelineExporter。
let exportedJSON = try TimelineExporter.exportJSON(store.timeline)
```

---

## 注意事项

1. **round-trip 精度**：`Double` 浮点在 start_offset 计算时可能有微小误差（< 0.001s），可忽略。
2. **新增 segment 无 sourceSceneID**：Export 时生成合成场景 ID，不影响渲染。
3. **服务端格式版本**：`ServerTimelineSchema.version = "1.0"`，未来如有 breaking change 在 import 入口处加版本分支。
4. **AI 生成中的 segment**：`AssetType.placeholder` 在 export 时 src/videoURL 为空字符串，服务端渲染会跳过空素材。
