# TimelineKit v4 文档基线

## 版本定位

v4 是 v1 剪辑底座 + v3 多轨与文本/音频补齐之后的**体验升级层**：不做大架构重构，对齐剪映 iOS / Final Cut Pro 的主流剪辑逻辑，集中解决遗留样式 BUG、操作繁琐、多轨道使用障碍三大问题，把日常剪辑与批量创作的流畅度拉到上线水准。

v1 基线（`docs/v1/`）、v2 渲染特性（`docs/v2/`）、v3 剪辑能力补齐（`docs/v3/`）均**不重开**：v4 在它们之上做加法与 BUG 修复，数据模型仅做向下兼容的加法（`TextStyle.alignment` / `EditorSegment.userZOrder`）。

## 文档列表

| 文件 | 内容 | 优先级 | 状态 |
|------|------|------|------|
| [V4-initiation.md](V4-initiation.md) | 立项书：背景 / 范围围栏 / 里程碑 / 风险 / KPI | — | 规范定稿，待实现 |
| [competitive-benchmarks-v4.md](competitive-benchmarks-v4.md) | 竞品对标总报告（剪映 iOS / FCP / CapCut Desktop / LumaFusion，覆盖 P0/P1 全部能力点） | — | 规范定稿，待实现 |
| [text-style-fidelity-spec.md](text-style-fidelity-spec.md) | 样式预览 / 导出一致性 + 预设接线 | P0 | 规范定稿，待实现 |
| [bulk-style-apply-spec.md](bulk-style-apply-spec.md) | 同轨同类批量样式应用 + 二次确认 | P0 | 规范定稿，待实现 |
| [multi-track-scroll-spec.md](multi-track-scroll-spec.md) | 左右双栏纵向同步滚动 + 行高对齐 | P0 | 规范定稿，待实现 |
| [text-typography-spec.md](text-typography-spec.md) | 文本对齐 / 智能换行 / 复制粘贴样式 / 层级置顶置底 | P1 | 规范定稿，待实现 |
| [audio-track-controls-spec.md](audio-track-controls-spec.md) | 音频淡入淡出 + 轨道静音/锁定/隐藏 + 磁吸精度 | P1 | 规范定稿，待实现 |

## 与 v2 / 后续 P2 P3 的关系

| V4 阶段需求 | 落地位置 |
|---|---|
| P2 转场（叠化 / 闪黑 / 闪白 / 推进）| **沿用** [docs/v2/transition-spec.md](../v2/transition-spec.md)，必要修订条目追加在该 spec 内 |
| P2 调色（亮度 / 对比 / 饱和 / 色温）| **沿用** [docs/v2/filter-color-spec.md](../v2/filter-color-spec.md) |
| P2 工程画幅切换 / 自定义导出 / 后台导出 | **沿用** [docs/v2/export-pipeline-spec.md](../v2/export-pipeline-spec.md) |
| P2 视频定格画面 / P2 文本入场动画 / P3 模板复用 | V4-initiation.md 留 roadmap 占位，P0/P1 上线后单独立 spec |

## 开发节奏

```
P0（M1：样式保真 → M2：多轨滚动）
  → P1（M3：文本排版 → M4：音频与轨道控制）
  → M5 联调 + 草稿向下兼容回归 + 真机验收
  → P2 沿用 docs/v2 三件 spec
  → P3 单独立项
```

依赖顺序：**样式保真 → 批量应用 → 多轨滚动 → 文本排版 → 音频与轨道控制**

- 样式保真先于批量应用：批量复用的是单段样式 mutate 链路，单段链路必须先打通
- 多轨滚动独立于样式相关任务，可与 M1 并行
- 文本排版（含层级）建立在样式保真之上
- 音频淡入淡出与轨道锁定/隐藏与 v3 音频底座兼容，可放最后做

## 已确认的 V3 → V4 BUG / 缺口（来源：源码逐行校对）

| 类别 | 文件 / 位置 | 现状 | V4 spec 对应 |
|---|---|---|---|
| 文本预设点击 | [TextEditPanel.swift:291](../../Sources/TimelineKit/Views/TextEditPanel.swift) | 6 个色卡是 ZStack 装饰，**无 tap handler** | [text-style-fidelity-spec.md](text-style-fidelity-spec.md) §3 |
| 12 字段预览失真 | [SubtitleLayerBuilder（CompositionBuilder.swift:779-944）](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) | 预览端仅消费 fontSize/color/backgroundColor 等少量字段；导出端 `SubtitleFrameBuilder.renderText` 字段齐全 | [text-style-fidelity-spec.md](text-style-fidelity-spec.md) §4 |
| 批量样式 API | [EditorStore.swift](../../Sources/TimelineKit/Store/EditorStore.swift) | 仅有单段 `mutateTextStyle`/`mutateSubtitleStyle`，无批量 API | [bulk-style-apply-spec.md](bulk-style-apply-spec.md) §3 |
| 双栏纵向滚动 | [ClipEditorViewController.swift:141-158](../../Sources/TimelineKit/Views/ClipEditorViewController.swift) + [TrackLabelsView:394](../../Sources/TimelineKit/Views/ClipEditorViewController.swift) | scrollView 仅横向；TrackLabelsView 是 frame 布局固定左栏，**无 scroll** | [multi-track-scroll-spec.md](multi-track-scroll-spec.md) §2 |
| 文本对齐 | [TextStyle（SegmentContent.swift:254）](../../Sources/TimelineKit/Models/SegmentContent.swift) | **无 alignment 字段**；`renderSubtitle/renderText` 硬编码 `.center` | [text-typography-spec.md](text-typography-spec.md) §2 |
| 文本层级 | [EditorSegment.swift:28](../../Sources/TimelineKit/Models/EditorSegment.swift) | `sourceZIndex` 仅 round-trip 元数据；无用户重排 | [text-typography-spec.md](text-typography-spec.md) §5 |
| 音频淡入淡出 | [SegmentContent.swift:170-171](../../Sources/TimelineKit/Models/SegmentContent.swift) + [CompositionBuilder.swift:664-738](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) | 字段已在；**未调 `setVolumeRamp`**；无 UI | [audio-track-controls-spec.md](audio-track-controls-spec.md) §2 |
| 轨道 isLocked / isHidden | [EditorTrack.swift:10-11](../../Sources/TimelineKit/Models/EditorTrack.swift) | 字段都在；canvas 手势 / 渲染端 / UI 端均无消费 | [audio-track-controls-spec.md](audio-track-controls-spec.md) §3 |

## 与 v1 / v2 / v3 的边界

- **v1**：渲染管线主路径不动；仅在 `SubtitleLayerBuilder` / `SubtitleFrameBuilder` / `CompositionBuilder.buildAudio*` 内补字段读取与 ramp 调用。
- **v2**：转场 / 调色 / 导出三件 spec 完全不动，作为 V4 P2 阶段直接复用文档。
- **v3**：多轨架构、TextEditPanel、AudioEditPanel 入口全部沿用，V4 仅扩展内容（增加预设点击 handler、批量按钮、对齐 / 复制粘贴 / 层级按钮、淡入淡出滑杆、轨道锁/隐图标）。

数据模型变更（最小加法、向下完全兼容）：

- `TextStyle.alignment: TextAlignment`，新增枚举 `{ leading, center, trailing }`，默认 `.center`（旧草稿反序列化后视觉无差）。
- `EditorSegment.userZOrder: Int?`，旧草稿 = `nil`，渲染时与现有时间顺序复合排序。
- 无任何字段删除、无重命名、无类型变更。
