# V5 竞品对标总报告

> 版本：v5.0
> 状态：规范定稿
> 对标产品：剪映 iOS 13.0+（移动端主对标） + CapCut Desktop 3.0+ + Final Cut Pro 11 / FCP for iPad 2.x + LumaFusion 4.x
> 服务对象：V5 P0/P1 全部 3 份 spec 的规则定档依据

本报告把 V5 P0/P1 涉及的两大能力族（**导出参数面板** + **全屏同源预览**）按能力点拉到一起对标。规则定档集中在本文档维护，避免在 3 份 spec 之间重复抄写；各 spec 的「规则段」直接引用本文档对应章节。

---

## 一、导出参数面板

### 1.1 入口位置

| 产品 | 入口 | 触发方式 |
|---|---|---|
| **剪映 iOS** | 顶部导航栏导出按钮**左侧**「规格」按钮，常态显示当前分辨率（如"1080P"） | 单击弹出半屏 sheet |
| **CapCut Desktop** | 顶部导出按钮 → 一级弹窗内嵌全部导出参数（分辨率 / 帧率 / 码率 / 格式） | 导出按钮内联 |
| **FCP（macOS）** | File → Share → Master File... → Settings 标签页 | 多级菜单 |
| **FCP for iPad** | 共享面板 → Apple Devices 1080p / Custom | 半屏 sheet |
| **LumaFusion** | 顶部 Share → Movie → Settings 标签页 | 半屏 sheet |

**V5 定档**：**取剪映模型**——顶部 toolbar 导出按钮**左侧**新增规格按钮，常态仅显示当前分辨率（2-3 字符短文案），单击弹出半屏 Sheet。详见 [export-config-panel-spec.md](export-config-panel-spec.md) §4。

理由：剪映模型是移动端用户最熟悉的肌肉记忆；顶部位置常显当前规格，单击触达，无需多级菜单。

### 1.2 分辨率档位

| 产品 | 档位 | 默认 |
|---|---|---|
| **剪映 iOS** | 480P / 720P / 1080P / 2K / 4K | 1080P |
| **CapCut Desktop** | 480P / 720P / 1080P / 2K / 4K | 1080P |
| **FCP（macOS）** | 720p / 1080p / 2K / 4K / 5K / 8K（取决于源素材） | 1080p |
| **FCP for iPad** | 720p / 1080p / 4K | 1080p |
| **LumaFusion** | 360 / 540 / 720 / 1080 / 2K / 4K | 1080p |

**V5 定档**：**480P / 720P / 1080P / 2K / 4K 共 5 档**（对齐剪映/CapCut）。省略 5K/8K（iOS 设备稀有，移动端无消费场景）。

**默认跟随画布**（区别于剪映/CapCut 固定默认 1080P）：按 `EditorTimeline.canvas` 短边匹配最接近档位（候选 [480, 720, 1080, 1440, 2160]，距离最近优先，平局取更高保画质）。当前 [EditorCanvas.Preset](../../Sources/TimelineKit/Models/EditorCanvas.swift) 4 种默认预设（9:16 / 16:9 / 1:1 / 3:4）短边均为 720 → 新工程默认导出 720P；导入 1080P 素材的工程默认导出 1080P，避免"720P 工程默认 480P 导出"的反直觉。用户可在 Sheet 中手动改到任意档位，改后持久化。

### 1.3 帧率档位

| 产品 | 档位 | 默认 |
|---|---|---|
| **剪映 iOS** | 24 / 25 / 30 / 50 / 60 | 30 |
| **CapCut Desktop** | 24 / 25 / 30 / 50 / 60 / 120 | 30 |
| **FCP（macOS）** | 23.98 / 24 / 25 / 29.97 / 30 / 50 / 59.94 / 60 | 跟随源素材 |
| **FCP for iPad** | 23.98 / 25 / 29.97 / 30 | 跟随源素材 |
| **LumaFusion** | 18-240 连续可选 | 30 |

**V5 定档**：**24 / 25 / 30 / 50 / 60 / 120 共 6 档**（对齐 CapCut，纳入 120fps 兼容慢动作素材输出；保留 25/50 PAL 档位兼容欧洲素材）。省略电视广播帧率（23.98 / 29.97 / 59.94，移动端无消费场景）。

**默认跟随画布**：按 `canvas.fps` 匹配最接近档位（候选 [24, 25, 30, 50, 60, 120]，距离最近优先，平局取更高）。当前默认 canvas.fps=30 → 默认导出 30fps；若工程改为 60fps → 默认 60fps；非标准 fps（如 27 → 25，100 → 120）按距离最近规则匹配。用户可手动改到任意档位。

### 1.4 码率档位

