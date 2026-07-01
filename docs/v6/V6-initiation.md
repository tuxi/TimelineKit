# TimelineKit V6 立项书

> 版本：v6.0
> 状态：立项定稿，待各 spec 拆任务执行
> 对标产品：剪映 iOS 13.0+（移动端主对标）+ CapCut Desktop 3.0+ / CapCut Web + Final Cut Pro 11 / FCP for iPad 2.x + LumaFusion 5.x
> 依赖：v1 时间轴 / 字幕 / 音频交互基线，v2 渲染特性 spec（沿用、`transition-spec.md` 被本版反向引用），v3 多轨 / 文本 / 音频 / TTS 已上线，v4 样式保真 / 批量 / 多轨滚动 / 文本排版 / 音频控制规范定稿，v5 同源预览 / 导出参数 / AVAssetWriter 改造 spec（延期到 V6 P2 接入，**沿用不重写**）

---

## 一、立项背景

V5 + V5.1（详见 v5/V5-initiation.md + `memory/project_timelinekit_v5_1.md`）收尾后，**剪辑层体验已对齐主流**，但时间轴底层渲染体系仍残留两类系统性硬伤——这两点 V5 范围内**无法增量解决**，必须在底层结构上动刀。

### 1. 预合成 MP4 桎梏（最大架构债）

[StaticImageRenderer.swift](../../Sources/TimelineKit/Rendering/StaticImageRenderer.swift) 现状：所有 `image / image_motion / image_3d` 段落都被预渲染为 MP4 文件落盘（`/tmp/img_{key}.mp4`），再以 AVURLAsset 加载、取 AVAssetTrack、调 [CompositionBuilder.swift `resolveSegmentURL`](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) 行 672-697 → `assetTrack.insertTimeRange(...)` 挂到 AVMutableComposition。

直接副作用：

- **静态图 1fps / 动效图全 fps 差异化编码**：StaticImageRenderer 行 105 根据 `motionPreset / depthEffect` 是否存在切换 fps，两套帧时序在转场时常错位
- **sentinel 帧 + setOpacity 钳尾帧的脆弱兜底**：StaticImageRenderer 行 173-207 通过末尾追加一帧 + 旧 `setOpacity(0, at: mainVideoEnd)` 防止尾帧滞留，对 image_motion / image_3d 不可靠（V5.1 已用 dual-composition-track + instruction 切分救火，但 unified 路径 + overlay 组合仍有遗留）
- **AI 工程转场尾帧冻结 vs 自由剪辑正常 = 同段素材两种行为**：差异化 fps + sentinel 兜底是根因；用户对此类 BUG 完全无法预期
- **临时文件 IO + 帧率不一致**：编辑器中常驻 300MB+ 临时 MP4；缓存键（StaticImageRenderer 行 66-73）仅 URL basename + motion + duration + size，无内容哈希，长会话累积失效缓存

### 2. AI 动画参数损耗

[ServerTimelineSchema.swift](../../Sources/TimelineKit/Conversion/ServerTimelineSchema.swift) 已定义 `SImageAnimation.scaleFrom/scaleTo/translateXFrom/opacityTo`、`SDepthModel.centerX/innerRadius/outerRadius/nearValue/farValue/falloff`、`SCamera.intensity` 等连续参数，但 [TimelineImporter.swift](../../Sources/TimelineKit/Conversion/TimelineImporter.swift) 行 93-150 解码时**几乎全部丢弃**：

- `SImageAnimation` 仅取 `.type` 字段映射到 `ImageMotionPreset` 枚举（zoom_in / pan_left 等 6 方向预设），scaleFrom / scaleTo / translate / opacityTo 全部丢
- `SDepthModel`（深度图配置）完全未解码、未消费
- `SCamera.intensity` 仅作为 `DepthEffect.intensity` 透传，下游 StaticImageRenderer 不消费

