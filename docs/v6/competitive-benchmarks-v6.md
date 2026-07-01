# V6 竞品对标总报告

> 版本：v6.0
> 状态：规范定稿
> 对标产品：剪映 iOS 13.0+（移动端主对标）+ CapCut Desktop 3.0+ / CapCut Web + Final Cut Pro 11 / FCP for iPad 2.x + LumaFusion 5.x
> 服务对象：V6 P0/P1 全部 5 份 spec 的规则定档依据

本报告把 V6 涉及的三大能力族（**图片原生图层渲染** + **关键帧动画系统** + **2.5D parallax 景深效果**）按能力点拉到一起对标。规则定档集中在本文档维护，避免在 5 份 spec 之间重复抄写；各 spec 的「规则段」直接引用本文档对应章节。

---

## 一、图片原生图层渲染（对标对象：废除 prebake MP4）

### 1.1 渲染架构

| 产品 | 图片渲染方式 | 是否预合成视频 |
|---|---|---|
| **剪映 iOS** | 图片作为一等 clip 分段，直接进入 GPU compositor；`draft_content.json` 中图片节点与视频节点共享 `transform` + `keyframes` 数据结构 | ❌ 不预合成 |
| **CapCut Desktop / Web** | 同剪映；草稿工程与移动端互通；"预渲染"按钮是可选预览缓存，图片 clip 仍是可编辑的原生图片 | ❌ 不预合成（可选缓存仅提速） |
| **FCP（macOS）** | Still image = clip type，默认 4s duration；Generator 发射帧；两者在 Metal compositor 中与视频 node 平等，共享包覆 z-stack | ❌ 不预合成 |
| **LumaFusion** | 图片 clip 与视频 clip 共用同一 transform stack（size / position / rotation / anchor / opacity / crop），Metal 渲染 | ❌ 不预合成 |
| **TimelineKit V5** | 所有图片 (`image / image_motion / image_3d`) 经过 [StaticImageRenderer](../../Sources/TimelineKit/Rendering/StaticImageRenderer.swift) 预渲染为 MP4，再以 AVURLAsset → AVAssetTrack → insertTimeRange 挂到 AVMutableComposition | ✅ **独此一家预合成** |

**V6 定档**：**废除 MP4 预合成，图片以 CIImage 原生图层挂载时间轴**，走 UnifiedCompositor 实时渲染。详见 [image-layer-rendering-spec.md](image-layer-rendering-spec.md) §2。

理由：全部主流剪辑器（剪映 / CapCut / FCP / LumaFusion）均不预合成图片；TimelineKit 的 prebake 路径是整个渲染管线的架构债根源——差异化 fps、sentinel 帧兜底、转场尾帧冻结、临时文件 IO、帧率不一致 全部从它派生。改掉它是一劳永逸。

### 1.2 自定义 Compositor 的扩展点

| 产品 | Compositor 实现方式 |
|---|---|
| **剪映 / CapCut** | 自研 GPU compositor（大概率 Metal），不依赖 AVFoundation stock compositor |
| **FCP** | 自研 Metal compositor；CIImage 桥接用于滤镜链 |
| **LumaFusion** | `AVVideoCompositing` 协议的自定义 compositor + Metal + `CVPixelBufferPool` |
| **TimelineKit V5** | 已有自定义 [UnifiedCompositor](../../Sources/TimelineKit/Rendering/UnifiedCompositor.swift) 实现 `AVVideoCompositing`，但重度依赖 `request.sourceFrame(byTrackID:)` ——**每个指令必须有 AVAssetTrack 源**，无源时 `finish(with: missingFrame)` |

**V6 定档**：**扩展 UnifiedCompositor 的 `UnifiedCompositorInstruction`**，新增 `imageLayers: [ImageLayerSpec]` 字段。compositor 在 `startRequest` 中检测到 imageLayers 时走「CIImage 加载 + 关键帧变换 + 合成」分支，不走 sourceFrame。详见 [image-layer-rendering-spec.md](image-layer-rendering-spec.md) §4。

### 1.3 图片图层与视频图层的统一能力

