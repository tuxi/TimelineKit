# TimelineKit V5 立项书

> 版本：v5.0
> 状态：立项定稿，待各 spec 拆任务执行
> 对标产品：剪映 iOS（移动端主对标） + CapCut Desktop + Final Cut Pro / FCP iPad + LumaFusion
> 依赖：v1 时间轴 / 字幕 / 音频交互基线，v2 渲染特性 spec（沿用，附录 A 内追加 v5 修订条目），v3 多轨 / 文本 / 音频 / TTS 已上线，v4 样式保真 / 批量 / 多轨滚动 / 文本排版 / 音频控制规范定稿

---

## 一、立项背景

V4 规范定稿（7 份 spec：样式保真 / 批量 / 多轨滚动 / 文本排版 / 音频控制 / 立项 / 竞品）实施完成后，剪辑体验已对齐主流。但 V4 上线复盘后，用户反馈两类痛点 V4 范围内**未覆盖、也无法通过现有 spec 增量解决**：

### 1. 预览 ≠ 成片（最大体验缺口）

编辑画布的字幕 / 文本走 SwiftUI 叠加层（`TextOverlayView` / `SubtitleStackView`），导出走 `SubtitleFrameBuilder.renderText` 的 CIImage / CALayer 烘焙路径——**两套绘制逻辑**。

V4 [text-style-fidelity-spec.md](../v4/text-style-fidelity-spec.md) 已对齐 12 个字段，把预览端字段消费补齐到导出端水平。但「预览=成片」并不等于「字段都读到了」：

- **描边**：SwiftUI `.stroke` 与 CoreText 双 draw 算法不同，亚像素抗锯齿表现存在系统差
- **阴影**：SwiftUI `.shadow` 与 `CGContext.setShadow` 模糊半径计算单位不同
- **背景圆角 + padding**：SwiftUI ZStack + `RoundedRectangle` 与 `CGContext.fill(roundedRect:)` 角点平滑度不同
- **层级 z-order**：SwiftUI ZStack 排序与 CALayer `zPosition` 在多段同时间重叠时表现差异
- **字幕基础渲染**：CoreText `CTLineDraw` vs Core Graphics `NSAttributedString.draw(in:)` 像素偏差

只要预览与导出是两条独立绘制路径，**像素差永远消不掉**。用户调到"看着满意"后导出，总会差一点；用户必须反复"导出 → 看效果 → 调样式 → 再导出"，效率极低。

### 2. 导出参数不可控

[VideoExporter.swift:74-80](../../Sources/TimelineKit/Export/VideoExporter.swift) 现状：

```swift
let preset: String = {
    let all = AVAssetExportSession.allExportPresets()
    if all.contains(AVAssetExportPreset1920x1080) { return AVAssetExportPreset1920x1080 }
    if all.contains(AVAssetExportPreset1280x720)  { return AVAssetExportPreset1280x720 }
    return AVAssetExportPresetMediumQuality
}()
```

`AVAssetExportPreset1920x1080 / 1280x720 / MediumQuality` 三选一硬编码，[VideoExporter.swift:89](../../Sources/TimelineKit/Export/VideoExporter.swift) 固定 mp4，无任何可调参数：

- 没有 4K / 2K / 480P 档位选择
- 没有帧率选择（24 / 25 / 30 / 50 / 60 / 120）
- 没有码率档位（较低 / 推荐 / 较高）
- 没有 HDR（HEVC Main 10 + BT.2020 PQ）

`AVAssetExportSession` 架构本身也**无法**控制码率与色彩空间——预设绑定分辨率+质量，要做参数化必须改造为 `AVAssetWriter`（参考既有先例 [StaticImageRenderer.swift:107-116](../../Sources/TimelineKit/Rendering/StaticImageRenderer.swift) 已用 AVAssetWriter 手写编码）。

### 排期依据：先 P0 同源预览 → 再 P1 导出参数

两件事在底层耦合：**导出参数化需要 AVAssetWriter，AVAssetWriter 改造的同时正好可以把预览管线统一到同一条出帧路径**。先做 P0 同源预览（建立"烘焙 composition + 独立 AVPlayer"基础设施），P1 导出参数化时直接复用 P0 的同源调用链，工程经济性最高。

V5 不增加任何新的剪辑维度，只补齐这两件刚需。其他能力（空白工程新建 / 草稿体系扩展 / 精细化手势 / 批量操作扩展 / 样式模板 / 后台导出任务管理）全部延后。