后果：server 下发的连续动画参数被降级为有限预设，**相册导入图片 vs AI 下发图片**渲染表现漂移，无法做到「同样的素材在两种入口产生一致的预览/成片」。

### 排期依据：先 P0 架构打底 → 再 P1 兼容补齐 → P2 上层业务并行

两件事在底层耦合：**废除 MP4 prebake 必须重构 UnifiedCompositor 让它消费「无 AVAssetTrack 源的图片图层」；同一次改造顺带把关键帧动画底座搭起来，把 AI 动画参数全部消费起来**。先做 P0 架构打底（image-layer-rendering + keyframe-animation + ai-timeline-mapping + layer-rendering-rules 四件 spec），P1 处理转场 / 性能 / 缓存兼容，P2 复用 V5 已有 spec 接入上层业务功能，工程经济性最高。

V6 不增加任何新的剪辑维度，只重塑底层 + 顺势搭关键帧底座。

---

## 二、范围围栏

### 2.1 ✅ V6 必做（本期 P0 + P1）

| 优先级 | 序号 | 项目 | 落地 spec |
|---|---|---|---|
| **P0-A** | 1 | 废除 StaticImageRenderer 预合成 MP4 路径；图片以「原生图层」形式挂到时间轴；UnifiedCompositor 扩展为支持「无 AVAssetTrack 源」的纯图片图层渲染 | [image-layer-rendering-spec.md](image-layer-rendering-spec.md) |
| **P0-B** | 2 | 关键帧 5 维（position / scale / rotation / anchor / opacity）数据模型 + 缓动曲线（linear / ease / easeIn / easeOut / cubicBezier）+ 播放进度驱动求值器；FCP 风格 40 段 LUT 预采样 | [keyframe-animation-spec.md](keyframe-animation-spec.md) |
| **P0-C** | 3 | `SImageAnimation` / `SDepthModel` / `SCamera` → 关键帧端到端映射；`AnimationMacro` 把 `motionPreset` / `depthEffect` 预设展开为关键帧序列；相册图 + AI 图统一数据层 | [ai-timeline-mapping-spec.md](ai-timeline-mapping-spec.md) |
| **P0-D** | 4 | 主轨尾段黑屏 / overlay 透出 / 动画末态停驻 / 全局帧率对齐 等渲染层硬规则在 unified 单一路径下固化 | [layer-rendering-rules-spec.md](layer-rendering-rules-spec.md) |
| **P1** | 5 | 转场与关键帧图层共存（转场只作用于图层交界，不冻结关键帧求值）；多图层实时预览性能；替换 StaticImageRenderer 的 MP4 缓存为「CIImage + 参数」轻量化缓存；导出链路对齐 | [transition-compat-spec.md](transition-compat-spec.md) |

### 2.2 🟡 V6 沿用既有 spec（不重写，仅引用）

| 优先级 | 项目 | 复用 spec |
|---|---|---|
| P2 | 全屏同源真实预览 | [docs/v5/fullscreen-preview-spec.md](../v5/fullscreen-preview-spec.md) |
| P2 | 导出参数配置面板 | [docs/v5/export-config-panel-spec.md](../v5/export-config-panel-spec.md) |
| P2 | AVAssetWriter 改造（替换 AVAssetExportSession）| [docs/v5/render-pipeline-unification-spec.md](../v5/render-pipeline-unification-spec.md) |
| P1 反向引用 | 转场 spec（v2 占位）| [docs/v2/transition-spec.md](../v2/transition-spec.md) ← 被 [transition-compat-spec.md](transition-compat-spec.md) 引用 |

V6 严守 v4-initiation §2.2 / §3.2 立的硬规则：**v2/v5 既有 spec 完全不动**。V5 三份 spec 中的代码改动延期到 V6 P2 阶段执行，但 spec 本身**不在 V6 目录内重立**，保持唯一权威来源。

### 2.3 🕓 V6 留 roadmap（P0/P1 上线后单独立 spec）

