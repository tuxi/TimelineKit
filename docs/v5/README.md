# TimelineKit v5 文档基线

## 版本定位

v5 是在 v1 剪辑底座 + v3 多轨补齐 + v4 体验升级之上的**两件刚需补齐**——不引入新剪辑维度、不动既有交互模型，只解决两个 V4 范围内无法增量解决的痛点：

1. **预览 ≠ 成片**：编辑画布（SwiftUI 叠加层）与导出（CIImage / CALayer 烘焙）是两套绘制逻辑，描边 / 阴影 / 背景圆角 / padding / 层级 5 类样式必然存在像素差。V5 新增"全屏预览"入口，全屏复用导出渲染管线，所见即所得。
2. **导出参数不可控**：[VideoExporter.swift:74-80](../../Sources/TimelineKit/Export/VideoExporter.swift) 在 `AVAssetExportPreset1920x1080 / 1280x720 / MediumQuality` 三选一硬编码，无分辨率/帧率/码率/HDR 任何可调。V5 新增"规格按钮 + 配置面板"，全链路打通到 `AVAssetWriter`。

v1 基线（`docs/v1/`）、v2 渲染特性（`docs/v2/`）、v3 剪辑能力（`docs/v3/`）、v4 体验升级（`docs/v4/`）均**不重开**：v5 在它们之上做加法。数据模型仅做向下兼容的加法（`EditorMetadata.exportConfig`）。

## 文档列表

| 文件 | 内容 | 优先级 | 状态 |
|------|------|------|------|
| [V5-initiation.md](V5-initiation.md) | 立项书：背景 / 范围围栏 / 里程碑 / 风险 / KPI / 固定约束 | — | 规范定稿，待实现 |
| [competitive-benchmarks-v5.md](competitive-benchmarks-v5.md) | 竞品对标总报告（剪映 / CapCut / FCP / LumaFusion，覆盖导出参数 + 全屏预览） | — | 规范定稿，待实现 |
| [fullscreen-preview-spec.md](fullscreen-preview-spec.md) | 同源全屏真实预览（路线 1：烘焙 composition + 独立 AVPlayer） | **P0** | 规范定稿，待实现 |
| [export-config-panel-spec.md](export-config-panel-spec.md) | 规格按钮 + 配置面板 UI + ExportConfig 数据模型 + 持久化 | P1 | 规范定稿，待实现 |
| [render-pipeline-unification-spec.md](render-pipeline-unification-spec.md) | 渲染管线统一 + AVAssetWriter 改造（M3 SDR / M4 HDR 分阶段） | P1 | 规范定稿，待实现 |

## 与 v2 / 后续 P2 P3 的关系

| V5 阶段需求 | 落地位置 |
|---|---|
| P1 导出分辨率 / 码率档位规则 / 编码格式 / 文件落盘 | **沿用** [docs/v2/export-pipeline-spec.md](../v2/export-pipeline-spec.md) 末尾「附录 A：v5 修订条目」（V5 在原文追加，不重立同名 spec） |
| P2 空白工程 / 草稿体系扩展 / 后台导出 | V5-initiation.md §2.3 留 roadmap 占位，P0/P1 上线后单独立 spec |
| P3 草稿模板 / 多端协作 / 云端工程 | V5-initiation.md §2.3 留 roadmap 占位 |

## 开发节奏

```
M1（P0：全屏同源预览，可独立上线）
  → M2（P1-A：数据模型 + UI 面板）
  → M3（P1-B：AVAssetWriter 改造 H.264 SDR 全档位）
  → M4（P1-C：HEVC10 + HDR PQ 增量）
  → M5 联调 + 旧草稿向下兼容回归 + 真机验收
  → P2 沿用 docs/v2 export-pipeline-spec.md（含附录 A）
  → P3 单独立项
```

依赖顺序：**全屏同源预览 → 数据模型/UI → AVAssetWriter SDR → HDR 增量**

- 全屏预览先于导出参数：M1 建立的"烘焙 composition + 独立 AVPlayer"基础设施在 M3 直接复用
- M2 与 M3 可并行（UI/数据模型 vs 渲染管线，无文件交集）
- M4 在 M3 完成后做（HDR 需要 HEVC10 编码路径先稳定）

## 已确认的 V4 → V5 缺口（来源：源码逐行校对）