---

## 二、范围围栏

### 2.1 ✅ V5 必做（本期 P0 + P1）

| 优先级 | 序号 | 项目 | 落地 spec |
|---|---|---|---|
| **P0** | 1 | 同源全屏真实预览：底部 Controls 栏新增全屏按钮，全屏播放复用导出渲染管线，与成片像素一致 | [fullscreen-preview-spec.md](fullscreen-preview-spec.md) |
| P1 | 2 | 导出参数配置面板：顶部 toolbar 导出按钮左侧新增规格按钮，弹出 Sheet 配置 5 档分辨率 / 6 档帧率 / 3 档码率 / HDR 开关；参数持久化到工程 | [export-config-panel-spec.md](export-config-panel-spec.md) |
| P1 | 3 | VideoExporter 由 `AVAssetExportSession` 改造为 `AVAssetWriter`，码率 / HDR / 帧率 / 分辨率全部端到端真实生效；M3 H.264 SDR 全档位，M4 增量加 HEVC Main 10 + HDR PQ | [render-pipeline-unification-spec.md](render-pipeline-unification-spec.md) |

### 2.2 🟡 V5 沿用 v2 既有 spec（在 v2 原 spec 内追加修订条目）

| 优先级 | 项目 | 复用 spec |
|---|---|---|
| P1 | 导出分辨率 / 码率档位规则 / 编码格式选择 / 文件落盘路径 / 系统相册写入 | [docs/v2/export-pipeline-spec.md](../v2/export-pipeline-spec.md) 末尾「附录 A：v5 修订条目」 |

V5 严守 v4-initiation §2.2 / §3.2 立的硬规则：**v2 三件 spec 完全不动，必要修订在 v2 原 spec 内追加 vN 修订条目段落**。v2 的 `export-pipeline-spec.md` 虽然状态是「待撰写」、内容只有 8 节目录占位，**仍属于"已对外承诺归属 v2"**，v5 不在自己目录内重复立同名 spec。v5 通过附录 A 把档位表与 AVAssetWriter 决策回填给 v2，把"UI / 数据模型 / 持久化"与"渲染管线统一"两部分独立 spec 放在 v5 目录，与 v2 附录 A 互引。

### 2.3 🕓 V5 留 roadmap（P0/P1 上线后单独立 spec）

| 优先级 | 项目 | 备注 |
|---|---|---|
| P2 | 空白 Timeline 新建 / 全新草稿体系从零创作入口 | 草稿存储、二次编辑、工程初始化连带工作量大，避开 |
| P2 | 后台静默导出 + 通知中心进度 / 取消 | 涉及 BackgroundTask 与系统通知权限，单独立项 |
| P3 | 草稿模板 / 工程模板（一键复用） | DraftStore 多入口扩展 |
| P3 | 多端协作 / 云端工程 | 服务端 schema 重设计 |

### 2.4 ❌ V5 暂不做（明确延后）

| 项目 | 理由 |
|---|---|
| 各类精细化手势优化 | 不在本期容量；用户已明确"暂停" |
| 批量操作扩展（跨轨 / 多选 batch）| v4 P0 同轨同类批量已上线，再扩展需重新设计选择模型 |
| 样式模板（自定义保存 + 一键应用）| 与"草稿模板"同 P3 |
| ProRes / DNxHD 专业编码 | 移动端无消费场景；编码器集成成本高 |
| 关键帧动画（位置 / 缩放 / 透明度 keyframe）| 同 V4 ❌ 理由 |
| 全屏预览内允许编辑（拖拽字幕 / 二次调样式）| 全屏即沉浸式只读，符合主流剪辑器（剪映 / CapCut / FCP / LumaFusion）行为 |
| AI 字幕翻译 / 卡拉 OK 高亮 | 同 V4 ❌ 理由 |

---

## 三、与 v1 / v2 / v3 / v4 边界

### 3.1 不改动 v1 / v3 / v4 任何已锁文件

v1 / v3 / v4 文档与代码全部沿用。v5 仅做以下**加法**：

**新增代码文件（4）**：

