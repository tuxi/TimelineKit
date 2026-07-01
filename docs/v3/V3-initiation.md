# TimelineKit V3 立项书

> 版本：v3.0
> 状态：立项定稿，待各 spec 拆任务执行
> 对标产品：剪映 iOS（主要）+ Final Cut Pro / LumaFusion（参考）
> 依赖：v1 时间轴 / 字幕 / 音频交互基线，v2 不冲突

---

## 一、立项背景

v1 完成了「剪辑底座」（轨道 / 片段 / Trim / 字幕渲染 / 音频交互 / Draft / T-VRS 视频替换），v2 在排期中聚焦「渲染特性」（转场 / 调色 / 导出）。但用户在实际剪辑流程中仍卡在四个能力缺口：

1. **无法手动新建文本片段**。目前所有字幕都来自服务端 STT 流程，用户没有任何入口创建标题、备注、解说花字。
2. **底部工具栏「音频」入口已存在但功能为空**。`EditorToolCategory.audio` 已 `isEnabled = true`，但二级面板走默认 `EmptyView()` 分支，无任何工具可用。
3. **无配乐能力**。无视频提取音频、无本地音乐导入，用户无法给作品加 BGM。
4. **无任何 TTS 实现**。整库无 `AVSpeechSynthesizer` / `AVSpeechUtterance` 调用；服务端虽有「整段字幕 → 整段 MP3」流程，但编辑后必须整段重生成，无单条精修能力。

v3 目标即把这四件事一次性补齐到「剪辑流程完整闭环」的水平：用户拿一段视频就能提取音轨当 BGM，能手动加任何花字标题，能给单条文本一键生成配音，且字幕轨与文本轨完全独立，为后续多层叠加做架构准备。

---

## 二、范围围栏

### 2.1 ✅ V3 必做

| 序号 | 项目 | 落地位置 |
|---|---|---|
| 1 | 补齐「新建手动文本」完整入口与编辑流程 | [text-entry-spec.md](text-entry-spec.md) |
| 2 | 拆分字幕 / 文本双独立轨道；非主轨支持同类多轨道新建（预留多层叠加能力） | [multi-track-architecture-spec.md](multi-track-architecture-spec.md) |
| 3 | 音频全套基础功能：视频提取音频 + 本地配乐 + 基础音频编辑 | [audio-feature-spec.md](audio-feature-spec.md) |
| 4 | 客户端原生系统 TTS，绑定文本朗读功能 | [tts-spec.md](tts-spec.md) |
| 5 | 点击文本自动唤起专属编辑工具栏 | [text-entry-spec.md](text-entry-spec.md) |
| 6 | 音频波形展示、磁吸对齐音效反馈 | [audio-feature-spec.md](audio-feature-spec.md) |

### 2.2 ❌ V3 暂不做（延后迭代）

| 序号 | 项目 | 备注 |
|---|---|---|
| 1 | 多层字幕 / 文本叠加特效、层级混合透明度、字幕排版混合样式 | 预留数据模型与编辑入口，效果延后 |
| 2 | 云端海量音乐库、付费音效库 | 仅在二级面板预留「音效」灰显入口 |
| 3 | 专业音频混音、淡入淡出、音频变速变声 | 已有 `AudioContent.fadeInDuration / fadeOutDuration` 字段但 v3 不接入 UI |
| 4 | 服务端云端 TTS 对接 | 先跑通本地 `AVSpeechSynthesizer`，稳定后再谈服务端 |
| 5 | 花字、动画文本、文本边框阴影等花式文本样式 | `TextStyle` 字段已存在，v3 不开放完整样式编辑面板 |

---

## 三、与 v1 / v2 并行边界

### 3.1 不动 v1 任何文件

v1 已锁基线。v3 仅在三个地方做**加法**：

- `SegmentContent.AudioContent` 新增可选字段 `ttsSource: TTSSource?`（旧草稿反序列化为 `nil`，向后兼容）
- `EditorStore` 新增 `addTrack` / `addSegment(toTrack:)` / `removeTrackIfEmpty` / `regenerateTTS*` 方法
- `EditorBottomToolbar` 二级面板 `.audio` / `.text` 分支填入 stubs

不修改：v1 渲染管线（`CompositionBuilder` 主路径）、`mutateSubtitle` 不重建规则（S-04）、`isMainTrack` 唯一性、`TimelineImporter` 现有字幕导入路径。

### 3.2 与 v2 in-flight 工作的文件差集

v2 三件 spec 的关键改造文件 vs v3 改造文件清单：

| v2 spec | v2 改的文件 | v3 改的文件 | 冲突? |
|---|---|---|---|
| transition-spec.md | `CompositionBuilder.swift`（视频轨双轨 ping-pong）、`TrackCanvasView` 切割点 UI | 不动 `CompositionBuilder`；`TrackCanvasView` 仅加「轨道头 + 新建」入口 | ❌ 无 |
| filter-color-spec.md | `ColorAdjustmentCompositor.swift`、`ColorAdjustmentPanel.swift` | 不动 | ❌ 无 |
| export-pipeline-spec.md | `VideoExporter.swift` | 不动 | ❌ 无 |

v3 与 v2 共同会触碰 `EditorStore.swift` 和 `EditorBottomToolbar.swift`，但分别在不同方法 / 不同 enum case 上扩展，无写冲突。落地时按 spec 各自的 PR 推进即可，无需排序。

---

## 四、里程碑排期

