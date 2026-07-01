# TimelineKit V4 立项书

> 版本：v4.0
> 状态：立项定稿，待各 spec 拆任务执行
> 对标产品：剪映 iOS（移动端主对标） + Final Cut Pro（桌面级专业参考） + CapCut Desktop + LumaFusion
> 依赖：v1 时间轴 / 字幕 / 音频交互基线，v2 渲染特性 spec（沿用），v3 多轨 / 文本 / 音频 / TTS 已上线

---

## 一、立项背景

V3 已于 2026-05-16 全量上线（M1 多轨架构 / M2 手动文本入口 / M3 音频功能 / M4 本地 TTS 全部通过真机验收）。但在 V3 实际使用过程中，三类问题持续被用户反馈：

1. **文本样式预览与导出严重不一致**。`TextStyle` 字段齐全（lineSpacing / kerning / isItalic / stroke* / shadow* / backgroundColor / backgroundRadius / paddingH / paddingV 共 12 项），导出端 `SubtitleFrameBuilder.renderText()`（[CompositionBuilder.swift:1109](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift)）逐字段读取并正确渲染，但预览端 `SubtitleLayerBuilder` 仅消费一小撮基础字段，用户调样式时编辑画布完全无反馈，「样式调了但没生效」是误判，实质是预览端不刷新。**同时 `stylePresetsRow`（[TextEditPanel.swift:291](../../Sources/TimelineKit/Views/TextEditPanel.swift)）的 6 个预设是无 tap handler 的 ZStack 装饰**，点击不响应——这是另一个明确 BUG。
2. **多轨场景下下方轨道无法滚动查看**。v3 的多轨架构允许字幕 / 文本 / 音频 / 叠加层每类最多 8 条，但 `ClipEditorViewController` 主 UIScrollView 是**横向独享**（`scrollView.showsVerticalScrollIndicator = false`，仅 `alwaysBounceHorizontal = true`），左侧 `TrackLabelsView`（[ClipEditorViewController.swift:394](../../Sources/TimelineKit/Views/ClipEditorViewController.swift)）是固定左栏，frame 布局，无 scroll 上下文。一旦轨道数超过屏幕可视范围（约 5~6 条），下面的轨道**既看不到也选不到**——直接阻塞 v3 多轨能力的实际使用。
3. **批量重复样式调整效率低下**。同一条字幕轨上 30 段台词的样式调整目前只能逐条操作；`EditorStore` 无任何 batch / applyToAll 方法。用户在剪映 / CapCut 已养成「调一段、一键应用到全部」的肌肉记忆，缺失这功能体验落后竞品两个量级。

V4 不增加新的剪辑维度（不上专业混音、不上关键帧动画、不上多端协作），目标是把 V3 已有能力的体验「打磨到主流剪辑软件水平」，并补齐效率工具。

---

## 二、范围围栏

### 2.1 ✅ V4 必做（本期 P0 + P1）

| 优先级 | 序号 | 项目 | 落地 spec |
|---|---|---|---|
| P0 | 1 | 文本/字幕 12 个样式字段预览/导出 1:1 一致 + `stylePresetsRow` 预设点击接线 | [text-style-fidelity-spec.md](text-style-fidelity-spec.md) |
| P0 | 2 | 同轨同类批量样式应用（kind 隔离 + 二次确认 + 单条 undo） | [bulk-style-apply-spec.md](bulk-style-apply-spec.md) |
| P0 | 3 | 左侧 `TrackLabelsView` 与右侧轨道编辑区纵向同步滚动 + 行高 0 错位 | [multi-track-scroll-spec.md](multi-track-scroll-spec.md) |
| P1 | 4 | 文本对齐（leading/center/trailing） | [text-typography-spec.md](text-typography-spec.md) |
| P1 | 5 | 字幕智能换行边界完善（中英文 / emoji / 禁则） | [text-typography-spec.md](text-typography-spec.md) |
| P1 | 6 | 文本样式复制 / 粘贴（in-memory 剪贴板，kind 隔离） | [text-typography-spec.md](text-typography-spec.md) |
| P1 | 7 | 文本/字幕层级置顶/置底/上移/下移 | [text-typography-spec.md](text-typography-spec.md) |
| P1 | 8 | 音频片段淡入 / 淡出（`AVMutableAudioMixInputParameters.setVolumeRamp`） | [audio-track-controls-spec.md](audio-track-controls-spec.md) |
| P1 | 9 | 轨道静音 / 锁定 / 隐藏（已有 model 字段 → 全链路接入） | [audio-track-controls-spec.md](audio-track-controls-spec.md) |
| P1 | 10 | 音频剪辑手柄拖拽磁吸精度补强 | [audio-track-controls-spec.md](audio-track-controls-spec.md) |