- `Models/ExportConfig.swift` — 导出参数数据模型（独立文件，避免污染 EditorMetadata 主体）
- `Views/ExportConfigSheet.swift` — 导出参数配置面板（沿用 [TTSConfigSheet.swift:23-98](../../Sources/TimelineKit/Views/TTSConfigSheet.swift) 风格）
- `Views/FullScreenPreviewView.swift` — 全屏预览 SwiftUI 容器
- `Rendering/FullScreenPreviewController.swift` — 独立 AVPlayer + CompositionResult 持有者（不复用 [CompositionCoordinator.swift:14](../../Sources/TimelineKit/Rendering/CompositionCoordinator.swift)：它绑定编辑用 player 且 debounce 300ms 重建，与"打开瞬间即最终态"的语义不符）

**修改既有代码（精确到 file:line）**：

- [Models/EditorTimeline.swift:226-246](../../Sources/TimelineKit/Models/EditorTimeline.swift) `EditorMetadata` 新增 `var exportConfig: ExportConfig?`，Codable 用 `decodeIfPresent` 容错（旧草稿 nil → 按 canvas 派生默认）；同时在 `EditorTimeline` 加计算属性 `effectiveExportConfig: ExportConfig`（`metadata.exportConfig ?? .default(for: canvas)`），UI/渲染端统一从此读
- [Rendering/CompositionBuilder.swift](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) `build(from:renderSubtitles:)` 新增可选 `renderSize: CGSize?` / `fps: Double?` 参数，nil 时仍走 `timeline.canvas` 原行为（向后兼容）
- [Export/VideoExporter.swift:74-120](../../Sources/TimelineKit/Export/VideoExporter.swift) `exportToFile(_:)` 整体由 AVAssetExportSession 重写为 AVAssetWriter；**公共方法 `export(timeline:)` 签名不变**
- [Store/EditorStore.swift:11](../../Sources/TimelineKit/Store/EditorStore.swift) 新增 `mutateExportConfig(_ body:)` 方法（复用 v4 已落地的 mutate 模式）
- [Views/ClipEditorView.swift:197-199, 326-332](../../Sources/TimelineKit/Views/ClipEditorView.swift) toolbar 在 `exportButton` 左侧插入规格按钮 + sheet 绑定
- [Views/EditorControlBar.swift:8-34](../../Sources/TimelineKit/Views/EditorControlBar.swift) HStack 在 backward/play/forward 右侧追加全屏预览按钮

**完全不动文件**：

- v1 全部 / v3 全部 / v4 全部
- v2 `transition-spec.md` / v2 `filter-color-spec.md`
- [Models/EditorCanvas.swift](../../Sources/TimelineKit/Models/EditorCanvas.swift)（canvas 是工程的画幅基线，不掺导出运行时配置）
- [Models/EditorSegment.swift](../../Sources/TimelineKit/Models/EditorSegment.swift) / 所有 v3 多轨 / TTS 相关代码
- 草稿 schema 主路径（无字段删除 / 无重命名 / 无类型变更）
- [Views/TextOverlayView 与 SubtitleStackView](../../Sources/TimelineKit/Views/)（编辑画布 SwiftUI 叠加层与交互完全保持原样）

### 3.2 v2 spec 处置：附录 A 修订条目

[docs/v2/export-pipeline-spec.md](../v2/export-pipeline-spec.md) 现状是「待撰写 + 8 节目录占位」。V5 不在自己目录内重立同名 spec，而是在 v2 原文末尾追加：

```
## 附录 A：v5 修订条目（2026-05）

A.1 档位定档（v2 §2 + §3 留白由此填充）
A.2 编码格式（v2 §3）：M3 H.264 SDR / M4 HEVC Main 10 HDR PQ
A.3 AVAssetWriter 改造决策（替换 AVAssetExportSession）
A.4 反向引用：v5/export-config-panel-spec.md 与 v5/render-pipeline-unification-spec.md
```

v2 原 8 节目录保留不动；v2 §4 后台导出 / §5 进度汇报 / §6 失败重试 / §7 落盘路径 / §8 验收 留给 V5 之后的实现版本继续填充。

### 3.3 数据模型变更（最小加法、向下完全兼容）

- `EditorMetadata` 新增 `exportConfig: ExportConfig?`，旧草稿 = `nil`，加载后按 `canvas` 派生默认（分辨率/帧率自动匹配最接近档位；码率推荐；HDR 开）。当前 4 种 canvas 预设短边均为 720 → 默认导出 720P
- `EditorTimeline` 加计算属性 `effectiveExportConfig`（不挂在 `EditorMetadata` 上，因为派生需要 canvas）
- `ExportConfig` 自身是 Codable 独立结构体，含 4 字段（resolution / fps / bitrateTier / hdrEnabled）
- 无任何字段删除、无重命名、无类型变更
- 服务端 TimelineExporter schema **不**导出 `exportConfig`（仅本地草稿层；服务端不消费导出配置）