| 能力 | 剪映 | CapCut | FCP | LumaFusion | TimelineKit V5 | **V6 定档** |
|---|---|---|---|---|---|---|
| 拖拽切分 | ✅ | ✅ | ✅ | ✅ | ✅ (视频 + AI MP4) / ⚠️ 图片 MP4 时长受限 | ✅ (所有图层等权) |
| 时长伸缩 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 转场 | ✅ | ✅ | ✅ | ✅ | ⚠️ unified + overlay 不可见 | ✅ (转场作用于图层交界) |
| 调色 / LUT | ✅ | ✅ | ✅ | ✅ | ✅ (ColorAdjustmentCompositor) | ✅ (沿用) |
| 轨道叠加 (overlay) | ✅ | ✅ | ✅ | ✅ | ⚠️ V5.1 单 pass 已修 / unified 存留 | ✅ (P0-C layer-rendering-rules) |
| 多图层 z-order | ✅ | ✅ | ✅ | ✅ | ✅ (track zPosition) | ✅ |
| 蒙版 | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ (V6.1+) |
| 动画 (keyframe) | ✅ 全维 | ✅ 全维 | ✅ 全维 | ✅ v5.0 新增 Bezier | ⚠️ 仅 motionPreset 预设 | ✅ 5 维 MVP (见 §2) |

**结论**：TimelineKit V5 是唯一把图片降级为 MP4 的产品——不是因为技术限制（UnifiedCompositor 存在、字幕烘焙已证明 CIImage→CIImage 合成可行），而是因为路线选择。V6 的决定是把路线纠正到全行业一致的做法。

---

## 二、关键帧动画系统

### 2.1 关键帧维度覆盖

| 维度 | 剪映 | CapCut | FCP | LumaFusion | **V6 定档** |
|---|---|---|---|---|---|
| 位置 (x, y) | ✅ | ✅ | ✅ (per-axis curves) | ✅ (separable X/Y) | ✅ |
| 缩放 (x, y) | ✅ | ✅ | ✅ | ✅ (separable X/Y) | ✅ |
| 旋转 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 锚点 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 不透明度 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 倾斜 / skew | ✅ | ✅ | ❌ | ❌ | ❌ (V6.1+) |
| 3D 旋转 (X/Y/Z) | ⚠️ (3D 照片用分层) | ⚠️ (同剪映) | ✅ (CATransform3D) | ❌ | ❌ (V6.1+) |

**V6 定档**：**5 维 MVP（position / scale / rotation / anchor / opacity）**。对齐剪映 + LumaFusion 底线集；skew / 3D 推到 V6.1+。

理由：AI Timeline 已下发的全部动画参数（缩放推进/拉远、平移、景深位移）均可用这 5 维覆盖。超出部分（自定义贝塞尔路径、三维旋转、扭曲）在 server 端无对应参数，做了也用不上——遵循「够用优先，循序渐进」原则。

### 2.2 缓动曲线（easing）

| 曲线 | 剪映 | CapCut | FCP | LumaFusion | **V6 定档** |
|---|---|---|---|---|---|
| Linear | ✅ | ✅ | ✅ | ✅ | ✅ |
| Ease (缓入缓出) | ✅ | ✅ | ✅ (Smooth) | ✅ | ✅ |
| Ease In | ✅ | ✅ | ✅ | ✅ | ✅ |
| Ease Out | ✅ | ✅ | ✅ | ✅ | ✅ |
| Cubic Bezier (自定义) | ❌ (仅预设) | ❌ (Desktop 同) | ✅ (1D Bezier) | ✅ (v5.0 Bezier handle) | ✅ (预采样 40 段 LUT，参数化但无 UI) |
| Hold (阶跃) | ❌ | ❌ | ✅ | ✅ (v5.0) | ❌ (V6.1+) |
| Catmull-Rom (平滑自动切线) | ❌ | ❌ | ❌ | ❌ | ❌ (V6.1+) |

**V6 定档**：**linear / ease / easeIn / easeOut / cubicBezier(p1, p2) 共 5 种**。采用 **FCP 风格 40 段 LUT 预采样**求值器——LUT 大小固定，O(1) 查表 + 线性插值，无运行时 Bezier 迭代开销。

**与 V5 StaticImageRenderer 的兼容**：V5 动效图使用 `easeOut` 单曲线上采样（[StaticImageRenderer.swift 行 181](../../Sources/TimelineKit/Rendering/StaticImageRenderer.swift)），V6 的 `easeOut` LUT 与 V5 的 ease-out 采样在 0~1 域内重合（同属 `CAMediaTimingFunction(name: .easeOut)` 的四阶 Bézier 控制点（0,0,0.58,1.0））。详见 [keyframe-animation-spec.md](keyframe-animation-spec.md) §4。

### 2.3 曲线求值器实现对比