### 2.2 🟡 V4 沿用既有 spec（不重写）

| 优先级 | 项目 | 复用 spec |
|---|---|---|
| P2 | 片段基础转场（叠化 / 闪黑 / 闪白 / 推进，时长自定义） | [docs/v2/transition-spec.md](../v2/transition-spec.md) |
| P2 | 画面简易调色（亮度 / 对比 / 饱和 / 色温） | [docs/v2/filter-color-spec.md](../v2/filter-color-spec.md) |
| P2 | 工程全局快捷画幅切换（9:16 / 16:9 / 1:1）+ 自定义导出参数 + 后台静默导出 | [docs/v2/export-pipeline-spec.md](../v2/export-pipeline-spec.md) |

V4 P0/P1 落地后再启动 v2 三件 spec 的实现工作；如实现中发现现状偏离，**在 v2 原 spec 内追加「v4 修订条目」段落**，不在 v4 重复立 spec。

### 2.3 🕓 V4 留 roadmap（P0/P1 上线后单独立 spec）

| 优先级 | 项目 | 备注 |
|---|---|---|
| P2 | 视频定格画面（freeze frame） | 沿 v1 静帧渲染管线 + 新增 segment kind / 触发入口 |
| P2 | 轻量化文本入场动画（渐入 / 缩放弹出 / 平移出现） | v1 已有 `enterAnimation/exitAnimation` 字段；本期不接 UI |
| P3 | 常用剪辑工程模板保存与一键复用 | 草稿层扩展，涉及 `DraftStore` 多入口 |

### 2.4 ❌ V4 暂不做（明确延后）

| 项目 | 理由 |
|---|---|
| 关键帧动画（位置 / 缩放 / 透明度 keyframe）| 改动量 ≈ 半个 V3，本期容量不足 |
| 专业音频混音（多轨混音器 / EQ / 压缩）| `AVAudioEngine` 引入成本高，v3 已锁 `AVMutableAudioMix` 路径 |
| 多端实时协作 | 服务端 schema 重设计，非本期范围 |
| AI 字幕翻译 / 双语字幕 | 服务端 STT 流程未启动多语种，跨端依赖 |
| 字幕识别歌词样式（卡拉 OK 高亮）| 渲染管线需逐字时间戳，v3 字幕粒度=句 |

---

## 三、与 v1 / v2 / v3 并行边界

### 3.1 不改动 v1 任何已锁文件

v1 已锁基线（trim / scrub / 字幕渲染 / 音频交互 / 草稿持久化）。v4 仅在以下文件做**加法**：