| 里程碑 | 工作内容 | 关键交付 |
|---|---|---|
| **M1：多轨架构** | EditorStore 新增 `addTrack` / `addSegment(toTrack:)` / `removeTrackIfEmpty`；TrackCanvasView 加轨道头 `+` 入口 | 用户可在 UI 上新建第二条字幕轨 / 文本轨 / 音频轨；草稿往返不丢轨 |
| **M2：手动文本入口** | `EditorToolCategory.text` 启用；`.text` 二级面板 stubs；新建文本 → 自动入轨 + 弹 TextEditPanel | 用户可手动加任意花字标题，与字幕完全隔离 |
| **M3：音频核心** | `AudioExtractor` actor、`AudioImporter` actor、`.audio` 二级面板 stubs；磁吸对齐音效；音量滑块 | 用户可从任意视频提取音频、可从本地导入 m4a/mp3 当 BGM |
| **M4：本地 TTS** | `TTSService` actor、`AudioContent.ttsSource` 字段、`TextEditPanel` 朗读按钮、单条 / 批量 / 全篇重生 | 用户可对任意文本 / 字幕一键生成配音；改文案后自动提示重生 |
| **M5：整体联调** | 跨特性联调 + 草稿兼容性回归 + 性能/稳定性验证 | 完整剪辑流程通跑 |

排期顺序与用户在原始需求中给出的「开发推进顺序」完全一致。M1 是其他三个里程碑的前置依赖；M2、M3、M4 之间无强依赖，但 M4 依赖 M2 提供的 `TextEditPanel` 朗读按钮挂载点。

---

## 五、风险与依赖

### 5.1 技术风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| `AVSpeechSynthesizer.write(_:toBufferCallback:)` 离线渲染 API 仅 iOS 13+ | 限制最低支持 iOS 版本 | 项目当前已最低 iOS 17，远高于阈值，无影响 |
| PHPicker iOS 17 不直接支持 `audio` 媒体类型 | 「本地音乐」无法走 PHPicker | 改用 `UIDocumentPickerViewController` + `UTType.audio` |
| 音频提取需要 `AVAssetReader` 解码大视频，主线程不能阻塞 | 卡顿、ANR | actor 隔离 + 进度回调 + 取消支持 |
| 多字幕轨在服务端 schema 是否合并未确认 | 导出后字幕可能合并丢失分层 | 在 [multi-track-architecture-spec.md](multi-track-architecture-spec.md) 标注「跨端待对齐」，v3 客户端先按合并导出，分层信息保留本地草稿 |

### 5.2 外部依赖

- **服务端 TTS 路径**：旧服务端整段 MP3 字幕配音流程**不下线**；v3 客户端 TTS 不向服务端注册资产。两套配音可在同一草稿中并存，导出时一并合并。
- **服务端 schema**：现有 [TimelineExporter.swift](../../Sources/TimelineKit/Conversion/TimelineExporter.swift) 已能导出 `.subtitle` 轨道；多字幕轨合并策略需与服务端确认后回写本规范。
- **OS 权限**：相册访问（NSPhotoLibraryUsageDescription）已声明；音频导入 DocumentPicker 走系统 UI，无需额外权限。

---

## 六、验收 KPI

### 6.1 功能闭环

| KPI | 标准 |
|---|---|
| 用户能新建至少 2 条字幕轨、2 条文本轨、2 条音频轨并同时使用 | 全部可见、可剪辑、草稿往返保真 |
| 视频提取音频 → 一键加到 BGM 全链路成功率 | ≥ 99%（10 次连续试验 9 次以上成功） |
| 手动文本入口与自动字幕入口在数据上严格隔离 | `.text` 与 `.subtitle` 分属两类轨道；导入 / 导出不混淆 |
| 单条 TTS 生成 → 入轨 → 改文案 → 提示重生 → 重生 | 完整链路点击≤4 次完成 |

### 6.2 性能

| KPI | 标准 |
|---|---|
| 30 秒视频提取音频耗时 | ≤ 2.5s（iPhone 14） |
| 单条 TTS 合成（≤30 字中文） | ≤ 1.0s |
| 新建轨道（addTrack）操作 | ≤ 50ms 完成 store mutate + relayout |
| 切换到「音频」/「文本」二级面板 | ≤ 100ms（与 v1 切换基准持平） |

### 6.3 稳定性

| KPI | 标准 |
|---|---|
| 加载 v1 旧草稿 | 100% 兼容，无字段丢失，`ttsSource` 反序列化为 `nil` |
| 多轨草稿往返 | 写入 → 读出 → 比对 hash 一致 |
| 提取音频 / TTS / 导入过程中杀进程 | 临时文件清理，再次启动无残留 |

---

## 七、文档间引用图

```
README.md
   ├── V3-initiation.md  (本文档)
   ├── multi-track-architecture-spec.md
   │      ↳ 被 audio / text / tts 引用：新建轨道 / 同类多轨摆放策略
   ├── audio-feature-spec.md
   │      ↳ 被 tts-spec 引用：TTS 配音段落规则同音频段
   ├── text-entry-spec.md
   │      ↳ 被 tts-spec 引用：朗读按钮挂载点
   └── tts-spec.md
          ↳ 依赖 audio + text + multi-track 三件 spec
```

具体引用语义见各 spec「依赖」字段。

---

## 八、不在本立项范围

- 任何代码改动：留待 4 份 spec 各自的实现 PR
- v2 转场 / 调色 / 导出 spec 的任何修改
- 服务端 TTS 与服务端多字幕轨 schema 的对齐谈判（标注「跨端待对齐」）
