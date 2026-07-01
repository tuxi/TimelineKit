# TimelineKit v6 文档基线

## 版本定位

v6 是在 v1 剪辑底座 + v3 多轨补齐 + v4 体验升级 + v5 同源预览/导出参数化之上的**底层渲染架构重塑大版本**——不引入新剪辑维度、不动既有交互模型，目标是把「图片→预合成 MP4→AVAssetTrack→AVMutableComposition」这条死路换成「图片→CIImage→关键帧矩阵变换→UnifiedCompositor 直出」，相册导入与 AI 下发素材在数据层与渲染链路完全归一。

V5 + V5.1 收尾后渲染体系仍残留两类系统性硬伤，V4 / V5 范围内**无法增量解决**：

1. **预合成 MP4 桎梏**：所有 `image / image_motion / image_3d` 段落都靠 [StaticImageRenderer.swift](../../Sources/TimelineKit/Rendering/StaticImageRenderer.swift) 预渲染为 MP4 再挂到 AVMutableComposition。该方案带来 (a) 静态图 1fps、动效图全 fps 的差异化编码逻辑；(b) sentinel 帧 + `setOpacity(0, at:)` 钳层尾帧的脆弱兜底；(c) AI 工程转场尾帧冻结、自由剪辑正常的差异化 BUG；(d) 临时文件 IO + 帧率不一致引发的时序错位。V5.1 已在 `buildVideoTrackSinglePass` 引入 dual-composition-track + instruction 切分等多处补丁救火，但底层架构不变，新需求每加一条都要重写一次兜底。
2. **AI 动画参数损耗**：[TimelineImporter.swift](../../Sources/TimelineKit/Conversion/TimelineImporter.swift) 把 `SImageAnimation.scaleFrom/scaleTo`、`SDepthModel`（深度图）、`SCamera.intensity` 几乎全部丢弃，只取 `type` 字段映射到 `ImageMotionPreset` 枚举；server 下发的连续动画参数被降级为有限预设，造成「相册导入 vs AI 下发」素材行为漂移。

v1 基线（`docs/v1/`）、v2 渲染特性（`docs/v2/`）、v3 剪辑能力（`docs/v3/`）、v4 体验升级（`docs/v4/`）、v5 同源预览/导出参数（`docs/v5/`）均**不重开**：v6 在它们之上做底层重构。数据模型仅做向下兼容的加法（`ImageContent.keyframes`、`KeyframeSet.anchor`）。

## 文档列表

| 文件 | 内容 | 优先级 | 状态 |
|------|------|------|------|
| [V6-initiation.md](V6-initiation.md) | 立项书：背景 / 范围围栏 / 里程碑 / 风险 / KPI / 固定约束 | — | 规范定稿，待实现 |
| [competitive-benchmarks-v6.md](competitive-benchmarks-v6.md) | 竞品对标总报告（剪映 / CapCut / FCP / LumaFusion，覆盖图片图层 + 关键帧 + 2.5D parallax）| — | 规范定稿，待实现 |
| [image-layer-rendering-spec.md](image-layer-rendering-spec.md) | 废除 StaticImageRenderer，UnifiedCompositor 扩展为支持「无 AVAssetTrack 源」的纯图片图层渲染 | **P0** | 规范定稿，待实现 |
| [keyframe-animation-spec.md](keyframe-animation-spec.md) | 关键帧数据模型（position / scale / rotation / anchor / opacity 5 维 MVP）+ 缓动曲线 + 播放进度驱动求值器 | **P0** | 规范定稿，待实现 |
| [ai-timeline-mapping-spec.md](ai-timeline-mapping-spec.md) | `SImageAnimation` / `SDepthModel` / `SCamera` → 关键帧端到端映射；相册图 + AI 图统一规则 | **P0** | 规范定稿，待实现 |
| [layer-rendering-rules-spec.md](layer-rendering-rules-spec.md) | 主轨尾段黑屏 / overlay 透出 / 动画末态停驻 / 全局帧率对齐 等渲染层硬规则固化 | **P0** | 规范定稿，待实现 |
| [transition-compat-spec.md](transition-compat-spec.md) | 转场与关键帧图层共存（转场只作用于图层交界、不冻结关键帧求值）、实时缓存策略、导出链路对齐 | P1 | 规范定稿，待实现 |
| [timeline-runtime-architecture.md](timeline-runtime-architecture.md) | **架构重调研**：AVPlayer+AVVideoCompositing 方案边界分析 + 主流剪辑器 Layer Runtime 调研 + DreamAI Timeline Runtime 目标架构设计 + 分阶段迁移计划 | 调研 | 调研定稿，待技术评审 |
| [video-frame-provider-performance-plan.md](video-frame-provider-performance-plan.md) | **P4 性能化评估**：将 `VideoFrameProvider` 从 `AVAssetImageGenerator.copyCGImage` 架构验证路径升级为 source-level `AVPlayerItemVideoOutput -> CVPixelBuffer` 实时预览路径 | **P4** | source-level provider 已验证，seek/forced-copy 已收口，warm-frame/benchmark 待做 |
| [image-realtime-playback-issue-analysis.md](image-realtime-playback-issue-analysis.md) | seek/play 不一致根因分析：containsTweening / enablePostProcessing / requiredSourceTrackIDs 三个 instruction metadata bug | 调试 | 结论定稿，修复待执行 |