- `Models/SegmentContent.swift`：`TextStyle` 新增 `alignment: TextAlignment`（默认 `.center`，Codable 走 `decodeIfPresent` 容错）
- `Models/EditorSegment.swift`：新增 `userZOrder: Int?`（可选，渲染端复合排序）
- `Rendering/SubtitleLayerBuilder.swift`：补齐预览端 12 个样式字段读取（导出端 `SubtitleFrameBuilder.renderText` 已是完整参考实现，不动）
- `Rendering/CompositionBuilder.swift`：音频 mix 增加 `setVolumeRamp` 调用（在现有 `setVolume(_:at:)` 基础上叠加，不替换）
- `Store/EditorStore.swift`：新增 `applyStylePreset` / `applyStyleToTrackSegmentsOfKind` / `setTrackLocked` / `setTrackHidden` / `setSegmentZOrder` / `mutateAudioFade` 等方法
- `Views/TextEditPanel.swift`：`stylePresetsRow` 接线 / 增加批量按钮 / 增加对齐三按钮 / 增加复制粘贴 / 增加层级四按钮
- `Views/AudioEditPanel.swift`：增加 fade in / fade out 滑杆
- `Views/ClipEditorViewController.swift`：scrollView 嵌套结构调整以支持纵向同步滚动
- `Views/TrackCanvasView.swift`：暴露 `contentSize.height` 让左侧 labels 同步；新增锁/隐图标渲染
- 不修改：v1 渲染管线主路径 / `mutateSubtitle` 不重建规则（S-04）/ `isMainTrack` 唯一性 / 草稿主流程

### 3.2 v2 三件 spec 完全不动

V4 P2 阶段直接执行 v2 spec。v4 实现过程中若发现 v2 spec 与当前代码状态有偏差，**在 v2 原 spec 内追加「v4 修订条目」段落**，保持 v2 文档为后续实现的唯一权威来源。

### 3.3 v3 文档与代码完全沿用

v3 多轨架构 / 文本入口 / 音频功能 / 本地 TTS 四件 spec 都不修改。v4 在 v3 基础上做**内容补齐**与**入口扩展**：

- v3 `TextEditPanel` 已统一字幕 / 文本两类共用 → v4 在此面板内增加预设接线、批量、对齐、复制粘贴、层级按钮
- v3 多轨 `addTrack` 已落地 → v4 给左侧 labels 加同步滚动 + 锁/隐图标
- v3 音频提取 / 导入 / 音量基础编辑已上线 → v4 在 `AudioEditPanel` 内增加淡入淡出 + 全链路接入轨道锁/隐
- v3 已锁交互约束（轨道点击仅唤起快捷栏 / 文本字幕共用面板 / 底部工具栏二态 / 向下兼容）→ v4 全部沿用

---

## 四、里程碑排期

| 里程碑 | 工作内容 | 关键交付 |
|---|---|---|
| **M1（P0-A）样式保真** | `text-style-fidelity-spec.md` + `bulk-style-apply-spec.md`：补齐预览端 12 字段读取、接线预设点击、新增 `applyStylePreset` / `applyStyleToTrackSegmentsOfKind` store API、批量按钮 + 二次确认弹窗 | 调样式所见即所得；同轨同类一键批量；预览/导出像素差 ≤ 2% |
| **M2（P0-B）多轨滚动** | `multi-track-scroll-spec.md`：双栏共用纵向滚动上下文，行高 0 错位 | 8+8+8 多轨场景 0 漂移；ruler 与 labels 顶部对齐 |
| **M3（P1-A）文本排版与层级** | `text-typography-spec.md`：`TextStyle.alignment` 新增、`EditorSegment.userZOrder` 新增、对齐 / 复制粘贴 / 层级四按钮全套 UI、智能换行边界完善 | 三种对齐肉眼可控；样式跨段复用 ≤ 3 步点击；置顶置底实时生效 |
| **M4（P1-B）音频与轨道控制** | `audio-track-controls-spec.md`：`setVolumeRamp` 接入、淡入淡出滑杆、`isLocked / isHidden` 全链路 | 音频淡入淡出预览/导出一致；锁/隐图标可见可点；磁吸覆盖 fade handle |
| **M5 联调** | 跨特性回归 + 旧草稿（v1/v2/v3）100% 加载 + 真机验收 | 一份完整 V4 验收清单全绿 |

排期严格按用户给出的「P0 → P1」推进。M1 与 M2 可并行（涉及文件无交集）。M3 在 M1 完成后做（共享 styleSliderRow / Store mutate 路径）。M4 在 M2 完成后做（需要 labels 同步滚动后再加图标交互）。