| 优先级 | 项目 | 备注 |
|---|---|---|
| P2 | APP 端首页「开始创作」独立素材选择入口 | 与 V5 留 roadmap 的"空白工程入口"合并执行；P0 架构稳定后立 spec |
| P2 | 我的页面草稿列表管理（基于 TimelineCache 工程包）| 工程包持久化与列表 UI 设计；P0 架构稳定后立 spec |
| P3 | 自定义贝塞尔关键帧路径编辑 UI | 在 V6 关键帧底座之上做用户级路径编辑；当前 V6 不暴露 UI，仅 server 端可生成 |
| P3 | 蒙版动画 / 多维度形变 / Z 轴 / skew | V6 关键帧只做 5 维 MVP；这些维度推到 V6.1+ |
| P3 | 草稿模板 / 工程模板（一键复用）| DraftStore 多入口扩展 |
| P3 | 多端协作 / 云端工程 | 服务端 schema 重设计 |

### 2.4 ❌ V6 暂不做（明确延后）

| 项目 | 理由 |
|---|---|
| 物理删除 StaticImageRenderer.swift | V6 完成后下个版本再决定；保留代码作历史参考，避免立项期间用户手上还有运行中实例 |
| 编辑画布 SwiftUI 叠加层升级到 CIImage 出帧 | V5 留 V6/V7 议题；V6 仍只做底层 compositor，不动 SwiftUI 字幕/文本叠加层 |
| 关键帧 UI 编辑（在编辑器里手动打点）| V6 关键帧底座主要消费 server 下发参数；用户级 UI 编辑推到 V6.1+ |
| CATransform3D 真 3D 变换 | 2.5D parallax 用「分层 2D 图层 + 各自关键帧」实现（剪映模型），不引入真 3D |
| ProRes / DNxHD 专业编码 | 同 V5 ❌ 理由 |
| AI 字幕翻译 / 卡拉 OK 高亮 | 同 V4 ❌ 理由 |
| Dolby Vision / HDR10+ | 同 V5 ❌ 理由 |

---

## 三、与 v1 / v2 / v3 / v4 / v5 边界

### 3.1 不改动 v1 / v2 / v3 / v4 / v5 任何已锁文件

v1 / v2 / v3 / v4 / v5 文档与代码全部沿用。V6 仅做以下**加法 + 内部重构**：

**新增代码文件（4）**：

- `Sources/TimelineKit/Rendering/ImageLayerComposer.swift` — 图片图层求值器（无 AVAssetTrack 源），输入 ImageLayerSpec（URL + 关键帧），输出 CIImage
- `Sources/TimelineKit/Animation/KeyframeEvaluator.swift` — 关键帧时间因子 → 变换矩阵求值
- `Sources/TimelineKit/Animation/EasingCurve.swift` — 缓动曲线表（linear / ease / easeIn / easeOut / cubicBezier(p1, p2)），FCP 风格 40 段 LUT 预采样
- `Sources/TimelineKit/Animation/AnimationMacro.swift` — `motionPreset` / `depthEffect` → 关键帧序列展开器

**修改既有代码（精确到 file:line，按 spec 拆分细节）**：

