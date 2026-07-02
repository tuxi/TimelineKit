# TimelineKit V8 立项探索：本地可编辑 Timeline + UI/Agent 双入口

> 版本：v8.0
> 状态：探索定稿，待拆分 spec 执行
> 目标平台：iOS / macOS / 本地 CLI / MCP clients（Claude Code、Codex、端侧 code-agent）
> 依赖：V7 转场系统与 Animation Runtime 完成后进入主线；部分拆包准备可提前并行

---

## 一、立项背景

TimelineKit 最初从 DreamAI App 中拆出，当前 iOS 侧编辑器已经具备可用基础：相册素材导入、多轨 timeline、文字/字幕/音频、转场、预览、导出、草稿等能力都已经存在。

但仓库目前仍是单一 Swift Package target：

```text
TimelineKit
├── Models / Conversion / Animation      # 纯数据与算法，天然 Core
├── Rendering / Runtime / Export         # 渲染和导出，有 Apple 平台依赖
├── Store                                # 编辑状态，混合 Core mutation 与 UI 播放协调
└── Views                                # iOS SwiftUI/UIKit UI
```

这导致三个问题：

1. **macOS UI 难以独立开发**：`Views/` 与部分 `Rendering/` 使用 `UIKit` / `PhotosUI` / `Photos`，macOS 编译路径会遇到类型不可见和平台隔离问题。
2. **Core 无法作为工具层复用**：agent 或 CLI 想要使用 timeline 导入、修改、导出时，会被 UI 与 preview 状态拖进来。
3. **开源定位不够锋利**：如果只是一个 iOS 视频编辑器 demo，和现有 Swift/AVFoundation 项目差异有限；如果是 Apple 生态的可编辑 timeline 内核 + agent 工具层，差异明显。

V8 的目标是把 TimelineKit 明确升级为：

> **本地可编辑 timeline + iOS/macOS UI + CLI/MCP/Agent 双入口的 Apple 生态剪辑内核。**

---

## 二、竞品与开源生态调研

### 2.1 FFmpeg MCP 生态

GitHub 上已经有不少 FFmpeg MCP server：