| 产品 | 档位 | 默认 |
|---|---|---|
| **剪映 iOS** | 较低 / 推荐 / 较高 | 推荐 |
| **CapCut Desktop** | 推荐 / 高 / 自定义（Mbps 滑杆） | 推荐 |
| **FCP（macOS）** | 自定义 Mbps + Multi-pass / Single-pass 选择 | 跟随预设 |
| **FCP for iPad** | 跟随分辨率预设，不可调 | — |
| **LumaFusion** | 自定义 Mbps 滑杆 | 跟随分辨率 |

**V5 定档**：**较低 / 推荐 / 较高 共 3 档**（对齐剪映命名，用户心智成本最低）。不做"自定义 Mbps"档（移动端用户不会输 Mbps 数字；推荐档对齐 YouTube 1080P30 ≈ 8 Mbps）。

**默认推荐**（用户立项明确指定）。

每个分辨率档下的具体 Mbps 数值见 [render-pipeline-unification-spec.md](render-pipeline-unification-spec.md) §6 档位映射表。

### 1.5 HDR 开关

| 产品 | 形态 | 默认 |
|---|---|---|
| **剪映 iOS** | "智能 HDR" Toggle（需设备支持） | 关 |
| **CapCut Desktop** | "HDR" Toggle | 关 |
| **FCP（macOS）** | Color Space 下拉：Rec. 709 / Rec. 2020 PQ / Rec. 2020 HLG | Rec. 709 |
| **FCP for iPad** | "HDR" Toggle（HLG） | 关 |
| **LumaFusion** | "HDR" Toggle（HLG） | 关 |

**V5 定档**：**"智能 HDR" Toggle 单档开关**（取剪映命名 + 取 PQ 编码）。开启后自动以 HEVC Main 10 + BT.2020 PQ 输出；设备/系统不支持时静默降级 H.264 SDR + Rec.709，UI Toggle 禁用并提示"当前设备不支持"。

**默认 HDR 开**（用户立项明确指定，区别于剪映/CapCut 行业惯例的"默认 HDR 关"）。差异化决策：HDR 在新设备上输出表现明显优于 SDR；老设备会自动降级，对用户无副作用，因此默认开启即可让多数用户受益。

不做 PQ / HLG 双选（FCP 才需要的专业能力，移动端无消费场景）。不做 Dolby Vision（iOS 17+ 才支持 DoVi 8.4，V5 不上 DoVi，留作 V6/V7 议题）。

### 1.6 综合对照表

| 项 | 剪映 iOS | CapCut | FCP iPad | LumaFusion | **V5 选档** |
|---|---|---|---|---|---|
| 分辨率 | 480/720/1080/2K/4K | 480/720/1080/2K/4K | 720/1080/4K | 360/540/720/1080/2K/4K | **480/720/1080/2K/4K** |
| 帧率 | 24/25/30/50/60 | 24/25/30/50/60/120 | 23.98/25/29.97/30 | 18-240 连续 | **24/25/30/50/60/120** |
| 码率 | 低/推荐/高 | 推荐/高/自定义 | 跟随预设 | 自定义 Mbps | **较低/推荐/较高**（对齐剪映） |
| HDR | 智能 HDR Toggle | HDR Toggle | HDR Toggle (HLG) | HDR Toggle (HLG) | **智能 HDR Toggle**（HEVC10 + BT.2020 PQ） |
| 默认分辨率 | 1080P 固定 | 1080P 固定 | 跟源 | 1080P 固定 | **跟随画布**（按 canvas 短边派生，当前默认预设 → 720P）|
| 默认帧率 | 30 固定 | 30 固定 | 跟源 | 30 固定 | **跟随画布**（按 canvas.fps 派生）|
| 默认码率 | 推荐 | 推荐 | 跟预设 | 跟分辨率 | **推荐** |
| 默认 HDR | 关 | 关 | 关 | 关 | **开**（用户指定） |
| 持久化（同工程沿用） | ✅ | ✅ | ✅ | ✅ | **✅ 持久化到 `EditorMetadata.exportConfig`** |

---

## 二、全屏同源真实预览

### 2.1 入口位置

| 产品 | 入口 | 备注 |
|---|---|---|
| **剪映 iOS** | 预览区右上角"扩展全屏"图标 | 单击进入 |
| **CapCut Desktop** | 预览区右下角全屏图标 + 快捷键 Cmd+8 | — |
| **FCP（macOS）** | View → Playback → Play Full Screen + 快捷键 Shift+Cmd+F | 菜单 + 快捷键 |
| **FCP for iPad** | 预览面板右上角全屏按钮 | 单击 |
| **LumaFusion** | 双指外扩或预览区右上全屏按钮 | 两种入口 |
| **TimelineKit V4** | **❌ 无**——只有导出后的 [ExportResultView:72 FullScreenVideoPlayer](../../Sources/TimelineKit/Views/ExportResultView.swift) 是后置浏览，不是编辑中入口 | — |