- [Rendering/CompositionBuilder.swift](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) 行 672-697 `resolveSegmentURL`：删除图片分支的 StaticImageRenderer 调用；图片段落改为构造 `LayerInstruction.imagePayload`（新结构体）注入 `UnifiedCompositorInstruction`；**强制图片段落全部走 unified 路径**（消灭 single-pass 上的图片分支）
- [Rendering/UnifiedCompositor.swift](../../Sources/TimelineKit/Rendering/UnifiedCompositor.swift) 行 96-354：`UnifiedCompositorInstruction` 新增 `imageLayers: [ImageLayerSpec]` 字段；`startRequest` 检测到 imageLayers 时调用 `ImageLayerComposer.evaluate(at: compositionTime)` 获取 CIImage 链；移除 `requiredSourceTrackIDs` 对图片段落的依赖；保留 isBlackOut 路径与字幕烘焙路径（V5.1 落地）
- [Conversion/TimelineImporter.swift](../../Sources/TimelineKit/Conversion/TimelineImporter.swift) 行 93-150：重写 image_motion / image_3d 解码；`SImageAnimation.scaleFrom/scaleTo/translateXFrom/opacityTo` → KeyframeSet；`SCamera.move + intensity + duration` → KeyframeSet；`SDepthModel.centerX/innerRadius/outerRadius/nearValue/farValue/falloff` → 2.5D parallax 多层展开
- [Models/SegmentContent.swift](../../Sources/TimelineKit/Models/SegmentContent.swift) 行 33-51 `ImageContent`：新增 `keyframes: KeyframeSet?` 字段（Codable `decodeIfPresent` 容错，旧草稿 nil → 按 `motionPreset / depthEffect` 走 AnimationMacro 默认展开）；保留 `motionPreset / depthEffect` 作为「预设入口」语法糖，运行时一律展开
- [Models/EditorSegment.swift](../../Sources/TimelineKit/Models/EditorSegment.swift) 行 38-48 `KeyframeSet`：新增 `anchor: [KeyframePoint<CGPoint>]`（旧草稿 nil → 默认锚点 (0.5, 0.5)）

**完全不动文件**：

- v1 全部 / v2 全部 / v3 全部 / v4 全部 / v5 全部 spec
- [Models/EditorCanvas.swift](../../Sources/TimelineKit/Models/EditorCanvas.swift)（canvas 是工程的画幅基线）
- [Models/EditorTimeline.swift](../../Sources/TimelineKit/Models/EditorTimeline.swift)（EditorMetadata 不动）
- 草稿 schema 主路径（无字段删除 / 无重命名 / 无类型变更）
- [Views/TextOverlayView 与 SubtitleStackView](../../Sources/TimelineKit/Views/)（编辑画布 SwiftUI 叠加层与交互完全保持原样）
- [Rendering/ColorAdjustmentCompositor.swift](../../Sources/TimelineKit/Rendering/ColorAdjustmentCompositor.swift)（调色 compositor 不动）
- [Rendering/StaticImageRenderer.swift](../../Sources/TimelineKit/Rendering/StaticImageRenderer.swift)（保留代码，仅在 V6 全部完成后断引用；物理删除推到下个版本）

### 3.2 v2 spec 处置：transition-compat-spec.md 反向引用

[docs/v2/transition-spec.md](../v2/transition-spec.md) 不动。V6 P1 阶段的 [transition-compat-spec.md](transition-compat-spec.md) 反向引用 v2 转场规则集，并明确补充「关键帧图层在转场期间的求值规则」段落（与 v2 主体互引）。

### 3.3 数据模型变更（最小加法、向下完全兼容）

- `SegmentContent.ImageContent` 新增 `keyframes: KeyframeSet?`，旧草稿 nil；加载后由 `AnimationMacro.expand(motionPreset, depthEffect, duration)` 按预设生成默认关键帧序列
- `KeyframeSet` 新增 `anchor: [KeyframePoint<CGPoint>]?`，旧草稿 nil → 默认锚点 (0.5, 0.5)
- 无任何字段删除、无重命名、无类型变更
- 服务端 TimelineExporter schema **不变**（V6 不动 server 协议，仅在客户端解码层多消费几个已存在字段）

### 3.4 兼容承诺

- v1 / v2 / v3 / v4 / v5 旧草稿 100% 加载；`ImageContent.keyframes == nil` 时按 `motionPreset / depthEffect` 走 AnimationMacro 默认展开，视觉与 V5 StaticImageRenderer 对齐 ±2px
- `CompositionBuilder.build` 公共签名不变（V5 引入的 renderSize / fps 参数保留）
- `VideoExporter.export(timeline:)` 公共签名不变
- V5.1 三项已知遗留（unified 路径 overlay 不渲染 / FullScreenPreview + 字幕 + overlay 不可见 / v1 trim handle 超 nativeDuration）在 V6 渲染统一后**天然消解**，无需单独修复
- v4 已锁的固定交互约束全部沿用（详见第七节）