| 项目 | Stars（调研时） | 语言 | 定位 |
|---|---:|---|---|
| [video-creator/ffmpeg-mcp](https://github.com/video-creator/ffmpeg-mcp) | 135 | Python | 本地视频搜索、裁切、拼接、overlay、concat 等 FFmpeg 工具 |
| [egoist/ffmpeg-mcp](https://github.com/egoist/ffmpeg-mcp) | 121 | TypeScript | FFmpeg MCP server |
| [misbahsy/video-audio-mcp](https://github.com/misbahsy/video-audio-mcp) | 82 | Python | 基础视频/音频编辑 |
| [KyaniteLabs/mcp-video](https://github.com/KyaniteLabs/mcp-video) | 61 | Python | guardrailed video editing MCP，FFmpeg + clips |
| [kevinwatt/ffmpeg-mcp-lite](https://github.com/kevinwatt/ffmpeg-mcp-lite) | 26 | Python | convert / compress / trim / subtitle |

结论：

- 这些项目验证了「agent 调本地视频工具」是成立需求。
- 它们大多是 FFmpeg 命令包装，强在转码、裁切、拼接、字幕烧录。
- 它们通常没有可编辑 timeline 草稿，也没有和移动端/桌面 UI 往返编辑的模型。

TimelineKit 不应重复做一个普通 FFmpeg MCP，而应提供更高层的 timeline 语义。

### 2.2 Swift / Apple 视频编辑生态

| 项目 | Stars（调研时） | 定位 |
|---|---:|---|
| [coderyi/YiVideoEditor](https://github.com/coderyi/YiVideoEditor) | 138 | Swift AVFoundation 视频处理库，旋转/裁剪/水印/音频 |
| [codewithhera/VideoEditTimeline-and-TrimView](https://github.com/codewithhera/VideoEditTimeline-and-TrimView) | 10 | UIKit timeline trim UI |
| [Asifnewaz/VideoEditorClaude](https://github.com/Asifnewaz/VideoEditorClaude) | 7 | iOS timeline editor demo |
| [vladimiraldushin/SilenceCut](https://github.com/vladimiraldushin/SilenceCut) | 2 | macOS 静音移除编辑器 |
| [OpenTimelineIO-AVFoundation](https://github.com/OpenTimelineIO/OpenTimelineIO-AVFoundation) | 38 | OTIO 与 CoreMedia/AVFoundation 转换兼容层 |

结论：

- Swift 生态存在若干视频处理库和 timeline UI demo，但多数不是完整可编辑 timeline 内核。
- `OpenTimelineIO-AVFoundation` 值得重点参考，未来 TimelineKit 可以支持 OTIO import/export，提升专业软件互操作性。
- 暂未看到成熟开源项目覆盖「Apple 原生 timeline core + iOS/macOS UI 分离 + agent/MCP 工具入口」这个组合。

### 2.3 通用视频编辑/程序化生成生态

| 项目 | Stars（调研时） | 定位 |
|---|---:|---|
| [Remotion](https://github.com/remotion-dev/remotion) | 51775 | React 程序化视频生成 |
| [LosslessCut](https://github.com/mifi/lossless-cut) | 41789 | lossless 视频/音频切割工具 |
| [MoviePy](https://github.com/Zulko/moviepy) | 14750 | Python 程序化视频编辑 |
| [Olive](https://github.com/olive-editor/olive) | 9070 | 开源非线性视频编辑器 |
| [OpenTimelineIO](https://github.com/AcademySoftwareFoundation/OpenTimelineIO) | 1909 | 剪辑 timeline 交换格式 |
| [MLT](https://github.com/mltframework/mlt) | 1804 | 多媒体框架 |
| [libopenshot](https://github.com/OpenShot/libopenshot) | 1526 | OpenShot 视频编辑库 |

结论：

- 通用视频编辑生态成熟，但多数不是 Apple 原生，也不面向 iOS/macOS 可嵌入 UI。
- TimelineKit 的差异化不应与这些项目比拼全功能 NLE，而应聚焦 Apple 平台、移动优先、可嵌入 SDK、agent 可控 timeline。

---

## 三、V8 目标

### 3.1 产品目标

V8 完成后，TimelineKit 应能被四类入口调用：

| 入口 | 用户 | 能力 |
|---|---|---|
| iOS UI | iPhone/iPad App 用户 | 手动剪辑、预览、导出、草稿 |
| macOS UI | Mac App 用户 | 桌面编辑、批量素材、agent 协同 |
| CLI | 开发者 / 自动化脚本 | 导入素材、生成 timeline、导出视频、检查草稿 |
| MCP | Claude Code / Codex / code-agent | 通过结构化工具调用创建/修改/渲染 timeline |

核心不是让 agent 直接生成一个 MP4，而是让 agent 生成或修改一个可继续编辑的 timeline。

### 3.2 技术目标

1. `TimelineKitCore` 可在 iOS/macOS 独立构建，不依赖 SwiftUI/UIKit/Photos。
2. `TimelineKitRender` 提供 headless 导出能力，不依赖编辑器 UI。
3. `TimelineKitUIiOS` 复用现有 `ClipEditorView`，保持当前 demo 可运行。
4. `TimelineKitUIMac` 预留 target，先提供最小壳，后续逐步实现 macOS timeline UI。
5. `timelinekit` CLI 使用 Core/Render，而不是重复实现剪辑逻辑。
6. `timelinekit-mcp` 包装 CLI 或直接链接 Core API，向 agent 暴露稳定 tool schema。

---

## 四、目标 Package 拆分

### 4.1 Target Graph

```text
TimelineKitCore
├── Models
├── Animation
├── Conversion
├── Pure timeline mutation helpers
└── Draft Codable schema

TimelineKitRender
├── depends on TimelineKitCore
├── Rendering
├── Runtime
├── Export core
├── Thumbnail / waveform / audio utilities
└── no SwiftUI/UIKit UI views

TimelineKitUIShared
├── depends on Core + Render
├── Editor session state
├── selection / undo / redo orchestration
└── platform-neutral protocols where possible

TimelineKitUIiOS
├── depends on UIShared + Render
├── existing SwiftUI/UIKit editor views
├── PhotosPicker integration
└── iOS demo

TimelineKitUIMac
├── depends on UIShared + Render
├── SwiftUI/AppKit editor shell
└── macOS demo (future)

TimelineKitCLI
└── executable target, depends on Core + Render

TimelineKitMCP
└── executable target, depends on CLI adapter or Core + Render
```

### 4.2 Product Graph

```swift
.library(name: "TimelineKitCore", targets: ["TimelineKitCore"])
.library(name: "TimelineKitRender", targets: ["TimelineKitRender"])
.library(name: "TimelineKitUIiOS", targets: ["TimelineKitUIiOS"])
.library(name: "TimelineKitUIMac", targets: ["TimelineKitUIMac"])
.library(name: "TimelineKit", targets: ["TimelineKit"]) // umbrella, compatibility
.executable(name: "timelinekit", targets: ["TimelineKitCLI"])
.executable(name: "timelinekit-mcp", targets: ["TimelineKitMCP"])
```

### 4.3 文件归属初稿

| 当前目录 | V8 归属 |
|---|---|
| `Models/` | `TimelineKitCore` |
| `Animation/` | `TimelineKitCore`（若直接依赖 CoreImage 的预设渲染部分下沉到 Render） |
| `Conversion/` | `TimelineKitCore` |
| `Persistence/DraftCodable.swift` | `TimelineKitCore` |
| `Persistence/DraftStore.swift` | `TimelineKitUIShared` 或 `TimelineKitCorePersistence`，取决于是否保留 app container 路径 |
| `Persistence/AssetDownloadManager.swift` | `TimelineKitRender` 或独立 `TimelineKitAssets` |
| `Rendering/` | `TimelineKitRender` |
| `Runtime/` | `TimelineKitRender`，但 `TimelineClock` 若依赖 `CADisplayLink` 应进 UIiOS |
| `Export/VideoExporter.swift` | 拆为 `TimelineExporterService`（Render）+ `PhotosSaveService`（UIiOS） |
| `Services/AudioExtractor.swift` | `TimelineKitRender` |
| `Services/AudioImporter.swift` | `TimelineKitRender` 或 CLI shared utility |
| `Services/TTSService.swift` | 平台能力 target，iOS/macOS 均可用但需隔离 AVSpeechSynthesizer 差异 |
| `Store/EditorStore.swift` | 拆分：Core mutation / UI session / playback coordinator |
| `Views/` | `TimelineKitUIiOS` |

---

## 五、Core 边界定义

`TimelineKitCore` 只允许依赖：

- `Foundation`
- `CoreGraphics`（用于尺寸、坐标）
- 可选：`CoreMedia`（若 TimeRange 未来要提供 CMTime bridge，但核心存储仍保持 Double seconds）

`TimelineKitCore` 禁止依赖：

- SwiftUI
- UIKit
- AppKit
- Photos / PhotosUI
- AVPlayer / AVAssetExportSession / AVAssetWriter
- FileManager app container 策略（可以定义协议，具体实现下沉）

Core 应提供：

```swift
public struct EditorTimeline: Codable, Sendable, Hashable
public struct EditorTrack: Codable, Sendable, Hashable
public struct EditorSegment: Codable, Sendable, Hashable
public enum TimelineImporter
public enum TimelineExporter
public enum TimelineMutation
public struct TimelineValidationReport
public struct TimelineSummary
```

Core 不提供：

- UI state
- playback state
- Photos 保存
- AVFoundation export
- UIKit/AppKit view

---

## 六、CLI 设计

### 6.1 CLI MVP

命令名：`timelinekit`

```bash
timelinekit inspect input.timeline.json
timelinekit import-media a.mov b.jpg --output draft.timelinekit.json
timelinekit export-json draft.timelinekit.json --output server-timeline.json
timelinekit render draft.timelinekit.json --output out.mp4 --resolution 1080p --fps 30
timelinekit thumbnail draft.timelinekit.json --time 3.2 --output thumb.png
timelinekit waveform input.m4a --output waveform.json
timelinekit validate draft.timelinekit.json
```

### 6.2 CLI 输出规则

- 默认 stdout 输出结构化 JSON，便于 agent 读取。
- 进度写 stderr，避免污染 JSON。
- 所有文件路径必须是绝对路径或相对当前工作目录的安全路径。
- 所有命令返回 `TimelineKitError` 的稳定 code。

示例：

```json
{
  "ok": true,
  "timelineID": "A1B2...",
  "duration": 12.4,
  "tracks": 3,
  "output": "/path/to/out.mp4"
}
```

---

## 七、MCP 设计

### 7.1 MCP 定位

`timelinekit-mcp` 不直接暴露底层任意命令，而是暴露少量稳定工具。agent 负责意图规划，TimelineKit 负责安全执行和 timeline 状态管理。

首批工具：

| Tool | 输入 | 输出 |
|---|---|---|
| `timelinekit.inspect` | timeline path / media path | timeline summary / media metadata |
| `timelinekit.import_media` | media URLs, canvas, image duration | draft timeline path + summary |
| `timelinekit.apply_edits` | timeline path + edit operations JSON | new timeline path + diff summary |
| `timelinekit.render` | timeline path + export config | mp4 path + render summary |
| `timelinekit.thumbnail` | timeline path + time | image path |
| `timelinekit.validate` | timeline path | validation report |

### 7.2 Agent 工作流示例

用户：

> 把这 5 个商品视频剪成 30 秒短视频，加标题字幕，开头 2 秒做封面动效，导出 1080p。

Agent：

1. 调 `timelinekit.import_media` 创建草稿。
2. 调 `timelinekit.apply_edits` 添加文本轨、字幕轨、转场、动画。
3. 调 `timelinekit.validate` 检查素材缺失、重叠、越界。
4. 调 `timelinekit.render` 导出 MP4。
5. 用户如果不满意，可打开 iOS/macOS UI 继续编辑同一个 timeline 草稿。

这就是 TimelineKit 与普通 FFmpeg MCP 的关键区别：MP4 只是结果，timeline 才是可持续编辑资产。

### 7.3 安全边界

MCP server 必须默认本地安全：

- 限制可访问 workspace roots。
- 禁止任意 shell。
- 禁止覆盖输入文件，输出必须写到指定 output 或工作目录。
- 大文件操作必须返回进度。
- 渲染任务支持取消。
- 默认不访问网络；远程 URL 下载必须显式开关。

---

## 八、与 OpenTimelineIO 的关系

V8 不把 OTIO 作为 P0 依赖，但建议进入 roadmap：

| 能力 | 阶段 |
|---|---|
| `EditorTimeline -> OTIO` export | V8 P2 |
| `OTIO -> EditorTimeline` basic import | V8 P2 |
| Final Cut / Premiere / Resolve 互操作 | V9+ |

原因：

- OTIO 是行业 timeline 交换格式，适合开源生态。
- TimelineKit 当前模型更偏移动短视频编辑，不能被 OTIO 完全覆盖。
- 最优方案是 Core 保持 `EditorTimeline`，提供 OTIO bridge，而不是把内部模型改成 OTIO。

---

## 九、里程碑

### M1：拆包设计与 target skeleton

交付：

- `Package.swift` 新增 target graph。
- 所有 target 为空壳可 build。
- umbrella `TimelineKit` 保持兼容。

验收：

- `swift build --target TimelineKitCore` 通过。
- `xcodebuild ... VideoEditorDemo` 继续通过。

### M2：Core 独立

交付：

- `Models/`, `Conversion/`, 纯 `Animation/` 迁入 Core。
- Core 不含 SwiftUI/UIKit/Photos/AVPlayer。
- 新增 `TimelineSummary` / `TimelineValidationReport`。

验收：

- Core 在 macOS/iOS 均可 build。
- Core 单元测试覆盖 import/export roundtrip。

### M3：Render 独立

交付：

- 渲染、导出、缩略图、波形迁入 Render。
- `VideoExporter` 拆分为 headless render service + Photos save adapter。

验收：

- macOS CLI 可导出无 UI MP4。
- iOS demo 导出行为不回退。

### M4：iOS UI 迁移

交付：

- `Views/` 迁入 `TimelineKitUIiOS`。
- `EditorStore` 拆出 Core mutation 与 UI session。
- iOS demo 依赖 `TimelineKitUIiOS`。

验收：

- iOS demo 可相册导入、编辑、导出。
- 旧 public API 有迁移说明。

### M5：CLI MVP

交付：

- `timelinekit` executable target。
- `inspect / import-media / validate / render / thumbnail` 首批命令。

验收：

- CLI 可从本地素材生成 timeline 并导出 MP4。
- stdout JSON 稳定，适合 agent 消费。

### M6：MCP MVP

交付：

- `timelinekit-mcp` executable target。
- 首批 MCP tools：inspect / import_media / apply_edits / render / validate。

验收：

- Claude Code / Codex 可配置启动 MCP。
- 端侧 code-agent 可通过同一 schema 调用。
- 复杂失败可返回可读 validation error，而不是崩溃。

### M7：macOS UI 壳

交付：

- `TimelineKitUIMac` 最小 demo。
- 打开本地 timeline、预览、基础轨道列表。

验收：

- macOS app 可打开 CLI/MCP 生成的 timeline。
- iOS/macOS 草稿 roundtrip 一致。

---

## 十、风险与应对

| 风险 | 影响 | 应对 |
|---|---|---|
| 拆包过大，影响现有 iOS UI | iOS demo 断裂 | 先建 target skeleton，再逐目录迁移；每步跑 iOS demo build |
| `EditorStore` 过度耦合播放/渲染/UI | Core 无法干净独立 | 拆成 `TimelineDocument` / `EditorSession` / `PlaybackCoordinator` |
| Render 仍依赖 UIKit 图像类型 | macOS headless render 失败 | 把 `UIImage` adapter 下沉到 UIiOS，Render 内部统一 `CGImage/CIImage` |
| MCP tool 太多太散 | agent 难用且不稳定 | 首批只做 6 个高层工具，复杂编辑走 `apply_edits` JSON |
| 直接对标专业 NLE 范围失控 | 周期失控 | V8 只做架构与工具入口，不做新特效 |
| FFmpeg MCP 已经很多 | 开源差异不明显 | 明确定位为可编辑 timeline 内核，而不是 FFmpeg wrapper |

---

## 十一、非目标

V8 不做：

- 不重写整个渲染引擎。
- 不一次性实现完整 macOS 专业剪辑 UI。
- 不把内部模型替换为 OTIO。
- 不做云端渲染。
- 不做任意 FFmpeg shell 代理。
- 不新增新的视觉特效大版本。

---

## 十二、最终验收标准

V8 完成时应满足：

1. `TimelineKitCore` 可独立在 macOS/iOS 构建。
2. `TimelineKitRender` 可在无 UI 场景导出视频。
3. iOS demo 能继续完成相册导入、编辑、导出。
4. CLI 能从素材生成 timeline、校验、渲染。
5. MCP server 能被 Claude Code / Codex / 端侧 code-agent 调用。
6. CLI/MCP 生成的 timeline 能被 iOS UI 打开继续编辑。
7. README 明确 TimelineKit 的新定位：Apple 生态可编辑 timeline 内核 + UI/agent 双入口。