---

## 五、风险与依赖

### 5.1 技术风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| 预览端 `SubtitleLayerBuilder` 高频 `setNeedsDisplay` 卡顿 | 调样式手感顿挫 | 复用 v1 `mutateSubtitle` 不触发 compositionVersion 规则（S-04），只重绘字幕图层，不重建 AVComposition |
| `setVolumeRamp` 与现有 `setVolume(_:at:)` keyframe 共存策略 | 多轨音频 mix 时静音 keyframe 与 fade ramp 互相覆盖 | spec 中明确：先 `setVolumeRamp(0→volume, fadeIn)` → `setVolume(volume)` 平段 → `setVolumeRamp(volume→0, fadeOut)`；isMuted 时仍硬 `setVolume(0, at:.zero)` 优先 |
| `isHidden` 轨道在导出端语义未定 | 用户期望 vs 实现行为差异 | **本期定案：剪映语义 = 导出不渲染**，在 [audio-track-controls-spec.md](audio-track-controls-spec.md) 明示，覆盖音频静音、视频叠加层、字幕/文本三类 |
| `TextStyle.alignment` 旧草稿兼容 | 旧字幕加载后位置偏移 | 默认 `.center` 保持现状视觉；Codable `decodeIfPresent` 容错 |
| 多轨双栏纵向同步滚动方案 | 方案 A（labels 跟随主 scrollView contentOffset.y）vs 方案 B（外层共用 vertical ScrollView，内层水平 ScrollView） | spec 中定案方案 A：改动局限于 `ClipEditorViewController.scrollViewDidScroll` 与 `TrackLabelsView.contentOffset` 转发，零侵入 |

### 5.2 外部依赖

- **v2 三件 spec**：V4 P2 阶段执行的前置依赖。本期 P0/P1 不阻塞，但 P2 启动前需校对 v2 spec 与当前代码状态。
- **草稿 schema 加法**：`TextStyle.alignment` / `EditorSegment.userZOrder` 仅本端使用，不与服务端协议交换；服务端 TimelineExporter 暂不导出这两个字段（保留本地草稿层）。
- **iOS 平台 API**：`AVMutableAudioMixInputParameters.setVolumeRamp(fromStartVolume:toEndVolume:timeRange:)` 自 iOS 7 即支持，无版本风险。

---

## 六、验收 KPI

### 6.1 功能闭环

| KPI | 标准 |
|---|---|
| `stylePresetsRow` 6 个预设点击 → 当前片段完整样式更新 | 点击后 ≤ 200ms 预览端可见效果 |
| 12 个样式字段（lineSpacing / kerning / isItalic / strokeColor / strokeWidth / backgroundColor / backgroundRadius / paddingH / paddingV / shadowColor / shadowOffsetX/Y / shadowRadius）逐个可调 | 预览端实时显示；与导出端像素差 ≤ 2% |
| 同轨同类批量样式应用 | 字幕只批字幕、文本只批文本；10 段以内 ≤ 50ms；单条 undo |
| 多轨纵向同步滚动 | 8+8+8 共 24 轨场景下，labels 与 canvas 0 漂移；行高 0 错位 |
| 文本三种对齐 | UI 三按钮组；预览/导出一致 |
| 文本样式复制 / 粘贴 | 跨段 ≤ 2 步；kind 隔离（字幕↔文本互不污染） |
| 文本/字幕层级置顶/置底/上移/下移 | UI 四按钮；置顶段位于其他同位置段之上；undo/redo 一致 |
| 音频淡入 / 淡出 | AudioEditPanel 双滑杆；ramp 实时预览；导出 PCM 包络一致 |
| 轨道静音 / 锁定 / 隐藏 | TrackLabelsView 三图标可见可点；锁定后该轨拒绝长按 / drag / trim handle；隐藏后预览不可见且导出不渲染 |
| 音频磁吸覆盖 fade handle | 拖动 fade handle 时段落起止 / 相邻片段边 / 播放头三类磁吸触觉一致 |