---

## 四、里程碑排期

| 里程碑 | 工作内容 | 关键交付 |
|---|---|---|
| **M1（P0-A）图片图层最小可播** | [image-layer-rendering-spec.md](image-layer-rendering-spec.md) §2-§4 + [keyframe-animation-spec.md](keyframe-animation-spec.md) §3-§4 | `ImageLayerComposer` + `KeyframeEvaluator` + `EasingCurve` 落地；UnifiedCompositor 新增 imageLayers 字段；静态相册图（无动画）能跑通预览播放；可独立验证基础架构 |
| **M2（P0-B）AI 动画统一映射** | [ai-timeline-mapping-spec.md](ai-timeline-mapping-spec.md) §2-§4 + [keyframe-animation-spec.md](keyframe-animation-spec.md) §5（AnimationMacro）| `TimelineImporter` 重写；`SImageAnimation` / `SCamera` 全字段映射到关键帧；`SDepthModel` 映射为 2.5D parallax 多层展开；`AnimationMacro` 把 `motionPreset` / `depthEffect` 展开 |
| **M3（P0-C）渲染规则固化** | [layer-rendering-rules-spec.md](layer-rendering-rules-spec.md) 全文 | 主轨尾段黑屏 / overlay 透出 / 动画末态停驻 / 全局帧率对齐 等规则在 unified 单一路径下闭环；V5.1 遗留三项消解 |
| **M4（P1）转场 + 性能 + 缓存** | [transition-compat-spec.md](transition-compat-spec.md) 全文 | 转场与关键帧图层共存（转场不冻结关键帧求值）；多图层实时预览性能达标；MP4 临时缓存替换为「CIImage + 参数」轻量缓存；导出链路对齐 |
| **P4（VideoFrameProvider 性能化）** | [video-frame-provider-performance-plan.md](video-frame-provider-performance-plan.md) 全文 | `VideoFrameProvider` 从 `AVAssetImageGenerator.copyCGImage` 验证路径升级为 source-level `AVPlayerItemVideoOutput -> CVPixelBuffer` 实时预览路径；已解决 image->video 黑屏、播放态逐帧 seek、`compositionTime=0` 重复 forced copy，剩余 warm-frame 与 benchmark |
| **M5（P2）上层业务接入** | 沿用 [docs/v5/fullscreen-preview-spec.md](../v5/fullscreen-preview-spec.md) + [docs/v5/export-config-panel-spec.md](../v5/export-config-panel-spec.md) + [docs/v5/render-pipeline-unification-spec.md](../v5/render-pipeline-unification-spec.md) + 新增「开始创作」入口 + 草稿列表 spec 单独立项 | V5 三件 spec 在 V6 新架构上接入；创作入口 / 草稿列表 spec 立项后并行执行 |
| **M6 真机回归 + 封版** | 跨特性回归 + v1-v5 旧草稿 100% 加载 + 真机重负载验收 | V6 验收清单全绿；AI 工程全类型动效 timeline 播放 0 冻结 / 0 错位；自由剪辑 + AI 工程行为一致性矩阵全绿 |

排期严格按用户给出的「先 P0 架构打底 → 再 P1 兼容补齐 → P2 上层业务并行」推进。

- **M1 是所有后续里程碑的前置**：基建未落地之前 M2/M3 没有宿主，不可并行
- **M2 与 M3 不并行**：M3 渲染规则验证依赖 AI 动效素材跑通
- **M4 在 M3 完成后做**：转场逻辑需要 M3 渲染规则稳定才能确定 instruction 切分边界
- **P4 在 mixed timeline Runtime 跑通后做**：P3 的 `AVAssetImageGenerator.copyCGImage` 只保留为 export/debug fallback，TimelineRuntime preview 主链路使用 source-level `AVPlayerItemVideoOutput -> CVPixelBuffer`
- **M5 是业务层并行**，与 M4 性能优化无文件交集