### 3.4 兼容承诺

- v1 / v2 / v3 / v4 旧草稿 100% 加载，`exportConfig == nil` 时按当前 canvas 派生默认导出
- `VideoExporter.export(timeline:)` 公共 API 签名不变（对 ExportResultView / ClipEditorView 等调用方零修改）
- `CompositionBuilder.build` 旧调用点零修改（新参数默认 nil，行为不变）
- v4 已锁的固定交互约束全部沿用（详见第七节）

---

## 四、里程碑排期

| 里程碑 | 工作内容 | 关键交付 |
|---|---|---|
| **M1（P0）渲染同源化与全屏预览** | [fullscreen-preview-spec.md](fullscreen-preview-spec.md) + [render-pipeline-unification-spec.md](render-pipeline-unification-spec.md) §3 | `FullScreenPreviewController` + `FullScreenPreviewView`；`EditorControlBar` 入口；5 类样式对照矩阵全绿；可独立上线 |
| **M2（P1-A）数据模型 + UI 面板** | [export-config-panel-spec.md](export-config-panel-spec.md) §2-§4 | `ExportConfig.swift`；`ExportConfigSheet.swift`；规格按钮接线；`EditorStore.mutateExportConfig`；持久化打通；**尚未对接编码**（仍用旧 ExportSession） |
| **M3（P1-B SDR 全档位）** | [render-pipeline-unification-spec.md](render-pipeline-unification-spec.md) §4-§6 + [export-config-panel-spec.md](export-config-panel-spec.md) §5 | `VideoExporter.exportToFile` 重写为 AVAssetWriter；`CompositionBuilder.build` 加 renderSize/fps override；5 档分辨率 / 6 档帧率 / 3 档码率端到端生效（H.264 SDR）；ffprobe 校验通过；HDR Toggle 暂禁用显示"即将上线" |
| **M4（P1-C HDR 增量）** | [render-pipeline-unification-spec.md](render-pipeline-unification-spec.md) §7 | HDR Toggle 解禁；HEVC Main 10 + BT.2020 PQ 编码；不支持设备静默降级 SDR；色彩空间 ffprobe 校验通过 |
| **M5 联调 + 真机验收** | 跨特性回归 + v1-v4 旧草稿 100% 加载 + 真机大文件验收 | V5 验收清单全绿；真机 4K + 120fps + HDR 重负载导出不崩 |

排期严格按用户给出的「先 P0 同源预览 → 再 P1 导出参数」推进。

- **M1 独立可上线**（无需等待 M2/M3，全屏预览即时缓解"预览 ≠ 成片"痛点）
- **M2 与 M3 可并行**（数据模型/UI vs 渲染管线，无文件交集）
- **M4 在 M3 完成后做**（HDR 需要 HEVC10 编码路径先稳定）

---

## 五、风险与依赖