| 维度 | 剪映 | FCP | LumaFusion | **V6 定档** |
|---|---|---|---|---|
| 采样方式 | 每帧按预设类型直接计算 | JSON 定义控制点 + 40 段线性逼近输出到 XML | 实际曲线（visible in velocity/ease graph）| 40 段 LUT 预采样（取 FCP 模型） |
| 单帧开销 | ~4 次浮点运算（预设）| ~2 次（查表+线性插值）| 实时求值 | ~2 次（查表+线性插值） |
| 多帧一致性 | 相同预设保证 | 相同 LUT 保证 | 相同参数保证 | 相同 LUT 保证 |
| 质量 | 不可细调 | 可控制分段数 | 高精度 | 细分密度 40 段参考 FCP，对移动端足够 |

**V6 定档**：**40 段 LUT（键 = integer(progress * 40)，值 = 0~1 缓动后的 progress）**。确保 multi-pass 导出时 LUT 值位精确重复（帧一致性）。实现上直接生成为常量表数组（256 bytes），无需初始化开销。

### 2.4 关键帧数据模型

| 字段 | 剪映 draft_content.json | FCP XML | V5 KeyframeSet | **V6 KeyframeSet** |
|---|---|---|---|---|
| 时间表达 | 绝对时间 (s) | 绝对时间 (s) | `time: Double` | `timeFraction: Double` (0~1 标准化因子) |
| 值表达 | 各维分列 | 各维分列 | 各维分列 | 各维分列 |
| 缓动 | 预设名 | 控制点参数 | `easing: String` | `easing: EasingCurve` |
| 锚点 | 无（数据中未独立出现） | `offset` 属性 | ❌ | `anchor: CGPoint` |
| 维度复用 | 每个维度独立 keyframe 数组 | 同左 | 复制粘贴模式 `[KeyframePoint<T>]` | 同 V5 |

**V6 在 V5 KeyframeSet 上的变更**：

1. `time: Double`（绝对秒）→ `timeFraction: Double`（0~1）：使得用户改变 segment 时长后关键帧自动伸缩，无需重算时间点
2. `easing: String` → `easing: EasingCurve`：类型安全枚举替换魔术字符串
3. 新增 `anchor: [KeyframePoint<CGPoint>]`：缩放中心可控
4. `opacity` 保持 Double（0~1），`position` / `scale` / `rotation` 保持现有语义

---

## 三、2.5D Parallax 景深效果（Image3D 对标）

### 3.1 各家的 3D 照片实现

| 产品 | 实现方式 | 使用的数据源 |
|---|---|---|
| **剪映 3D 照片** | 单目深度估计 → 2-4 层深度切片 + 遮罩修补背景 → 每层独立图片 clip + 各自关键帧（缩放/位移/不透明度） → 在合成器里叠层。**不是**真 3D 几何变换。 | 深度图 + 原地修补 |
| **CapCut Parallax Photomotion** | 同剪映：分层 2D 图层 + differential 运动；导出为复合片段 | 同上 |
| **FCP Depth Effect** | Apple Silicon 神经引擎实时深度估计 → 焦点系统（与肖像模式共享管线）。本质仍是"焦点平面 + 景深模糊"的 2D 滤镜，非几何 3D。 | 神经深度 + 焦点参数 |
| **LumaFusion v5.0** | 无原生 3D 照片；通过关键帧手动模拟 Ken Burns + 分层截图实现 | 手工 |

**结论**：所有移动端剪辑器的 "3D 照片" 本质都是 **2D 分层图层 + differential 关键帧**，不是 CATransform3D 或真几何变换。V6 无需引入 3D 变换——2D 分层就够。

### 3.2 V6 的 2.5D Parallax 策略

| 参数 | 来源 | V6 映射 |
|---|---|---|
| 深度图 | `SDepthModel.centerX/Y` + `innerRadius/outerRadius` + `nearValue/farValue` + `falloff` | 中心焦点平面 → 前景/背景分层 → 前景 1 层 + 主层 1 层 + 背景 1 层（共 3 层），每层独立 ImageLayerSpec + 独立关键帧 |
| 景深移动 | `SCamera.move` (forward/backward/left/right/up/down) + `intensity` (0-1) + `duration` | 方向 → 各层 differential 位移量；intensity → 振幅；duration → 关键帧时间跨度 |
| 动画 | 各层关键帧（position / scale）| 前景层放大 + 同向位移 > 中景层；背景层缩小 + 反向位移；opacity 平滑过渡到主层 |

**V6 定档**：**3 层 2D 图层叠加模式**（剪映模型）。`AnimationMacro` 把 `SDepthModel` + `SCamera` 展开为一个 3 层 `[ImageLayerSpec]`，每层带独立关键帧数组。详见 [ai-timeline-mapping-spec.md](ai-timeline-mapping-spec.md) §3。