---

## 五、风险与依赖

### 5.1 技术风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| UnifiedCompositor 改造涉及核心渲染管线，回归面大 | M1 阶段失稳，编辑器不可用 | M1 先做"静态图无动画"最小路径打通；M2 再叠加动画；M3 再做尾段/overlay 规则；M6 真机回归全用例矩阵 |
| 多图层 + 关键帧实时预览性能不达标 | M4 阶段 30fps 不稳 | 用 `CVPixelBufferPool` 复用缓冲；共享 `CIContext(mtlDevice:)`；3 层以上 image_3d 自动降级单层；详见 [image-layer-rendering-spec.md](image-layer-rendering-spec.md) §5 |
| `motionPreset` / `depthEffect` 展开为关键帧后视觉与 StaticImageRenderer 不一致 | 用户感知"动画变了"，AI 历史工程崩塌 | M2 阶段建「视觉对齐对照矩阵」：12 个 motionPreset × 6 方向 × 3 时长 全部截屏与 V5 StaticImageRenderer ±2px diff 验证 |
| 2.5D parallax 分层展开（SDepthModel）实现复杂 | M2 单期工期失控 | 先做"中心 + 单层 falloff"简化模型对齐 V5 视觉；多层 inpainting 推到 V6.1+ |
| 自由剪辑（用户手动拖拽时长）的关键帧时间规范化 | 用户改 segment 时长后动画错位 | KeyframeEvaluator 用 0~1 标准化时间因子；segment 时长变化时关键帧时间因子不变，绝对时间自动重新映射 |
| Codable `keyframes / anchor` 反序列化失败 | 老草稿打开崩 | 所有新字段用 `decodeIfPresent` 容错；缺失走 AnimationMacro 默认展开 |
| StaticImageRenderer 旧调用方残留 | V6 上线后仍有 prebake 路径 | M3 收尾前用 `grep -r StaticImageRenderer` 全仓审计调用方；保留代码但断所有引用，编译期不可达 |
| Server 下发非法关键帧（duration=0 / 数值越界）| 求值器崩溃或动画不可见 | KeyframeEvaluator 输入做卫语句：duration < 1ms 当静止处理；NaN / Inf 兜底为身份变换 |
| iOS 17 以下 CIContext + Metal 设备能力差异 | 老机型预览卡顿 | 使用 `MTLCreateSystemDefaultDevice()`；不可用降级 CPU CIContext；详见 [image-layer-rendering-spec.md](image-layer-rendering-spec.md) §5 |

### 5.2 外部依赖

- **v2/transition-spec.md**：被 [transition-compat-spec.md](transition-compat-spec.md) 反向引用，作为转场规则集权威来源
- **v5 三份 spec**（fullscreen-preview / export-config-panel / render-pipeline-unification）：P2 阶段沿用，spec 主体不动
- **Server schema**：V6 不动 server 协议；仅多消费已存在但被丢弃的字段（`SImageAnimation` / `SDepthModel` / `SCamera` 完整字段集）
- **iOS 平台 API**：
  - `AVAsynchronousVideoCompositionRequest`（iOS 9+，全代支持）
  - `CIImage` / `CIContext(mtlDevice:)`（iOS 9+，全代支持）
  - `CVPixelBufferPool`（iOS 4+，全代支持）
  - `CGAffineTransform`（全代支持）

---

## 六、验收 KPI

### 6.1 功能闭环

