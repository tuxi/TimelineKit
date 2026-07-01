# TimelineKit

TimelineKit 是一个用于构建 iOS 优先视频时间线编辑器的 Swift Package。它包含值类型剪辑模型、带 undo/redo 的可观察状态容器、SwiftUI/UIKit 编辑界面、时间线导入导出、本地草稿持久化，以及基于 AVFoundation/Core Image 的预览与导出管线。

[English README](README.md)

## 当前状态

TimelineKit 是从 DreamAI App（早期代码中也出现 DreamLog/Dreamlog 命名）拆分出来的全新独立 Git 仓库，目前正在整理成可独立使用的开源包。

- 当前包声明：Swift tools 6.2，iOS 18+，macOS 15+。
- 编辑器 UI 和视频导出流程主要面向 iOS。
- 模型、转换、动画、持久化等模块按可复用包内核来组织。
- 目前还没有测试 target。

## 包含能力

- **标准时间线模型**：`EditorTimeline`、`EditorTrack`、`EditorSegment`、`EditorAsset`、`EditorTransition`、`TimeRange`、`KeyframeSet`，以及 video/image/text/subtitle/audio 等类型化片段内容。
- **编辑状态容器**：`EditorStore` 是 `@Observable` 的 main-actor store，负责时间线修改、选择状态、播放协调、undo/redo、裁剪、移动、分割、文字编辑、音频控制、转场、导出参数等。
- **编辑器界面**：`ClipEditorView` 使用 SwiftUI 承载预览和控制区，使用 UIKit 轨道画布处理高密度时间线手势。
- **导入导出转换**：`TimelineImporter` 和 `TimelineExporter` 负责在 `ServerTimelineSchema` JSON 与可编辑的 `EditorTimeline` 之间转换。
- **预览与渲染**：渲染层包含 composition 构建、图层解析、图片/视频/文字渲染、转场和运行时预览。
- **视频导出**：`VideoExporter` 可以把 `EditorTimeline` 导出为 MP4，支持分辨率、帧率、码率档位和 HDR 降级处理。
- **草稿持久化**：`DraftStore` 保存本地可编辑时间线，并在下次打开时恢复可移植素材 URL。
- **音频工具**：包含音频导入、音频分离、波形生成和本地 TTS 支持。

## 架构概览

TimelineKit 围绕一个标准内存模型构建：

```text
EditorTimeline
├── canvas: EditorCanvas
├── tracks: [EditorTrack]
├── materials: MaterialsPool
├── transitions: [EditorTransition]
└── metadata: EditorMetadata
```

核心设计规则：

- 所有时间都是从时间线起点开始计算的绝对秒数。
- 素材放在 `MaterialsPool`，轨道和片段只通过 UUID 引用素材。
- 转场是独立对象，不直接嵌在 clip 里。
- `EditorTimeline` 是纯值类型，因此 undo/redo 可以通过整份 timeline 快照恢复。
- 关键帧是主要动画表达；预设只是便捷输入，可展开为关键帧数据。

## 目录说明

```text
Sources/TimelineKit/
├── Animation/      动画预设、宏展开、缓动、关键帧求值
├── Conversion/     服务端 JSON schema 与导入导出转换
├── Export/         MP4 导出流程
├── Models/         时间线、轨道、片段、素材、画布、转场
├── Persistence/    草稿存储和素材下载/缓存
├── Rendering/      Composition builder、compositor、provider、runtime 组件
├── Runtime/        图层解析、时间线时钟、运行时渲染器
├── Services/       音频导入/分离和 TTS
├── Store/          EditorStore 与编辑 mutation API
└── Views/          SwiftUI/UIKit 编辑界面
```

设计说明和版本规格文档在 [`docs/`](docs/) 目录。建议先看：

- [`docs/architecture.md`](docs/architecture.md)
- [`docs/data-model.md`](docs/data-model.md)
- [`docs/conversion-spec.md`](docs/conversion-spec.md)
- [`docs/README.md`](docs/README.md)

## 环境要求

- Swift 6.2+
- 带 iOS 18 SDK / macOS 15 SDK 的 Xcode
- Apple 平台能力：AVFoundation、Core Image、SwiftUI、Observation、Photos

## 安装

包发布后，可以通过 Swift Package Manager 引入：

```swift
.package(url: "https://github.com/<owner>/TimelineKit.git", branch: "main")
```

然后在 target 中添加 product：

```swift
.product(name: "TimelineKit", package: "TimelineKit")
```

本地开发时，可以打开包目录或示例工程：

```text
TimelineKit/
Examples/VideoEditorDemo/VideoEditorDemo.xcodeproj
```

示例 App 支持从系统相册选择图片或视频，并通过
`TimelineImporter.importingMedia(from:)` 打开编辑器。

## 快速开始

把服务端时间线 JSON 导入为可编辑模型：

```swift
import TimelineKit

let timeline = try TimelineImporter.importing(from: jsonData, taskID: taskID)
let draftID = DraftStore.save(timeline)
let store = EditorStore(timeline: timeline)
```

在 iOS SwiftUI App 中打开编辑器：

```swift
ClipEditorView(store: store) { draftID, timeline in
    // 在你的 App 中保存 draftID，或同步编辑后的 timeline。
}
```

恢复本地草稿：

```swift
if let restored = DraftStore.load(draftID: draftID) {
    let store = EditorStore(timeline: restored)
}
```

执行可撤销编辑：

```swift
store.updateTextContent(segmentID: textSegmentID, text: "New title")
store.trimSegment(
    id: clipID,
    newTargetRange: TimeRange(start: 2.0, duration: 4.0)
)
store.undo()
```

把本地素材导入为一个简单时间线：

```swift
let timeline = try await TimelineImporter.importingMedia(
    from: mediaURLs,
    canvas: EditorCanvas(width: 720, height: 1280, fps: 30),
    imageDuration: 3
)
```

导出视频：

```swift
let exporter = VideoExporter()
await exporter.export(timeline: store.timeline)

if let url = exporter.savedVideoURL {
    // 使用导出的 MP4 文件 URL。
}
```

## 时间线 JSON 转换

TimelineKit 在 `ServerTimelineSchema` 中提供了服务端时间线格式的 Codable 镜像。导入器会把该 schema 规范化为编辑模型：

- 把 scene 内的相对 offset 展开为绝对 `TimeRange`；
- 按图层类型和 zIndex 分配到 video、overlay、text、subtitle、audio 轨道；
- 把转场从 clip 中拆出来作为独立对象保存；
- 把 BGM 和配音导入到音频轨；
- 保留来源元信息，便于后续导出或调试。

需要把编辑后的时间线重新序列化为服务端/调试 schema 时，可以使用 `TimelineExporter`。

## 当前限制

- 部分历史文档中还保留 DreamAI/DreamLog 接入背景。
- 文档和版本规格很丰富，但目前没有自动化测试 target。
- `VideoExporter` 和 `ClipEditorView` 主要用于 iOS App 集成。

## 许可证

TimelineKit 使用 MIT License。见 [LICENSE](LICENSE)。