### 5.1 技术风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| 同源全屏预览采用烘焙路径，字幕在全屏内不可点选 | 用户期望"全屏内还能编辑" | 全屏即沉浸式只读上下文（剪映 / CapCut / FCP / LumaFusion 均如此）；编辑画布的 SwiftUI 叠加层与交互完全不动，保持现状 |
| 全屏预览首帧延迟 300-500ms（compoition 重建 + 编码） | 体验下降 | [fullscreen-preview-spec.md](fullscreen-preview-spec.md) §6 设置首帧 ≤ 500ms 预算；进入时显示首帧 loading；后续 frame 由 AVPlayer buffer 保证流畅 |
| AVAssetWriter 改造涉及 video+audio 双 writer，比 AVAssetExportSession 复杂 | M3 单期工期失控 | 参考既有先例 [StaticImageRenderer.swift:107-116](../../Sources/TimelineKit/Rendering/StaticImageRenderer.swift) 已用 AVAssetWriter 手写编码；M3 仅做 H.264 SDR 全档位覆盖；HDR 推到 M4 增量 |
| HDR（HEVC Main 10 + BT.2020 PQ）在 iOS 17 以下系统能力不全 | 老设备导出失败 | `AVAssetWriter.canApply(outputSettings:forMediaType:)` 在写入器创建前 dry-run；不支持 → 静默降级为 H.264 SDR + Rec.709；UI Toggle 禁用并提示"当前设备不支持" |
| 4K + 120fps + HDR 重负载组合内存与耗时压力 | 真机 OOM / 卡顿 | 档位表文档警告"重负载组合"；不做硬性限制；M5 真机记录耗时/内存峰值入 KPI 附录 |
| 规格按钮与 toolbar 现有 exportButton / title / dismiss 三按钮空间冲突 | iPhone 窄屏 toolbar 挤压 | 规格按钮文案仅 2-3 字符（"480P" / "1080P" / "4K"）；topBarLeading 已是 dismiss、title 已是 productName、topBarTrailing 加规格 + 导出共两个按钮 → 空间足够 |
| 非标准 canvas 尺寸的派生匹配 | canvas 短边/帧率非标准（如 540×960、canvas.fps=27）| `Resolution.matching` / `FrameRate.matching` 按"距离最近优先 + 平局取更高"规则；540 → 480P、600 → 720P（平局取高）、27 fps → 25fps（距离 25 更近） |
| 已持久化 exportConfig 后用户改 canvas | 导出分辨率与画布不一致 | 设计预期：尊重用户已选；用户可点"恢复默认"清回 nil 让其重新跟随 canvas |

### 5.2 外部依赖

- **v2/export-pipeline-spec.md**：在原文末尾追加附录 A，作为 v5 的"档位与编码格式"权威来源
- **草稿 schema 加法**：`ExportConfig` 仅本端使用，不与服务端协议交换；服务端 TimelineExporter 不导出该字段
- **iOS 平台 API**：
  - `AVAssetWriter`（iOS 4+，全代支持）
  - `HEVC Main 10 + BT.2020 PQ` 编码：iOS 14+ 支持；iOS 17+ 支持 Dolby Vision 8.4（v5 暂不做 DoVi）
  - `AVPlayerItemVideoOutput` 取首帧：iOS 9+ 全代支持

---

## 六、验收 KPI

### 6.1 功能闭环

| KPI | 标准 |
|---|---|
| 全屏预览入口可见可点 | 底部 Controls 栏右侧新增图标，单击即进入全屏 |
| 全屏预览与导出像素一致（5 类样式） | 描边 / 阴影 / 背景+padding / 层级 / 字幕基础 5 类对照截图像素 diff ≤ 2% |
| 全屏预览支持播放 / 暂停 / 拖拽进度 / 退出 | 5 项操作全部可用；退出后编辑画布播放头连续 |
| 规格按钮常态显示当前分辨率 | "480P" / "720P" / "1080P" / "2K" / "4K" 5 种文案，跟随 `timeline.effectiveExportConfig.resolution`（新工程跟随画布派生）|
| 导出参数配置面板 4 项可调 | 分辨率 5 档 / 帧率 6 档 / 码率 3 档 / HDR 开关全部交互可用 |
| 配置持久化 | 工程关闭再打开后，规格按钮显示与最后一次配置一致 |
| 旧草稿（v1/v2/v3/v4）打开 | `exportConfig == nil` → 按 canvas 派生导出（短边 720 → 720P；canvas.fps → 匹配最接近档位；码率推荐；HDR 开）|
| 导出文件参数真实生效（M3 验收，12 组代表组合） | ffprobe 校验 width/height/r_frame_rate 100% 匹配；bit_rate ±15% 内 |
| HDR 导出（M4 验收）| ffprobe `color_space=bt2020nc`、`color_transfer=smpte2084` |
| HDR 设备不支持 | UI Toggle 禁用 + 提示；导出降级 H.264 SDR + Rec.709，不崩 |

### 6.2 性能

| 操作 | 标准 |
|---|---|
| 全屏预览入口点击 → 首帧可见 | ≤ 500ms |
| 全屏预览拖拽进度 → 新位置首帧 | ≤ 200ms（与编辑预览 seek 等价） |
| 规格按钮点击 → Sheet 弹出 | ≤ 100ms |
| ExportConfig mutate → 规格按钮文案刷新 | ≤ 1 frame（同步） |
| 1080P / 30fps / 推荐 / SDR 60s 时长导出 | 与 v4 现状（AVAssetExportPreset1920x1080）耗时 ±10% 内 |