| KPI | 标准 |
|---|---|
| 相册导入静态图 | 预览 + 导出像素一致；段尾停驻不回溯上一片段尾帧 |
| AI 下发 image_motion（6 方向）| 动画曲线与 V5 StaticImageRenderer 视觉对齐 ±2px；12 个 motionPreset × 3 时长矩阵全绿 |
| AI 下发 image_3d（6 方向 × 3 intensity 档）| 2.5D parallax 多层渲染正常；视觉与 V5 ±2px 对齐 |
| 混合排布（相册 + AI 视频 + AI 动效图）| 转场前后无尾帧冻结、无 fps 跳变；切点连续；末态停驻 |
| 关键帧 5 维（position / scale / rotation / anchor / opacity）| 单独 + 组合各跑一遍；缓动曲线 5 种（linear / ease / easeIn / easeOut / cubicBezier）全绿 |
| StaticImageRenderer 调用方清零 | `grep -r "StaticImageRenderer" Sources/` 仅命中 StaticImageRenderer.swift 自身（保留未删除）|
| V5.1 三项遗留消解 | unified 路径 overlay 正常渲染 / FullScreenPreview + 字幕 + overlay 三者共存可见 / trim handle 不再超 nativeDuration |
| 旧草稿（v1/v2/v3/v4/v5）打开 | 100% 兼容；`ImageContent.keyframes == nil` 自动按 motionPreset / depthEffect 走 AnimationMacro 默认展开 |
| Server 下发新参数被消费 | `SImageAnimation.scaleFrom/scaleTo` / `SDepthModel` / `SCamera.intensity` 在导入后转化为关键帧并影响渲染 |

### 6.2 性能

| 操作 | 标准 |
|---|---|
| 单图片层预览 60fps 稳定 | ≥ 58fps（iPhone 13 baseline）|
| 3 层 image_3d 同屏预览 | ≥ 30fps（iPhone 13） |
| AI 工程导入 → 首帧 | ≤ 800ms（旧路径含 prebake ≈ 2s）|
| 临时缓存峰值（编辑 5min 后）| < 100MB（旧路径 MP4 缓存常驻 300MB+）|
| 1080P / 30fps / 60s 导出耗时 | 与 V5 持平 ±10%（不退化）|

### 6.3 稳定性 & 兼容

| KPI | 标准 |
|---|---|
| 加载 v1 / v2 / v3 / v4 / v5 旧草稿 | 100% 兼容；新字段反序列化为 `nil` |
| 用户手动改 segment 时长后 | 关键帧时间因子不变，动画自然伸缩，无错位 |
| 编辑过程中切换工程 | 临时 CIImage 缓存正常释放，无残留内存 |
| 12 组代表组合（相册/AI/混合 × 转场/无转场 × 单层/多层）连续导出 | 0 崩溃；任一组失败不影响后续 |
| 4 层 image_3d + 转场 + 字幕 60s 重负载 | 真机不崩；首帧 ≤ 1.5s |

---

## 七、固定交互约束（V3 已锁 + V4/V5 沿用，V6 全程沿用，禁止改动）

| 约束 | 来源 |
|---|---|
| 轨道点击仅选中唤起快捷操作栏，**不遮挡轨道编辑区**；预览画布点击直接唤起完整编辑面板 | V3 已定稿 |
| 文本、字幕统一共用 `TextEditPanel` 唯一编辑面板，仅区分是否展示朗读功能、位置调节 Tab | V3 [text-entry-spec.md](../v3/text-entry-spec.md) |
| 底部工具栏严格区分两种场景：无选中片段仅展示新建入口，选中片段仅展示编辑快捷操作 | V3 已定稿 |
| 所有新增功能必须适配旧版草稿，做到向下完全兼容 | V3 [V3-initiation.md](../v3/V3-initiation.md) §3.1 |
| 安卓 / iOS 双端交互逻辑保持统一 | V3 已定稿 |
| `mutateSubtitle` 不重建 compositionVersion（S-04）| V1 已锁，V4/V5 沿用 |
| `isMainTrack` 唯一性 | V1 已锁，V3/V4/V5 沿用 |
| 全屏预览即沉浸式只读上下文（不可在全屏内编辑）| V5 已定稿 |
| 导出公共 API 签名锁定（`VideoExporter.export(timeline:)`）| V5 已定稿 |
| `CompositionBuilder.build` 向后兼容（renderSize / fps 可选）| V5 已定稿 |

