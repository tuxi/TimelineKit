# 导出流水线规范（v2）

> 状态：**框架待撰写**；**附录 A 已由 v5 填充**（§2 / §3 / §7 落地，§4 / §5 / §6 / §8 留待后续版本）
> 依赖：v1 渲染架构、v2 转场规范、v2 滤镜规范
> 修订记录：2026-05 v5 立项追加附录 A（详见末尾）

---

## 目录（待填充）

1. 竞品分析（剪映 / Final Cut Pro / LumaFusion）→ **v5 附录 A §A.1 已落地**
2. 导出分辨率与码率规则（720p / 1080p / 4K 档位）→ **v5 附录 A §A.1 已落地**
3. 编码格式（H.264 / HEVC / ProRes 选项）→ **v5 附录 A §A.2 已落地**（ProRes 暂不做）
4. 后台导出任务管理（`AVAssetExportSession` + BackgroundTask）→ 留待 v5 之后版本（v5 ❌ 明确延后）
5. 进度汇报与取消机制 → 留待后续；v5 仅沿用 v4 已有进度上报模式
6. 导出失败处理与重试策略 → 留待后续
7. 文件落盘路径与系统相册写入 → **v5 附录 A §A.3 已落地（路径沿用 V4）**
8. 验收标准 → 由各版本对应实现 spec 承载（v5 见 [docs/v5/render-pipeline-unification-spec.md](../v5/render-pipeline-unification-spec.md) §10）

---

## 附录 A：v5 修订条目（2026-05）

> v5 立项填充本附录，作为 v5 阶段「档位与编码格式」的**唯一权威来源**。
> v5 详细 spec 在：
> - [docs/v5/export-config-panel-spec.md](../v5/export-config-panel-spec.md) —— UI / 数据模型 / 持久化
> - [docs/v5/render-pipeline-unification-spec.md](../v5/render-pipeline-unification-spec.md) —— AVAssetWriter 改造 / 编码参数透传 / HDR
> - [docs/v5/competitive-benchmarks-v5.md](../v5/competitive-benchmarks-v5.md) —— 竞品对标（剪映 / CapCut / FCP / LumaFusion）
>
> v5 后任何档位 / 编码参数调整：**先改本附录，再同步代码常量表与 v5 spec**。

### A.1 分辨率 / 帧率 / 码率档位定档

档位选择依据见 [docs/v5/competitive-benchmarks-v5.md](../v5/competitive-benchmarks-v5.md) §1.2 / §1.3 / §1.4。

| 参数 | 档位 | 出厂默认 |
|---|---|---|
| 分辨率 | 480P (854×480) / 720P (1280×720) / 1080P (1920×1080) / 2K (2560×1440) / 4K (3840×2160) | **跟随画布**（按 `EditorTimeline.canvas` 短边匹配最接近档位）|
| 帧率 | 24 / 25 / 30 / 50 / 60 / 120 | **跟随画布**（按 `canvas.fps` 匹配最接近档位）|
| 码率档位 | 较低 / 推荐 / 较高 | **推荐** |
| 智能 HDR | 开 / 关 | **开** |

**默认分辨率/帧率跟随画布** —— 区别于剪映/CapCut 固定默认 1080P/30。理由：当前 [EditorCanvas.Preset](../../Sources/TimelineKit/Models/EditorCanvas.swift) 4 种预设（9:16 / 16:9 / 1:1 / 3:4）短边均为 720，若用固定 480P 默认会导致 720P canvas 工程默认导出 480P 反直觉；按 canvas 派生 → 720P canvas → 720P 默认，1080P 素材导入工程 → 1080P 默认。**默认 HDR 开** 由 v5 立项硬指定（区别于剪映/CapCut 默认 HDR 关），不支持设备静默降级。

派生规则：

- `ExportConfig.Resolution.matching(canvasShortSide:)`：候选 [480, 720, 1080, 1440, 2160]，距离最近优先，平局取更高保画质
- `ExportConfig.FrameRate.matching(canvasFPS:)`：候选 [24, 25, 30, 50, 60, 120]，同上规则
- 派生默认仅在 `metadata.exportConfig == nil` 时生效；用户首次 mutate 后持久化具体值，后续 canvas 变更不回溯

详见 [docs/v5/export-config-panel-spec.md](../v5/export-config-panel-spec.md) §3.1 / competitive-benchmarks-v5.md §1.2 / §1.3。

#### 基线码率（30fps，单位 Mbps）

| 分辨率 | 较低 | 推荐 | 较高 |
|---|---|---|---|
| 480P | 1.0 | 2.5 | 4.0 |
| 720P | 2.5 | 5 | 8 |
| 1080P | 5 | 8 | 12 |
| 2K | 10 | 16 | 24 |
| 4K | 20 | 35 | 50 |

#### 帧率倍率

| 帧率 | 倍率 |
|---|---|
| 24 / 25 / 30 | ×1.0 |
| 50 / 60 | ×1.2 |
| 120 | ×1.5 |

实际码率 = 基线 × 帧率倍率。

代码侧常量表落地在 `Rendering/ExportEncodingProfile.swift`，与本附录必须同步。

### A.2 编码格式

| 配置 | 编码器 | 像素格式 | 色彩空间 |
|---|---|---|---|
| SDR 480/720/1080 | H.264 | BGRA 8-bit | Rec.709 |
| SDR 2K/4K | HEVC (Main) | BGRA 8-bit | Rec.709 |
| HDR 全档位 | HEVC Main 10 | 420YpCbCr10 (10-bit YUV) | BT.2020 PQ |