## 与 v5 / 后续 P2 P3 的关系

| V6 阶段需求 | 落地位置 |
|---|---|
| P2 全屏同源预览 | **沿用** [docs/v5/fullscreen-preview-spec.md](../v5/fullscreen-preview-spec.md)，V6 P0 架构稳定后接入；本期不重写 |
| P2 导出参数面板 | **沿用** [docs/v5/export-config-panel-spec.md](../v5/export-config-panel-spec.md)，V6 P0 架构稳定后接入；本期不重写 |
| P2 AVAssetWriter 改造 | **沿用** [docs/v5/render-pipeline-unification-spec.md](../v5/render-pipeline-unification-spec.md)，V6 P0 架构稳定后接入；本期不重写 |
| P2 「开始创作」素材选择入口 | V6-initiation.md §2.3 留 roadmap 占位，P0/P1 上线后单独立 spec |
| P2 我的页面草稿列表管理 | V6-initiation.md §2.3 留 roadmap 占位 |
| P3 自定义贝塞尔关键帧路径编辑 UI / 蒙版动画 / 多维度形变 | V6-initiation.md §2.3 留 roadmap 占位 |

## 开发节奏

```
M1（P0-A：图片图层最小可播，相册静态图跑通）
  → M2（P0-B：AI 动画统一映射，TimelineImporter 重写）
  → M3（P0-C：渲染规则固化，主轨尾段黑屏 / overlay 透出 / 末态停驻）
  → M4（P1：转场 + 性能 + 缓存）
  → P4（VideoFrameProvider 性能化：AVPlayerItemVideoOutput 实时预览帧源）
  → M5（P2：上层业务接入，沿用 V5 三份 spec + 新增创作入口/草稿列表 spec 单独立项）
  → M6 真机回归 + 封版
```

依赖顺序：**图片图层最小可播 → AI 映射 → 渲染规则 → 转场 / 性能 / 缓存 → 上层业务**

- M1 是所有后续里程碑的前置：`ImageLayerComposer` + `KeyframeEvaluator` + `EasingCurve` 三件基建未落地之前，M2/M3 没有宿主
- M2 与 M3 不并行（M3 渲染规则验证依赖 AI 动效素材跑通）
- M4 在 M3 完成后做（转场逻辑需要 M3 渲染规则稳定才能确定 instruction 切分边界）
- P4 在 Timeline Runtime mixed timeline 跑通后执行，目标是把视频帧来源从 `AVAssetImageGenerator` 验证路径替换为 `AVPlayerItemVideoOutput` 长期实时预览路径
- M5 是业务层并行，与 M4 性能优化无文件交集

## 已确认的 V5 → V6 缺口（来源：源码逐行校对）