---

## 四、转场与关键帧图层共存

| 产品 | 转场期间的图层关键帧行为 |
|---|---|
| **剪映 / CapCut** | 两 clips 各自继续求值关键帧到转场结束；转场作为叠加层独立于关键帧；转场 overlap 期间两个 clip 都在输出帧 |
| **FCP** | 转场是单独的 compositor 指令节点；每个 clip 的关键帧在指令有效期内继续求值 |
| **LumaFusion** | 转场 applied as effect on clip junction；两个 clip 的关键帧不冻结 |
| **TimelineKit V5** | 转场在 unified 路径工作，但关键帧根本不存在（图片动画全部被 bake 进 MP4）——转场期间的行为由 StaticImageRenderer 的 sentinel/duration 逻辑隐身决定 |

**V6 定档**：**转场 = compositor 叠加层指令，两 clips 的关键帧继续求值到转场结束**（对齐全行业惯例）。转场指令和图层关键帧分层独立处理——转场 check transition-cover 区域，关键帧 check segment 时间区间。详见 [transition-compat-spec.md](transition-compat-spec.md) §2。

---

## 五、实时渲染性能基准

### 5.1 各家的性能策略

| 策略 | 剪映 | FCP | LumaFusion | **V6 定档** |
|---|---|---|---|---|
| GPU 加速 | ✅ Metal | ✅ Metal | ✅ Metal | ✅ `CIContext(mtlDevice:)` |
| CVPixelBuffer 池 | ✅ | ✅ | ✅ | ✅ `CVPixelBufferPool` |
| 后台渲染 | N 层并行 | 完全并行 DAG | 限制并行层数 | 共享 CIContext，按 z-order 逐层合成 |
| 降级策略 | 预览低分辨率 + 导出全分辨率 | 实时 Viewfinder 降级 | 预览自适应 | 预览 canvas 尺寸；导出 renderSize |
| 缓存 | CIImage 引用链（lazy）| 帧缓存 | 图层缓存 | CIImage lazy chain + CVPixelBuffer output pool |

**V6 最大性能节省**：去掉了 StaticImageRenderer 的编码 → 写入临时文件 → AVAssetReader 解码 → AVAssetTrack 提取像素 → AVCompositor 合成 的**双重编解码路径**。新路径：CIImage(contentsOf: URL) → transform → composited → CVPixelBuffer。预计 AI 工程导入首帧 ≤ 800ms（vs 旧路径 ≈ 2s prebake）。

### 5.2 性能 KPI 对标

| 指标 | 剪映 iOS (iPhone 13) | CapCut Desktop | **V6 目标 (iPhone 13 baseline)** |
|---|---|---|---|
| 单图片层 60fps | ✅ 稳 60fps | ✅ | ≥ 58fps |
| 3 层 image_3d 同屏 | 肉眼流畅 (约 30-40fps) | 肉眼流畅 | ≥ 30fps |
| AI 工程导入 → 首帧 | ~500ms | ~300ms | ≤ 800ms (vs V5 ~2s) |
| 编辑中缓存内存 | 约 50-80MB | 约 100-200MB | < 100MB (vs V5 300MB+ MP4) |

---

## 六、AVFoundation / Apple 平台技术路线选择

### 6.1 自定义 Compositor 的三个选项

| 选项 | 描述 | 优点 | 缺点 | V6 选择 |
|---|---|---|---|---|
| A: `AVVideoCompositionCoreAnimationTool` | 用 CALayer 做合成 | Apple 提供；链简单 | 只能用于 AVAssetExportSession；播放器不支持 | ❌ |
| B: 自定义 `AVVideoCompositing` + CIImage | 用 CIImage transform chain 通过 CVPixelBuffer 输出 | 播放器 + 导出双通；CIImage lazy chain 零内存拷贝 | 复杂度在 compositor 指令编排层 | ✅ |
| C: Metal 直渲染（无 CIImage 桥接）| 用 MTLCommandQueue + 自写着色器 | 最高性能、最低开销 | 工程量巨大；需重写所有现有调色/字幕/混合逻辑 | ❌ (V6.1 评估) |

**V6 定档：选项 B**。理由：(1) TimelineKit 已有 UnifiedCompositor 满足 `AVVideoCompositing` (B 选项骨架)；(2) 字幕烘焙路径已证明 CIImage→CIImage 合成可行；(3) CIImage lazy chain 免去每帧 additional pixel buffer allocation；(4) 无需重写调色/字幕/混合逻辑。