### 6.3 稳定性 & 兼容

| KPI | 标准 |
|---|---|
| 加载 v1 / v2 / v3 / v4 旧草稿 | 100% 兼容；`exportConfig` 反序列化为 `nil`，导出时按当前 canvas 派生默认 |
| 全屏预览过程中切换工程 | 全屏自动退出；不残留 AVPlayer 实例 |
| 编辑过程中修改样式 → 进入全屏 → 退出 → 再次进入全屏 | 第二次进入显示最新样式（CompositionResult 重建） |
| 12 组代表组合连续导出 | 0 崩溃；中间任一组失败不影响后续 |
| 4K + 120fps + HDR 重负载 60s 导出 | 真机不崩；内存峰值记录入 KPI 附录（不限硬指标） |

---

## 七、固定交互约束（V3 已锁 + V4 沿用，V5 全程沿用，禁止改动）

| 约束 | 来源 |
|---|---|
| 轨道点击仅选中唤起快捷操作栏，**不遮挡轨道编辑区**；预览画布点击直接唤起完整编辑面板 | V3 已定稿 |
| 文本、字幕统一共用 `TextEditPanel` 唯一编辑面板，仅区分是否展示朗读功能、位置调节 Tab | V3 [text-entry-spec.md](../v3/text-entry-spec.md) |
| 底部工具栏严格区分两种场景：无选中片段仅展示新建入口，选中片段仅展示编辑快捷操作 | V3 已定稿 |
| 所有新增功能必须适配旧版草稿，做到向下完全兼容 | V3 [V3-initiation.md](../v3/V3-initiation.md) §3.1 |
| 安卓 / iOS 双端交互逻辑保持统一 | V3 已定稿 |
| `mutateSubtitle` 不重建 compositionVersion（S-04） | V1 已锁，V4 沿用 |
| `isMainTrack` 唯一性 | V1 已锁，V3/V4 沿用 |

每份 v5 spec 末尾必须重申一遍以上七条约束，确保实现时不漂移。

V5 自身新增的隐性约束（写入各 spec）：

- **全屏预览即沉浸式只读**：全屏内不允许编辑（拖拽 / 点选字幕 / 二次调样式），与剪映 / CapCut / FCP / LumaFusion 行为一致
- **导出公共 API 签名锁定**：`VideoExporter.export(timeline:)` 对外签名不变，任何渲染层改造都不破坏这一契约
- **`CompositionBuilder.build` 向后兼容**：新增 renderSize / fps 参数必须为可选，nil 时行为与 V4 完全一致

---

## 八、不在本立项范围

- 任何代码改动：留待 3 份 spec 各自的实现 PR（按 M1 → M5 排期推进）
- v1 / v2 / v3 / v4 已有文档的修订（v5 是补齐与加法；v2 仅在原文追加附录 A 不改主体）
- 空白工程 / 草稿体系扩展 / 草稿模板 / 后台导出 / ProRes / 关键帧 / 多端协作（详见 §2.3 / §2.4）
- 编辑画布常态预览的同源化（SwiftUI 叠加层升级为 CIImage 出帧）—— 留作 V6/V7 议题
- 服务端 TimelineExporter schema 谈判（`exportConfig` 仅本地草稿层）

---

## 九、文档间引用图

```
README.md
   ├── V5-initiation.md  (本文档)
   ├── competitive-benchmarks-v5.md
   │      ↳ 被 3 份 spec 引用：竞品基线（导出档位 + 全屏预览能力）与定档依据集中维护
   ├── fullscreen-preview-spec.md (P0)
   │      ↳ 依赖 CompositionBuilder.build(renderSubtitles: true) 同源出帧路径
   │      ↳ 被 render-pipeline-unification-spec 引用：M1 已建立的 FullScreenPreviewController 在 M3 复用编码路径
   ├── export-config-panel-spec.md (P1)
   │      ↳ 依赖 render-pipeline-unification-spec：UI 配置的最终生效靠 AVAssetWriter 改造打通
   │      ↳ 反向引用 docs/v2/export-pipeline-spec.md 附录 A：档位与编码格式权威表
   └── render-pipeline-unification-spec.md (P1)
          ↳ 依赖 fullscreen-preview-spec：M1 同源调用链复用
          ↳ 反向引用 docs/v2/export-pipeline-spec.md 附录 A：档位映射表
```

具体引用语义见各 spec「依赖」字段。