**V5 定档**：**底部 Controls 栏（[EditorControlBar.swift:8-34](../../Sources/TimelineKit/Views/EditorControlBar.swift)）右侧追加全屏图标按钮**，与 backward / play / forward 并排。

理由：[EditorPreviewView](../../Sources/TimelineKit/Views/EditorPreviewView.swift) 自身布局已挤满，右上角浮动按钮会与字幕叠加层冲突；放在播放控制栏与"播放/暂停/前后帧"形成统一的播放能力族，符合用户预期。

### 2.2 同源能力（核心差异化点）

| 产品 | 全屏预览渲染路径 | 是否与导出同源 |
|---|---|---|
| **剪映 iOS** | 同一套烘焙输出帧 → AVPlayer 播放 | ✅ |
| **CapCut Desktop** | 同一套渲染管线 → 全屏播放 | ✅ |
| **FCP（macOS）** | Viewer 始终走完整渲染管线（不存在预览/导出分裂） | ✅ |
| **FCP for iPad** | 同 macOS | ✅ |
| **LumaFusion** | Preview Engine 与 Export Engine 共享底层渲染节点 | ✅ |
| **TimelineKit V4** | **❌ 不存在全屏预览**；编辑画布走 SwiftUI 叠加层，与导出 CIImage 烘焙是两套绘制逻辑 | ❌ |

**V5 定档**：**全屏预览触发 `CompositionBuilder.build(renderSubtitles: true)`，独立 AVPlayer 播放该 composition**——与 `VideoExporter.exportToFile` 走同一函数同一参数。详见 [fullscreen-preview-spec.md](fullscreen-preview-spec.md) §2 + §3。

理由：与导出**绝对**同源（同函数同参数）；改动局限于新增视图与 controller；不破坏编辑画布的 SwiftUI 叠加层与交互。

### 2.3 全屏内的交互能力

| 产品 | 全屏内可做什么 | 不可做什么 |
|---|---|---|
| **剪映 iOS** | 播放 / 暂停 / 拖拽进度 / 退出 | 不可编辑（不可拖字幕、不可调样式） |
| **CapCut Desktop** | 同剪映 | 同剪映（鼠标移动调出控件，编辑能力关闭）|
| **FCP** | 同上 | 同上 |
| **LumaFusion** | 同上 | 同上 |

**V5 定档**：**全屏即沉浸式只读上下文**——播放 / 暂停 / 拖拽进度 / 退出 4 项操作可用；不可编辑、不可点选字幕、不可调样式。与剪映 / CapCut / FCP / LumaFusion 完全一致。

理由：全屏预览的目的是"校验最终成片效果"，不是"在更大画面里继续编辑"；后者需求由编辑画布自身满足。

### 2.4 进度拖拽精度

| 产品 | 拖拽精度 | 备注 |
|---|---|---|
| **剪映 iOS** | 帧级 seek（toleranceBefore/After: .zero）| 拖到任意帧立即定格 |
| **CapCut** | 同剪映 | — |
| **FCP** | 帧级 + 关键帧吸附 | 专业场景 |
| **LumaFusion** | 帧级 | — |

**V5 定档**：**帧级 seek（toleranceBefore/After: .zero）**——拖动进度条时调 `player.seek(to:toleranceBefore:.zero, toleranceAfter:.zero)`。详见 [fullscreen-preview-spec.md](fullscreen-preview-spec.md) §3.3。

### 2.5 退出后状态保持

| 产品 | 退出全屏后 | 备注 |
|---|---|---|
| **剪映 iOS** | 编辑画布播放头跳到全屏最后停留位置 | 上下文连续 |
| **CapCut** | 同剪映 | — |
| **FCP** | 同剪映 | — |
| **LumaFusion** | 同剪映 | — |

**V5 定档**：**退出全屏时将 player 最后位置回写 `EditorStore.selection.playheadTime`**，编辑画布播放头跳到该时刻。详见 [fullscreen-preview-spec.md](fullscreen-preview-spec.md) §3.5。

---

## 三、AVAssetWriter 改造决策依据

### 3.1 各家编码栈

| 产品 | 编码栈 | 码率/HDR 可控 |
|---|---|---|
| **剪映 iOS** | `AVAssetWriter` + 自配 H.264 / HEVC | ✅ 全可控 |
| **CapCut** | 自研编码引擎 + 系统硬编码 | ✅ |
| **FCP** | 自研 / VideoToolbox | ✅ |
| **LumaFusion** | `AVAssetWriter` + VideoToolbox | ✅ |
| **TimelineKit V4** | `AVAssetExportSession` 三选一预设 | ❌ 架构无法控制码率与色彩空间 |

### 3.2 V5 必须改造为 AVAssetWriter