V6 自身新增的隐性约束（写入各 spec）：

- **图片图层渲染走唯一 unified 路径**：V6 起 single-pass 路径不再处理图片段落；视频段落可保留 single-pass 路径作短路优化
- **关键帧 5 维即 MVP 上限**：position / scale / rotation / anchor / opacity；skew / Z / 3D 实变换、自定义贝塞尔路径全部推到 V6.1+
- **预设作为语法糖、运行时一律展开为关键帧**：`motionPreset` / `depthEffect` 不在播放/导出链路单独成分支；UI 层保留预设入口
- **关键帧时间因子标准化（0~1）**：用户改 segment 时长时关键帧时间因子不变，绝对时间自动重新映射
- **2.5D parallax 用分层 2D 图层实现**：不引入 CATransform3D，保持渲染路径单一
- **StaticImageRenderer.swift 保留代码作历史参考**：V6 完成后所有调用方清零，物理删除推到下个版本

每份 v6 spec 末尾必须重申一遍以上约束，确保实现时不漂移。

---

## 八、不在本立项范围

- 任何代码改动：留待 5 份 spec 各自的实现 PR（按 M1 → M6 排期推进）
- v1 / v2 / v3 / v4 / v5 已有文档的修订（V6 是底层重构 + 加法；v2/v5 仅在 transition-compat-spec 反向引用，不改主体）
- StaticImageRenderer.swift 物理删除（V6 完成后下个版本再决定）
- 创作入口 / 草稿列表 / 草稿模板 / 后台导出 / ProRes / DoVi / 多端协作 / 蒙版动画 / 真 3D 变换（详见 §2.3 / §2.4）
- 编辑画布 SwiftUI 叠加层升级到 CIImage 出帧（V5 留 V6/V7 议题；本期 V6 仍只做底层 compositor，不动 SwiftUI 叠加层）
- 用户级关键帧 UI 编辑（V6.1+）
- 服务端 TimelineExporter schema 谈判（V6 不动 server 协议）

---

## 九、文档间引用图

```
docs/v6/
   ├── README.md
   ├── V6-initiation.md  (本文档)
   ├── competitive-benchmarks-v6.md
   │      ↳ 被 5 份 spec 引用：图片图层 + 关键帧 + 2.5D parallax 的对标依据集中维护
   ├── image-layer-rendering-spec.md (P0-A)
   │      ↳ 依赖 v1 avfoundation-rendering-architecture：unified compositor 基础
   │      ↳ 被 keyframe-animation-spec / ai-timeline-mapping-spec / layer-rendering-rules-spec / transition-compat-spec 依赖
   ├── keyframe-animation-spec.md (P0-B)
   │      ↳ 依赖 image-layer-rendering-spec：图层求值器宿主
   │      ↳ 被 ai-timeline-mapping-spec / transition-compat-spec 依赖
   ├── ai-timeline-mapping-spec.md (P0-C)
   │      ↳ 依赖 image-layer-rendering-spec / keyframe-animation-spec
   │      ↳ 反向引用 Conversion/ServerTimelineSchema.swift 全部图片/动效字段
   ├── layer-rendering-rules-spec.md (P0-D)
   │      ↳ 依赖 image-layer-rendering-spec
   │      ↳ 收编 V5.1 三项遗留处理规则
   └── transition-compat-spec.md (P1)
          ↳ 依赖 image-layer-rendering-spec / keyframe-animation-spec
          ↳ 反向引用 docs/v2/transition-spec.md：转场规则集
          ↳ 反向引用 docs/v5/render-pipeline-unification-spec.md：导出链路对齐

外部依赖（沿用不重写）：
   - docs/v5/fullscreen-preview-spec.md       → V6 P2 接入
   - docs/v5/export-config-panel-spec.md      → V6 P2 接入
   - docs/v5/render-pipeline-unification-spec.md → V6 P2 接入
```

具体引用语义见各 spec「依赖」字段。