| 类别 | 文件 / 位置 | 现状 | V6 spec 对应 |
|---|---|---|---|
| 图片必须 prebake 为 MP4 | [CompositionBuilder.swift](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) `resolveSegmentURL`（≈ 行 672-697）| 所有 `.image / .image_motion / .image_3d` 段落调用 `StaticImageRenderer.render(...)` 输出 MP4 → AVURLAsset → AVAssetTrack → insertTimeRange；无任何「无源图层」分支 | [image-layer-rendering-spec.md](image-layer-rendering-spec.md) §2 |
| 静态图 / 动效图差异化 fps | [StaticImageRenderer.swift](../../Sources/TimelineKit/Rendering/StaticImageRenderer.swift)（≈ 行 105）| 静态图 fps=1 编码；带 motionPreset / depthEffect 的图全 fps 编码；两套帧时序，转场时常错位 | [image-layer-rendering-spec.md](image-layer-rendering-spec.md) §3 |
| sentinel 帧 + setOpacity 钳尾帧 | StaticImageRenderer（≈ 行 173-207）+ CompositionBuilder V5 setOpacity 旧实现 | 通过末尾追加一帧 + `setOpacity(0, at: mainVideoEnd)` 防止尾帧滞留；image_motion / image_3d 上不可靠（V5.1 已用 dual-composition-track 救火，但 unified 路径仍残留）| [layer-rendering-rules-spec.md](layer-rendering-rules-spec.md) §2 |
| 服务器动画参数被降级为预设 | [TimelineImporter.swift](../../Sources/TimelineKit/Conversion/TimelineImporter.swift) 行 93-150 + [ServerTimelineSchema.swift](../../Sources/TimelineKit/Conversion/ServerTimelineSchema.swift) `SImageAnimation` / `SDepthModel` / `SCamera` | `SImageAnimation.scaleFrom/scaleTo/translateXFrom/opacityTo` 全部丢弃；`SDepthModel.centerX/innerRadius/falloff` 完全未消费；`SCamera.intensity` 仅作为 `DepthEffect.intensity` 透传但下游用不上 | [ai-timeline-mapping-spec.md](ai-timeline-mapping-spec.md) §2 |
| `KeyframeSet` 已有却被图片忽略 | [EditorSegment.swift](../../Sources/TimelineKit/Models/EditorSegment.swift) 行 38-48 | `KeyframeSet` 支持 opacity / position / scale / rotation 四维但仅服务于「text/subtitle 段落手动动画」，图片 content 完全不消费 | [keyframe-animation-spec.md](keyframe-animation-spec.md) §3 |
| UnifiedCompositor 强依赖 sourceFrame | [UnifiedCompositor.swift](../../Sources/TimelineKit/Rendering/UnifiedCompositor.swift)（≈ 行 135-156）| `request.sourceFrame(byTrackID:)` 取像素，无源时 `finish(with: missingFrame)`；不存在「图层从 URL 加载 CIImage + 应用变换 + 输出」分支 | [image-layer-rendering-spec.md](image-layer-rendering-spec.md) §4 |
| 缺 anchor 维度 | [EditorSegment.swift](../../Sources/TimelineKit/Models/EditorSegment.swift) `KeyframeSet`（≈ 行 38-48）| scale 关键帧无锚点字段，复刻"缩放中心可控"必需 anchor | [keyframe-animation-spec.md](keyframe-animation-spec.md) §3.2 |
| 临时 MP4 缓存占用大 | StaticImageRenderer `/tmp/img_{key}.mp4`（≈ 行 66-73）| 缓存键仅 URL basename + motion + duration + size（无内容哈希）；编辑器中常驻 300MB+ 临时文件 | [transition-compat-spec.md](transition-compat-spec.md) §4 |

## 与 v1 / v2 / v3 / v4 / v5 的边界

- **v1**：渲染管线主路径（`CompositionBuilder.build` 现签名 + 烘焙路径）保留；本期改造点集中在 `resolveSegmentURL` 的图片分支与 `UnifiedCompositor` 的指令负载，未触碰 v1 锁定的字幕渲染与时间轴 scrub 状态机
- **v2**：transition / filter-color 两件 spec 完全不动；v2 `transition-spec.md` 被 [transition-compat-spec.md](transition-compat-spec.md) 反向引用，不修改主体
- **v3**：多轨架构、TextEditPanel、AudioEditPanel 入口全部沿用；本期不涉及 v3 任何能力
- **v4**：样式保真 / 批量 / 多轨滚动 / 文本排版 / 音频控制 7 份 spec 完全沿用；本期不修改其中任何代码
- **v5**：fullscreen-preview-spec / export-config-panel-spec / render-pipeline-unification-spec 三份 spec 推迟到 V6 P2 阶段执行，**沿用不重写**；V5.1 四项 BUG 修复保留

数据模型变更（最小加法、向下完全兼容）：

- `SegmentContent.ImageContent` 新增 `keyframes: KeyframeSet?` 字段（旧草稿 nil，加载后按 `motionPreset` / `depthEffect` 走 `AnimationMacro` 默认展开）
- `KeyframeSet` 新增 `anchor: [KeyframePoint<CGPoint>]`（旧草稿 nil → 默认锚点为 (0.5, 0.5)）
- 无任何字段删除、无重命名、无类型变更
- 服务端 TimelineExporter 不导出新字段（仅本地草稿层；server schema 不变）