`AVAssetExportSession` 的预设绑定分辨率+质量，**架构上**无法独立控制码率与色彩空间。要实现 V5 §1.4 三档码率 + §1.5 HDR 开关，**没有第二条路**，必须改造为 `AVAssetWriter`。

参考既有先例 [StaticImageRenderer.swift:107-116](../../Sources/TimelineKit/Rendering/StaticImageRenderer.swift) 已用 `AVAssetWriter` 手写编码（作为静帧渲染路径）；V5 在 [VideoExporter.swift:74-120](../../Sources/TimelineKit/Export/VideoExporter.swift) 复用同一模式扩展到视频导出主路径。

详见 [render-pipeline-unification-spec.md](render-pipeline-unification-spec.md) §4。

### 3.3 分阶段降低风险

| 阶段 | 范围 | 编码 |
|---|---|---|
| **M3（SDR 全档位）** | 5 档分辨率 × 6 档帧率 × 3 档码率 端到端打通 | H.264（≤1080P）+ HEVC（≥2K）+ Rec.709 |
| **M4（HDR 增量）** | HDR 开关解禁 | HEVC Main 10 + BT.2020 PQ |

M3 不上 HDR 的理由：HEVC Main 10 编码涉及 10-bit pixel format、`kCVImageBufferTransferFunction_ITU_R_2100_PQ` 配置、设备能力检测、降级路径，工程量翻倍。先把 SDR 全档位打通让导出参数面板上线可用，HDR 留作 M4 增量。

UI 层面：M3 阶段 HDR Toggle 暂时禁用并显示"即将上线"小字；M4 解禁。

---

## 四、规则定档汇总（供 3 份 spec 引用）

| 决策点 | 选择 | 来源 |
|---|---|---|
| 规格按钮位置 | 顶部 toolbar 导出按钮左侧 | §1.1（剪映模型）|
| 规格按钮文案 | 仅当前分辨率（"480P" / "720P" / "1080P" / "2K" / "4K"）| §1.2 |
| 分辨率档位 | 480P / 720P / 1080P / 2K / 4K | §1.2 |
| 帧率档位 | 24 / 25 / 30 / 50 / 60 / 120 | §1.3 |
| 码率档位 | 较低 / 推荐 / 较高 | §1.4 |
| HDR 形态 | 智能 HDR 单档 Toggle（HEVC10 + BT.2020 PQ）| §1.5 |
| 出厂默认（分辨率/帧率）| 跟随画布派生（`canvas` 短边匹配最接近档位；`canvas.fps` 匹配最接近档位）| §1.2/§1.3 |
| 出厂默认（码率/HDR）| 推荐 / HDR 开 | §1.4/§1.5（用户立项指定）|
| 持久化 | 写入 `EditorMetadata.exportConfig`；读取走 `EditorTimeline.effectiveExportConfig` | §1.6 |
| 全屏预览入口 | 底部 Controls 栏右侧 | §2.1 |
| 全屏预览渲染路径 | `CompositionBuilder.build(renderSubtitles: true)` + 独立 AVPlayer | §2.2 |
| 全屏交互 | 沉浸式只读：播放 / 暂停 / 拖拽 / 退出 | §2.3 |
| 拖拽精度 | 帧级 seek（toleranceBefore/After: .zero）| §2.4 |
| 退出后状态 | 编辑画布播放头跳到全屏最后位置 | §2.5 |
| 编码栈 | `AVAssetWriter`（替换 AVAssetExportSession）| §3.2 |
| 分阶段 | M3 SDR 全档位 → M4 HDR 增量 | §3.3 |

---

## 五、未对齐项（V5 主动放弃的能力）

以下能力主流剪辑器有，V5 主动放弃：

| 能力 | 放弃理由 |
|---|---|
| 自定义码率 Mbps 滑杆 | 移动端用户不会输 Mbps 数字；三档预设覆盖 95% 场景 |
| Dolby Vision / HDR10+ | iOS 17+ 才支持 DoVi 8.4；V5 不上 DoVi，留作 V6/V7 |
| PQ / HLG 双选 | FCP 才需要的专业能力，移动端无消费场景 |
| 5K / 8K 分辨率 | iOS 设备稀有，移动端无消费场景 |
| 23.98 / 29.97 / 59.94 电视广播帧率 | 移动端无消费场景 |
| ProRes / DNxHD | 移动端无消费场景；编码器集成成本高 |
| 后台静默导出（应用退后台继续）| 涉及 BackgroundTask 权限，V5 留 roadmap |
| 全屏预览内继续编辑 | 与剪映 / CapCut / FCP / LumaFusion 行为一致，全屏即只读 |

放弃决策由 [V5-initiation.md](V5-initiation.md) §2.3 / §2.4 留 roadmap 占位；P0/P1 上线后再评估是否单独立项。