### 6.2 性能

| KPI | 标准 |
|---|---|
| `applyStylePreset` 单段 | ≤ 16ms（不引入 frame drop） |
| `applyStyleToTrackSegmentsOfKind` 10 段 | ≤ 50ms |
| 双栏纵向滚动 | 60fps 稳态，无掉帧 |
| `setNeedsDisplay` 触发字幕图层重绘 | ≤ 8ms |
| `setVolumeRamp` 重新构建 audio mix | ≤ 30ms（与 v3 现状持平） |

### 6.3 稳定性 & 兼容

| KPI | 标准 |
|---|---|
| 加载 v1 / v2 / v3 旧草稿 | 100% 兼容，无字段丢失；`alignment` 反序列化为 `.center`，`userZOrder` 反序列化为 `nil` |
| 多轨场景下连续 100 次纵向滚动 | 0 崩溃；contentOffset 不漂移 |
| 批量样式应用过程中切换片段选择 | 不打断；操作原子完成 |
| 轨道锁定状态下尝试拖拽 / trim | 拒绝且无副作用；编辑面板隐藏破坏性按钮 |
| 隐藏轨道导出 | 导出文件不包含该轨内容（视频叠加 / 字幕 / 音频静音） |

---

## 七、固定交互约束（V3 已锁，V4 全程沿用，禁止改动）

| 约束 | 来源 |
|---|---|
| 轨道点击仅选中唤起快捷操作栏，**不遮挡轨道编辑区**；预览画布点击直接唤起完整编辑面板 | V3 已定稿交互逻辑 |
| 文本、字幕统一共用 `TextEditPanel` 唯一编辑面板，仅区分是否展示朗读功能、位置调节 Tab | V3 [text-entry-spec.md](../v3/text-entry-spec.md) |
| 底部工具栏严格区分两种场景：无选中片段仅展示新建入口，选中片段仅展示编辑快捷操作 | V3 已定稿 |
| 所有新增功能必须适配旧版草稿，做到向下完全兼容 | V3 [V3-initiation.md](../v3/V3-initiation.md) §3.1 |
| 安卓 / iOS 双端交互逻辑保持统一 | V3 已定稿 |

每份 v4 spec 末尾必须重申一遍以上五条约束，确保实现时不漂移。

---

## 八、不在本立项范围

- 任何代码改动：留待 7 份 spec 各自的实现 PR
- v1 / v2 / v3 文档修订（v4 是补齐与加法，不重开历史 spec）
- v2 三件 spec 的实现工作（P0/P1 上线后启动）
- P2 / P3 留 roadmap 占位项目（freeze frame / 文本动画 / 模板）
- 服务端 TimelineExporter schema 谈判（`alignment` / `userZOrder` 仅本地草稿层）

---

## 九、文档间引用图

```
README.md
   ├── V4-initiation.md  (本文档)
   ├── competitive-benchmarks-v4.md
   │      ↳ 被所有 5 份 P0/P1 spec 引用：竞品基线与规则定案依据集中维护
   ├── text-style-fidelity-spec.md (P0)
   │      ↳ 被 bulk-style-apply / text-typography 引用：单段样式 mutate 是批量与层级排序的前置链路
   ├── bulk-style-apply-spec.md (P0)
   │      ↳ 依赖 text-style-fidelity：批量改写复用单段 mutate
   ├── multi-track-scroll-spec.md (P0)
   │      ↳ 被 audio-track-controls 引用：锁/隐图标渲染需要左侧 labels 同步滚动
   ├── text-typography-spec.md (P1)
   │      ↳ 依赖 text-style-fidelity：alignment 字段补齐预览/导出
   └── audio-track-controls-spec.md (P1)
          ↳ 依赖 multi-track-scroll：图标交互前置；引用 v3 audio-feature-spec 磁吸阈值
```

具体引用语义见各 spec「依赖」字段。
