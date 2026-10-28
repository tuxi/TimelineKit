# 素材优先创建、空白项目与自动画布

- 日期：2026-10-26
- 状态：公共规则和 iOS 项目浏览入口已实现；完整 PhotosPicker 点击流程待复验
- 范围：TimelineKit 公共导入 / 项目 API、iOS `ProjectBrowserView` 与共享预览

## 产品行为

iPhone 默认点击“新建项目”先选择视频或照片，选择完成后创建并直接进入编辑器。“更多创建方式”菜单保留“创建空白项目”，空列表也直接展示两条入口。

- 素材优先：保留选择顺序，由第一个可读取的主轨图片 / 视频确定画布。
- 空白项目：持久化“等待首个视觉素材”状态；预览提示自动设置比例，首次主轨素材导入后定型。
- 批量导入：后续片段数量不阻止首素材定型，音频、文字和 overlay 不消耗主轨画布决策。
- 指定时间插入和替换未读成功的首素材也使用同一规则。
- 图片按 EXIF 显示方向读取，视频应用 `preferredTransform`；画布尺寸偶数化。
- 图片保留现有 fps，视频读取 nominal fps；后续素材不改变已确定画布。
- 用户或宿主明确指定的画布保持固定。删除所有素材、保存和重开不重置已经确定的画布。
- 取消选择不创建项目；全部素材不可读取时报告错误，不保存空项目。

这里的项目画布方向与设备横竖屏、工作区布局独立。导出规格继续使用现有配置机制。

## 共享实现

`EditorMetadata.canvasSizingMode` 是可选持久化字段：

| 值 | 含义 |
|---|---|
| `.automatic` | 等待首个可读取的主轨视觉素材 |
| `.fixed` | 已按素材定型，或由宿主 / 用户明确指定 |
| `nil` | 旧数据；已有内容保持原画布，旧空草稿兼容首次添加的自动行为 |

旧 JSON 缺少该字段时仍可读取。旧的非空项目经常规删除清空时保存固定状态，以免重开后误当成新空项目。

`MediaCanvasResolver` 供 `TimelineImporter` 与 `EditorStore` 共用。同步添加接口保持可调用，内部按入队顺序异步读取尺寸；不再以片段总数判断是否可以设置画布。写回前验证项目、片段 / 素材身份和原始画布，手动设置不会被晚到的读取结果覆盖。

异步定型通过 `TimelineDocument.resolveAutomaticCanvas` 合并到导入操作的历史中：包含同一参考素材 ID 和 URL 的历史快照获得同样画布，导入前及替换前的快照保持原状态，不额外增加“调整画布”撤销步骤。

## 宿主接入

### 选择素材后创建

先将 PhotosPicker 的有序选择加载成 URL，再调用库 API；媒体会复制进 `.tlkbundle/Media`，返回的项目已经完成画布设置和持久化。

```swift
let project = try await libraryStore.createProject(
    name: "新项目",
    mediaURLs: selectedURLs
)
let editorStore = EditorStore(timeline: project.timeline)
```

### 创建空白项目

```swift
let project = try libraryStore.createProject(name: "空白项目")
let editorStore = EditorStore(timeline: project.timeline)
editorStore.addVisualSegment(localURL: firstURL, nativeDuration: duration)
await editorStore.waitForAutomaticCanvasResolution()
```

批量添加全部素材后，在主动保存或生成依赖 timeline version 的 Agent 计划前等待 `waitForAutomaticCanvasResolution()`，确保画布及版本已经稳定。普通编辑器继续支持后台解析；未解析完成的项目会保留 `.automatic`，再次打开时恢复解析。

### 宿主明确指定画布

```swift
let project = try libraryStore.createProject(
    name: "方形项目",
    canvas: EditorCanvas(width: 1080, height: 1080, fps: 30)
)
// 已打开编辑器中手动设置，后续素材不会覆盖。
editorStore.setCanvas(EditorCanvas.Preset.portrait_9_16.canvas)
```

直接导入同样支持两种语义：

```swift
let automatic = try await TimelineImporter.importingMedia(from: urls)
let fixed = try await TimelineImporter.importingMedia(
    from: urls,
    canvas: EditorCanvas.Preset.portrait_9_16.canvas
)
```

直接构造时间线时，可在 `EditorMetadata` 中显式设置 `canvasSizingMode`。旧的已编辑时间线不会因升级而自动重新构图。

## DreamLog 对接观察

已只读核对 `../DreamLog`，该工程当前引用兄弟目录的 TimelineKit。本轮未修改 DreamLog 文件。

- `Projects/ProjectEditorView.swift` 的源视频导入省略 `canvas`，可采用新的首素材自动设置。
- 同一文件的无源视频路径会创建空时间线；旧空草稿继续兼容首次主轨视觉素材自动设置。新的宿主创建代码建议显式使用 `.automatic`。
- `Editor/AgentEditing/AgentEditingEditorView.swift` 显式调用 `canvas: timelineCanvas()`，按照项目源视频尺寸计算目标比例。本库尊重该值；如宿主希望完全自动，应省略 `canvas`，不应传入一个占位尺寸。
- 从模板或服务端导入的既有成片画布应维持固定设置。

DreamLog 的草稿 / Agent 持久化与迁移流程本轮未做 App 构建或设备验收。公共 API 的两个创建入口、显式画布和库持久化在本库测试中验证。

## 验证与限制

`AutomaticCanvasTests` 覆盖批量顺序、音频 / overlay、插入 / 替换、手动设置优先、撤销 / 重做、解析期间撤销、删除全部后重开、空项目和解析中的项目重开、库内媒体副本、非法选择、EXIF 方向、实际旋转视频以及旧数据兼容。

- `swift test` 全量 125 个用例通过，其中自动画布回归 16 个。
- iOS Demo Debug 模拟器构建通过。
- Duo 模拟器轨道生命周期回归 8 个通过。

本轮已构建新版 iOS Demo，并在 iPhone 17 Pro 模拟器看到项目列表中的新建和更多入口。Device Hub 后续点击遇到 `noWindowsAvailable` / ScreenCaptureKit `-3811` 错误，PhotosPicker 选择、取消、创建后自动导航这条完整 UI 流程尚未完成运行时验收，不能以编译和公共 API 测试代替。

复跑公共规则：

```sh
swift test --filter AutomaticCanvasTests
swift test
```