| 类别 | 文件 / 位置 | 现状 | V5 spec 对应 |
|---|---|---|---|
| 预览/成片绘制路径分裂 | [CompositionBuilder.swift:35](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) `build(from:renderSubtitles:)` | 导出 `renderSubtitles=true` 走 CIImage/CALayer 烘焙；预览 `renderSubtitles=false` 走 SwiftUI 叠加层。**两套绘制逻辑**，描边/阴影/背景/层级 5 类必然像素差 | [fullscreen-preview-spec.md](fullscreen-preview-spec.md) §2 |
| 无全屏预览入口 | [EditorControlBar.swift:8-34](../../Sources/TimelineKit/Views/EditorControlBar.swift) | 仅 backward/play/forward 三按钮；无 fullscreen 代码（即使是注释或废弃代码）| [fullscreen-preview-spec.md](fullscreen-preview-spec.md) §3.4 |
| 导出参数三选一硬编码 | [VideoExporter.swift:74-80](../../Sources/TimelineKit/Export/VideoExporter.swift) | `AVAssetExportPreset1920x1080 / 1280x720 / MediumQuality` 三选一；固定 mp4；无 4K/2K/480P/帧率/码率/HDR | [render-pipeline-unification-spec.md](render-pipeline-unification-spec.md) §4 |
| AVAssetExportSession 架构限制 | 同上 | 预设绑定分辨率+质量，无法独立控制码率 + 色彩空间 | 必须改造为 `AVAssetWriter`（参考既有先例 [StaticImageRenderer.swift:107-116](../../Sources/TimelineKit/Rendering/StaticImageRenderer.swift)） |
| EditorMetadata 无导出配置字段 | [EditorTimeline.swift:226-246](../../Sources/TimelineKit/Models/EditorTimeline.swift) | `EditorMetadata` 仅 5 字段（sourceTaskID / sourceWorkflow / productName / createdAt / renderType），无导出配置挂载点 | [export-config-panel-spec.md](export-config-panel-spec.md) §3 |
| 无"跟随画布"派生默认机制 | [EditorCanvas.swift:22-29](../../Sources/TimelineKit/Models/EditorCanvas.swift) 4 种预设短边均为 720 | 若用固定 480P 默认 → 720P canvas 工程默认导出 480P，反直觉 | [export-config-panel-spec.md](export-config-panel-spec.md) §3.1 `ExportConfig.default(for: canvas)` |
| 顶部 toolbar 无规格按钮 | [ClipEditorView.swift:197-199, 326-332](../../Sources/TimelineKit/Views/ClipEditorView.swift) | topBarTrailing 仅 `exportButton`（文本"导出"）；左侧无规格快捷标识 | [export-config-panel-spec.md](export-config-panel-spec.md) §4 |

## 与 v1 / v2 / v3 / v4 的边界

- **v1**：渲染管线主路径（`CompositionBuilder.build` 现签名 + 烘焙路径）不动；本期 `build` 仅新增可选 renderSize/fps 参数，默认 nil 时行为完全一致
- **v2**：transition / filter-color 两件 spec 完全不动；export-pipeline-spec 在原文末尾追加附录 A（不改主体）
- **v3**：多轨架构、TextEditPanel、AudioEditPanel 入口全部沿用；本期不涉及 v3 任何能力
- **v4**：样式保真 / 批量 / 多轨滚动 / 文本排版 / 音频控制 7 份 spec 完全沿用；本期不修改其中任何代码

数据模型变更（最小加法、向下完全兼容）：

- `EditorMetadata.exportConfig: ExportConfig?`，旧草稿 = `nil`，加载后**按 `canvas` 派生默认**（分辨率/帧率匹配最接近档位；码率推荐；HDR 开）。当前 4 种 canvas 预设短边均为 720 → 默认导出 720P
- `EditorTimeline.effectiveExportConfig` 计算属性（不挂在 `EditorMetadata` 上，因派生需要 canvas 上下文）
- `ExportConfig` 是 Codable 独立结构体，含 4 字段；提供 `default(for canvas:)` 工厂方法 + `factoryDefault` 兜底常量（1080P/30/推荐/HDR开，仅单元测试用）
- 无任何字段删除、无重命名、无类型变更
- 服务端 TimelineExporter 不导出该字段（仅本地草稿层）