### 6.2 CIImage 在 V6 中的 use cases

| 操作 | 旧路径 (V5) | 新路径 (V6) |
|---|---|---|
| 加载图片 | MP4 → AVAssetReader → CVPixelBuffer | `CIImage(contentsOf: url)` 单行 |
| 图片 fit (cover/contain) | StaticImageRenderer 四角计算 | CIImage extent + canvas RenderSize → scale transform；同逻辑更快 |
| motion 动画 | 每帧采样 easeOut → transform → render to PixelBuffer → write to AssetWriter → 读取 → 解 → 合成 | 每帧采样 easeOut → transform → `ciImage.transformed(by:)` → composited |
| 合成 | `request.sourceFrame(byTrackID:)` → 双 PixelBuffer → blend | imageLayers CIImage array → `over` composited → final CIImage + subtitles → CVPixelBuffer output |
| 输出 | 片内已有 PixelBuffer → AVAssetWriter | CIContext.render(finalCI, to: buffer) |

**关键收益**：图片素材不再经过 VideoToolbox 编码 + AVAssetReader 解码的双重管道——这是旧路径最大的耗时源和内存峰值源。CIImage lazy chain 使得 transform 顺序不产生中间 buffer：`scale → translate → rotate → anchor` 一步到位为单个 transform 矩阵。

---

## 七、规则定档汇总（供 5 份 spec 引用）

| 决策点 | 选择 | 来源 |
|---|---|---|
| 图片渲染方式 | 废除 prebake MP4；CIImage 原生图层挂载时间轴 | §1.1 |
| Compositor 扩展 | UnifiedCompositor instruction 新增 `imageLayers` 字段；图片不生成 AVAssetTrack | §1.2 |
| 图片/视频图层统一能力集 | 切分/时长/转场/调色/overlay/z-order 等权 | §1.3 |
| 关键帧维度 | 5 维 MVP：position / scale / rotation / anchor / opacity | §2.1 |
| 缓动曲线 | 5 种：linear / ease / easeIn / easeOut / cubicBezier(p1,p2)；FCP 风格 40 段 LUT | §2.2 |
| 关键帧时间表达 | 0~1 标准化因子（非绝对秒）| §2.4 |
| 锚点 | 新增 `anchor: [KeyframePoint<CGPoint>]` | §2.4 |
| 2.5D parallax | 3 层 2D 图层叠加（剪映模型），不做 CATransform3D | §3.2 |
| 转场 + 关键帧 | 转场为 compositor 叠加层，关键帧继续求值 | §4 |
| GPU 加速 | `CIContext(mtlDevice:)` + `CVPixelBufferPool` | §5.1 |
| Compositor 基座 | 自定义 `AVVideoCompositing` + CIImage（选项 B） | §6.1 |
| 缓存策略 | CIImage lazy chain + CVPixelBuffer pool（不让 CIImage 产生中间 buffer）| §6.2 |
| 降级策略 | 预览 canvas 尺寸输出；导出 renderSize；3 层以上 image_3d 降为单层 | §5.1 |

---

## 八、未对齐项（V6 主动放弃的能力）

以下能力主流剪辑器有，V6 主动放弃：

| 能力 | 放弃理由 |
|---|---|
| CATransform3D 真 3D 变换 | 所有移动端对手的 "3D 照片" 本质是 2D 分层图层，不是真 3D；V6 用分层 2D 实现 parity |
| 关键帧 UI 编辑器（手动在画布上打点）| V6 关键帧底座主要消费 server 参数；手动 UI 编辑推到 V6.1+ |
| 自定义 Bezier 路径编辑 UI | 同关键帧 UI 编辑块 |
| Metal 直渲染（绕过 CIImage）| V6 先用 CIImage lazy chain 交付；Metal 直渲染的工程量和风险不成正比 |
| Skew / 3D 旋转关键帧 | 5 维 MVP 已覆盖 AI Timeline 全部下发参数；更多维度推到 V6.1+ |
| Hold / Catmull-Rom 缓动类型 | AI Timeline 缓动类型仅 3 种（easeIn / easeOut / easeInOut）；V6 的 5 种覆盖 + cubicBezier 扩展足够 |
| 多图层 inpainting（真实深度切片修补）| 先做 3 层简化 parallax；高质量 inpainting 推到 V6.1+ |
| Dolby Vision / HDR10+ | 同 V5 ❌ 理由 |

放弃决策由 [V6-initiation.md](V6-initiation.md) §2.3 / §2.4 留 roadmap 占位；P0/P1 上线后再评估是否单独立项。