容器：mp4（v4 已固定，v5 沿用）。
音频：AAC LC，128 kbps，44.1 kHz，立体声（v4 沿用）。

ProRes / DNxHD：v5 明确不做（移动端无消费场景），不列入档位。
Dolby Vision：v5 不做（iOS 17+ 才支持 DoVi 8.4），留作 v6/v7。

### A.3 AVAssetWriter 改造决策

#### A.3.1 必须改造的理由

`AVAssetExportSession` 架构上**无法**：
1. 独立控制码率（预设绑定 分辨率+质量，三档预设码率均不可改）
2. 独立控制色彩空间（无法配置 BT.2020 PQ）
3. 选择 HEVC Main 10（10-bit pixel format）

要支持本附录 A.1 三档码率 + A.2 HDR 编码，**没有第二条路**，v5 必须将 `VideoExporter.exportToFile` 由 AVAssetExportSession 改造为 `AVAssetWriter + AVAssetReader` 双向流模式。

#### A.3.2 既有先例

[StaticImageRenderer.swift:107-180](../../Sources/TimelineKit/Rendering/StaticImageRenderer.swift) 已用 AVAssetWriter + AVAssetWriterInput + AVAssetWriterInputPixelBufferAdaptor 模式实现静帧渲染。v5 在 VideoExporter 复用同一模式扩展到视频导出主路径，无新增第三方依赖。

#### A.3.3 分阶段降低风险

| 阶段 | 范围 | 编码 |
|---|---|---|
| **M3（SDR 全档位）** | 5 档分辨率 × 6 档帧率 × 3 档码率 端到端打通 | H.264（≤1080P）+ HEVC（≥2K）+ Rec.709 |
| **M4（HDR 增量）** | HDR Toggle 解禁 | HEVC Main 10 + BT.2020 PQ |

M3 不上 HDR 的理由：HEVC Main 10 编码涉及 10-bit pixel format、`kCVImageBufferTransferFunction_ITU_R_2100_PQ` 配置、设备能力检测、降级路径，工程量翻倍。先把 SDR 全档位打通让导出参数面板上线可用，HDR 留作 M4 增量。UI 层面 M3 阶段 HDR Toggle 始终 disabled，显示"智能 HDR 即将上线"。

#### A.3.4 公共 API 锁定

- `VideoExporter.export(timeline:)` 签名不变（对 ExportResultView / ClipEditorView 调用方零修改）
- `CompositionBuilder.build` 新增 `renderSize: CGSize?` / `fps: Double?` 必须为可选，nil 时行为与 v4 完全一致（旧调用点零修改）

#### A.3.5 失败降级

| 失败场景 | 行为 |
|---|---|
| AVAssetWriter 创建失败 | 抛错；ExportResultView 显示错误消息 |
| canAdd(videoInput) 返回 false | 抛错（编码参数组合不支持） |
| HDR 设备不支持 | 静默降级 SDR；UI Toggle 禁用 + 提示"当前设备不支持 HDR 编码" |
| 视频帧 append 失败 / writer.finishWriting 状态异常 | 抛错；temp 文件清理 |

错误码沿用 v4 `NSError(domain: "VideoExporter", code: -1...-N)` 模式。

### A.4 文件落盘（沿用 v4）

`FileManager.default.temporaryDirectory.appendingPathComponent("TimelineExport_<uuid>.mp4")`（[VideoExporter.swift:94-97](../../Sources/TimelineKit/Export/VideoExporter.swift) v4 现状）。

写入系统相册由 ExportResultView 负责（v4 已有逻辑），本附录不变更。

### A.5 进度上报（沿用 v4 节奏）

v4 用 Task 轮询 session.progress；v5 改用视频帧 pts 作为进度源（30Hz 同步更新），体感与 v4 一致。详见 [docs/v5/render-pipeline-unification-spec.md](../v5/render-pipeline-unification-spec.md) §4.5。

### A.6 持久化（v5 新增）

导出配置写入 `EditorMetadata.exportConfig: ExportConfig?`（v5 新增字段），Codable 默认合成自动兼容旧草稿（nil → 按 `canvas` 派生默认，见上 §A.1）。读取统一走 `EditorTimeline.effectiveExportConfig` 计算属性。详见 [docs/v5/export-config-panel-spec.md](../v5/export-config-panel-spec.md) §3 / §7。

服务端 TimelineExporter schema **不**导出 `exportConfig`（仅本地草稿层）。

### A.7 v5 主动放弃的能力（留给后续版本）

| 能力 | 放弃理由 |
|---|---|
| 自定义码率 Mbps 滑杆 | 移动端用户不会输 Mbps；三档预设覆盖 95% 场景 |
| Dolby Vision / HDR10+ | iOS 17+ 才支持 DoVi 8.4；v5 不上，留作 v6/v7 |
| PQ / HLG 双选 | FCP 专业能力；移动端无消费场景 |
| 5K / 8K 分辨率 | iOS 设备稀有 |
| 23.98 / 29.97 / 59.94 电视广播帧率 | 移动端无消费场景 |
| ProRes / DNxHD | 移动端无消费场景 |
| 后台静默导出（应用退后台继续）| 涉及 BackgroundTask 权限，留待 v5 之后版本（对应本规范 §4） |
