# 滤镜 / 调色 / LUT 规范（v2）

> 版本：v2.0
> 状态：规范定稿，待实现
> 依赖：v1 渲染架构（`CompositionBuilder`）、v2 转场规范

---

## 一、竞品分析

### 1.1 剪映（CapCut / Jianying）—— 对标主体

#### 基础调节参数

| 参数 | 范围 | 默认 |
|------|------|------|
| 亮度 | -100 ~ +100 | 0 |
| 对比度 | -100 ~ +100 | 0 |
| 饱和度 | -100 ~ +100 | 0 |
| 锐化 | 0 ~ 100 | 0 |
| 高光 | -100 ~ +100 | 0 |
| 阴影 | -100 ~ +100 | 0 |
| 色温 | -100 ~ +100（冷→暖） | 0 |
| 色调 | -100 ~ +100（绿→洋红） | 0 |
| 暗角 | 0 ~ 100 | 0 |
| 褪色 | 0 ~ 100 | 0 |
| 颗粒 | 0 ~ 100 | 0 |

#### 滤镜体系

- **数量**：~200+ 滤镜，按场景分类（自然、美食、氛围、Vlog、风景等）
- **模型**：LUT（Look-Up Table），每个滤镜一份 .cube 文件
- **强度**：每个滤镜有 0-100% 强度滑块
- **作用范围**：可选「仅当前片段」或「应用到全部」
- **导入**：不支持用户自导入 LUT（封闭系统）

#### 调节 vs 滤镜叠加顺序

剪映的叠加顺序（从原始帧到输出）：

```
原始帧
 → 滤镜（LUT，整体风格色调）
 → 基础调节（亮度/对比/饱和/高光/阴影/锐化等）
 → 特效（粒子/故障等，视频层面）
输出帧
```

剪映把滤镜放在最底层，调节叠在上面——用户先定风格，再微调参数，符合"先宏观后微观"的用户习惯。

---

### 1.2 LumaFusion（iPad，专业参考）

| 维度 | 数据 |
|------|------|
| 调色工具 | 色彩校正（三向色轮：阴影/中间调/高光）+ 曲线 + HSL |
| LUT 支持 | 支持导入 .cube 文件，作用后可调强度 |
| 作用范围 | 逐片段 |
| 颜色曲线 | Master + R/G/B/Saturation 共 5 条 |
| 实时预览 | 是，Metal GPU 渲染 |

LumaFusion 的 HSL（Hue/Saturation/Luminance per color channel）和三向色轮属于专业剪辑师工具，移动端短视频用户利用率极低，适合 Phase 2 后续补充。

---

### 1.3 Lightroom Mobile（参考调色深度）

| 参数 | iOS 实现 |
|------|---------|
| 曝光/高光/阴影/白色/黑色 | CIHighlightShadowAdjust |
| 对比/清晰度/自然饱和度 | CIColorControls + CIVibrance |
| 色温/色调 | CITemperatureAndTint |
| 曲线 | 无对应系统 CIFilter，需自定义 |
| 降噪/锐化 | CINoiseReduction / CIUnsharpMask |

Lightroom 的色调曲线（Point Curve）需要自定义 Metal Shader，是 Phase 2 范畴。

---

### 1.4 竞品对比汇总

| 维度 | 剪映 | LumaFusion | Lightroom | **本规范定案** |
|------|------|------------|-----------|--------------|
| 基础调节 | 11项 | 3向色轮+曲线 | 12项 | **7项（Phase 1）** |
| 滤镜 | 200+ LUT | 自定义 LUT | 预设+自定义 | **12内置预设（Phase 1）** |
| LUT 导入 | 否 | 是 | 是 | **否（Phase 2）** |
| HSL 分色 | 是 | 是 | 是 | **否（Phase 2）** |
| 作用范围 | 片段/全局 | 片段 | 全局 | **片段（Phase 1）** |
| 实时预览 | 是 | 是 | 是 | **是** |
| 叠加顺序 | 滤镜→调节 | 校正→LUT | 调节→LUT | **调节→滤镜** |

> **定案依据**：本项目面向移动端短视频，7 项基础调节覆盖 95% 的使用场景。12 个内置滤镜提供开箱即用的风格，无需用户自行导入 LUT。叠加顺序采用"调节→滤镜"而非剪映的"滤镜→调节"，因为先调节再加滤镜可以保证参数调节的可预期性（调节量直接对应最终效果，不受滤镜色调偏移干扰）。

---

## 二、规则定义

### 2.1 基础调节参数（Phase 1，7项）

| 参数 ID | 显示名 | 范围 | 默认 | CIFilter 映射 |
|---------|--------|------|------|--------------|
| `brightness` | 亮度 | -1.0 ~ +1.0 | 0 | `CIColorControls.inputBrightness` |
| `contrast` | 对比度 | 0.5 ~ 1.5 | 1.0 | `CIColorControls.inputContrast` |
| `saturation` | 饱和度 | 0.0 ~ 2.0 | 1.0 | `CIColorControls.inputSaturation` |
| `temperature` | 色温 | 2000 ~ 9000 K | 6500 | `CITemperatureAndTint` |
| `tint` | 色调 | -150 ~ +150 | 0 | `CITemperatureAndTint` |
| `highlights` | 高光 | -1.0 ~ +1.0 | 0 | `CIHighlightShadowAdjust.inputHighlightAmount` |
| `shadows` | 阴影 | -1.0 ~ +1.0 | 0 | `CIHighlightShadowAdjust.inputShadowAmount` |

> `CIColorControls`、`CITemperatureAndTint`、`CIHighlightShadowAdjust` 均为 iOS 系统 CIFilter，Metal GPU 加速，无需自定义 Shader。

**"零调节"判断**：当且仅当所有参数都等于默认值且 `filterName == nil` 时，判定为无调节，跳过 CIFilter 链，直接透传原始帧，避免不必要的 GPU 开销。

### 2.2 CIFilter 应用链（Phase 1）

```
rawFrame (CVPixelBuffer)
   │
   ▼  [仅当 brightness/contrast/saturation 有非默认值时执行]
CIColorControls
   │
   ▼  [仅当 temperature ≠ 6500 或 tint ≠ 0 时执行]
CITemperatureAndTint
   │
   ▼  [仅当 highlights ≠ 0 或 shadows ≠ 0 时执行]
CIHighlightShadowAdjust
   │
   ▼  [仅当 filterName ≠ nil 时执行，filterIntensity 混合]
预设滤镜（CIPhotoEffect 或 CIColorCube）
   │
   ▼
outputFrame (CVPixelBuffer)
```

每一步仅在参数偏离默认值时才真正创建并执行 CIFilter，避免透传帧也走完整链路。

### 2.3 预设滤镜（Phase 1，12个）

分三类，全部使用系统 CIPhotoEffect 滤镜（无需外部 LUT 文件）：

**自然（Natural）**

| ID | 显示名 | CIFilter | 特点 |
|----|--------|----------|------|
| `natural_vivid` | 鲜艳 | CIVibrance | 自然饱和度提升 |
| `natural_warm` | 暖调 | CIPhotoEffectProcess | 暖色调，增强橙黄 |
| `natural_cool` | 冷调 | CIPhotoEffectFade + 色温偏移 | 冷蓝色调 |
| `natural_soft` | 柔和 | CIPhotoEffectTonal | 轻微去饱和，柔化 |

**电影（Cinematic）**

| ID | 显示名 | CIFilter | 特点 |
|----|--------|----------|------|
| `cinema_chrome` | 铬黄 | CIPhotoEffectChrome | 高对比，铬黄色调 |
| `cinema_noir` | 黑白 | CIPhotoEffectNoir | 强对比黑白 |
| `cinema_instant` | 拍立得 | CIPhotoEffectInstant | 褪色感，暖黄色调 |
| `cinema_mono` | 单色 | CIPhotoEffectMono | 柔和黑白 |

**复古（Retro）**

| ID | 显示名 | CIFilter | 特点 |
|----|--------|----------|------|
| `retro_transfer` | 转印 | CIPhotoEffectTransfer | 复古胶片感 |
| `retro_fade` | 褪色 | CIPhotoEffectFade | 淡雅褪色 |
| `retro_process` | 冲印 | CIPhotoEffectProcess | 冷调复古 |
| `retro_sepia` | 棕褐 | CISepiaTone | 怀旧棕褐色 |

### 2.4 滤镜强度混合公式

```swift
// filterIntensity ∈ [0.0, 1.0]，0 = 原始帧，1 = 滤镜满强度
outputImage = CIFilter.dissolve(inputImage: filteredFrame,
                                inputBackgroundImage: rawFrame,
                                inputTime: filterIntensity)
// 等价于：output = filteredFrame * intensity + rawFrame * (1 - intensity)
```

强度为 0 时完全回到原始，等同于无滤镜。

### 2.5 作用范围规则

| 情况 | 行为 |
|------|------|
| 片段有 `adjustment` | 仅对该片段生效 |
| 片段无 `adjustment`（nil） | 透传，无任何处理 |
| 多片段各自独立调节 | 互不影响 |
| 主轨以外的轨道 | **不支持调色**（字幕/音频/叠加层不处理） |
| 静态图片段 | 与视频片段相同，在渲染时帧已经是静态视频，正常处理 |

---

## 三、数据模型

### 3.1 新增类型：`SegmentAdjustment`

```swift
public struct SegmentAdjustment: Sendable, Hashable {
    public var brightness:      Double   // -1.0 ~ +1.0, default 0
    public var contrast:        Double   // 0.5 ~ 1.5,   default 1.0
    public var saturation:      Double   // 0.0 ~ 2.0,   default 1.0
    public var temperature:     Double   // 2000 ~ 9000, default 6500
    public var tint:            Double   // -150 ~ +150, default 0
    public var highlights:      Double   // -1.0 ~ +1.0, default 0
    public var shadows:         Double   // -1.0 ~ +1.0, default 0
    public var filterName:      String?  // nil = 无预设滤镜
    public var filterIntensity: Double   // 0.0 ~ 1.0,   default 1.0

    public static let identity = SegmentAdjustment()  // 所有参数=默认值

    /// 是否等同于无调节（透传短路条件）
    public var isIdentity: Bool {
        brightness == 0 && contrast == 1 &&
        saturation == 1 && temperature == 6500 &&
        tint == 0 && highlights == 0 && shadows == 0 &&
        filterName == nil
    }
}
```

### 3.2 `EditorSegment` 扩展

```swift
// EditorSegment 新增字段
public var adjustment: SegmentAdjustment?
// nil = 无调节，不触发任何 CIFilter 开销
```

nil vs `SegmentAdjustment.identity` 的区别：nil 表示"用户从未打开过调色面板"，`identity` 表示"用户打开过但重置到了默认值"。两者的渲染行为相同（透传），但 UI 上"重置"按钮的可用状态不同。

### 3.3 EditorStore 新增操作

```swift
/// 设置片段调节参数（undo-tracked，触发 composition rebuild）
public func setAdjustment(_ adj: SegmentAdjustment, for segmentID: UUID)

/// 重置片段调节为 identity（undo-tracked）
public func resetAdjustment(for segmentID: UUID)

/// 预览调节（无 undo，无 rebuild）—— 供滑块拖拽实时预览
public func previewAdjustment(_ adj: SegmentAdjustment, for segmentID: UUID)
```

---

## 四、AVFoundation 渲染方案

### 4.1 核心架构决策：自定义 AVVideoCompositing

`AVMutableVideoCompositionInstruction` 的 `layerInstructions` 只支持 opacity/transform，无法传递调色参数。要在渲染管线中插入 CIFilter，必须使用自定义合成器：

```swift
videoComposition.customVideoCompositorClass = ColorAdjustmentCompositor.self
```

自定义合成器实现 `AVVideoCompositing` 协议：
- 接收 `AVVideoCompositionRequest`（包含源 pixel buffer）
- 查找该帧对应的 `SegmentAdjustment`
- 应用 CIFilter 链
- 将结果写入 `request.renderContext.newPixelBuffer()`

### 4.2 与转场的共存策略

**Phase 1 约束**：颜色调节和转场**不能同时使用自定义合成器**——AVFoundation 只允许一个合成器类。

解决方案：

| 场景 | 合成器 | 转场 | 调色 |
|------|--------|------|------|
| 仅转场 | 内置（opacity ramp）| ✅ | ❌ |
| 仅调色 | 自定义 ColorAdjustmentCompositor | ❌ | ✅ |
| 转场 + 调色 | 统一自定义合成器（Phase 1b）| ✅ | ✅ |

**Phase 1 实现顺序**：
1. Phase 1a：`ColorAdjustmentCompositor` 处理无转场时间轴的调色
2. Phase 1b：将转场 opacity ramp 逻辑迁移进 `ColorAdjustmentCompositor`，实现统一管线

**Phase 1a 的 dispatch 逻辑**（`CompositionBuilder`）：

```swift
if timeline.transitions.isEmpty {
    if needsColorAdjustment(timeline) {
        // 自定义合成器路径（无转场 + 有调色）
        videoComposition.customVideoCompositorClass = ColorAdjustmentCompositor.self
        videoComposition.instructions = buildColorAdjustmentInstructions(...)
    } else {
        // 现有 SinglePass 路径
    }
} else {
    // 现有 PingPong 路径（调色暂不支持，Phase 1b 整合）
}
```

### 4.3 ColorAdjustmentInstruction

自定义 instruction 需要遵从 `AVVideoCompositionInstructionProtocol`（非 `AVMutableVideoCompositionInstruction` 子类）：

```swift
final class ColorAdjustmentInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange
    var enablePostProcessing = true
    var containsTweening    = false
    var requiredSourceTrackIDs: [NSValue]
    var passthroughTrackID: CMPersistentTrackID

    // 调色参数：该时间段内生效的调节
    let adjustment: SegmentAdjustment?

    // ...init...
}
```

`passthroughTrackID`：当 `adjustment.isIdentity` 时设置为该片段的 track ID，通知 AVFoundation 跳过自定义合成直接透传，无 CIFilter 开销。

### 4.4 ColorAdjustmentCompositor 核心实现

```swift
final class ColorAdjustmentCompositor: NSObject, AVVideoCompositing {

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { }

    func startRequest(_ request: AVVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? ColorAdjustmentInstruction,
              let adj = instruction.adjustment, !adj.isIdentity,
              let srcBuffer = request.sourceFrame(byTrackID: instruction.requiredSourceTrackIDs.first!.int32Value),
              let destBuffer = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(...))  // passthrough or error
            return
        }

        let result = applyAdjustment(adj, to: CIImage(cvPixelBuffer: srcBuffer))
        ciContext.render(result, to: destBuffer)
        request.finish(withComposedVideoFrame: destBuffer)
    }

    private func applyAdjustment(_ adj: SegmentAdjustment, to image: CIImage) -> CIImage {
        var img = image

        // 1. 基础调节
        if adj.brightness != 0 || adj.contrast != 1 || adj.saturation != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: adj.brightness,
                kCIInputContrastKey:   adj.contrast,
                kCIInputSaturationKey: adj.saturation
            ])
        }

        // 2. 色温/色调
        if adj.temperature != 6500 || adj.tint != 0 {
            let neutral = CIVector(x: CGFloat(adj.temperature), y: CGFloat(adj.tint))
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": neutral
            ])
        }

        // 3. 高光/阴影
        if adj.highlights != 0 || adj.shadows != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1.0 + adj.highlights,
                "inputShadowAmount":    adj.shadows
            ])
        }

        // 4. 预设滤镜（带强度混合）
        if let name = adj.filterName,
           let filterImg = applyPresetFilter(name, to: img) {
            img = filterImg.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputImageKey:           filterImg,
                kCIInputBackgroundImageKey: image,  // 原始帧
                kCIInputTimeKey:            adj.filterIntensity
            ])
        }

        return img
    }
}
```

### 4.5 CIContext 复用策略

CIContext 创建开销大（约 50–100ms），必须全局复用：
- `ColorAdjustmentCompositor` 持有一个 `CIContext`（Metal backend）
- 同一 `CompositionBuilder` actor 的多次 build 复用同一个实例（通过 actor 隔离保证线程安全）

---

## 五、时间轴 UI（调色面板）

### 5.1 入口

| 入口 | 行为 |
|------|------|
| 底部工具栏「调色」按钮 | 弹出调色面板（bottom sheet，210pt 高） |
| 面板仅在主轨片段被选中时可用 | 非主轨片段选中时按钮灰化 |

### 5.2 调色面板结构

```
┌─────────────────────────────────────┐
│  [调色]    [滤镜]          [重置] [完成] │  ← 分段控件 + 操作
├─────────────────────────────────────┤
│  调色 tab:                           │
│  亮度    ────●────  +0.3             │
│  对比度  ────●────  1.1              │
│  饱和度  ──●──────  0.8              │
│  色温    ────────●  7200K            │
│  高光    ──●──────  -0.2             │
│  阴影    ──────●──  +0.3             │
├─────────────────────────────────────┤
│  滤镜 tab:                           │
│  [原始] [鲜艳] [暖调] [冷调] ...     │  ← 横向滚动缩略图
│                 强度 ────●────  80%  │
└─────────────────────────────────────┘
```

### 5.3 实时预览策略

- 滑块拖拽中：调用 `store.previewAdjustment()`（无 rebuild，直接更新 `EditorPreviewView` 的 CIFilter）
- 滑块释放（.ended）：调用 `store.setAdjustment()`（undo-tracked，触发 `compositionVersion++` → rebuild）
- 滤镜缩略图点击：立刻触发 rebuild（不需要 preview，点击即生效）

### 5.4 滤镜缩略图生成

- 取被选中片段第一帧（`playheadTime` 对应的帧）
- 应用每个预设滤镜 → 生成 60×60pt 缩略图
- 缩略图在面板打开时异步生成，生成完毕前显示骨架占位

---

## 六、边界情况处理

| 情况 | 处理规则 |
|------|---------|
| 片段无 URL（生成中）| adjustment 保存到数据模型，rebuild 时跳过无 URL 片段 |
| 调色 + 转场共存（Phase 1） | 有转场的时间轴调色不生效（面板可操作，数据保存，Phase 1b 整合后生效） |
| `isIdentity == true` | `passthroughTrackID` 短路，不创建 CIFilter，零 GPU 开销 |
| `SegmentAdjustment` 全部字段默认 | 等同于 nil，CompositionBuilder 不启用自定义合成器路径 |
| 主轨以外片段选中 | 调色按钮 disabled，面板不弹出 |
| 导出路径 | 与预览使用同一个 `ColorAdjustmentCompositor`，无需额外处理 |

---

## 七、与 v1/v2 转场的接口约束

- **不修改** `CompositionBuilder.build(from:)` 对外签名
- **不修改** `EditorTransition` 相关逻辑
- 现有 `SinglePass` 和 `PingPong` 路径不变；调色作为第三路径：`ColorAdjustmentPass`
- `EditorSegment.adjustment` 是可选字段，nil 时完全不影响现有渲染逻辑

---

## 八、验收标准

| 项目 | 标准 |
|------|------|
| 基础调节实时预览 | 滑块拖拽延迟 ≤ 2 帧（约 66ms @ 30fps），无可见卡顿 |
| 滤镜切换 | 点击后 ≤ 300ms 生效（与 v1 rebuild 基准一致） |
| `isIdentity` 短路 | 无调节片段不创建任何 CIFilter，CPU/GPU 占用与 v1 无差异 |
| 调色 + undo | 一次 undo 完整还原调节参数 + 上一帧效果 |
| 导出一致性 | 导出视频与预览视觉效果完全一致，无色偏 |
| 滤镜缩略图 | 面板打开后 ≤ 500ms 完成全部 12 个缩略图渲染 |
| Phase 1a 限制 | 有转场时间轴：调色面板可操作，但展示「转场片段暂不支持调色，将在后续版本支持」提示 |
| 转场回归 | 加入调色后，无调节片段的转场渲染与 v2 转场规范完全一致，无回归 |

---

## 九、实现路线（Phase 1 拆解）

```
Phase 1a（调色核心）：
  1. SegmentAdjustment 数据模型
  2. EditorSegment.adjustment 字段
  3. EditorStore.setAdjustment / resetAdjustment / previewAdjustment
  4. ColorAdjustmentCompositor（CIFilter 链）
  5. CompositionBuilder 新增 ColorAdjustmentPass 分支
  6. 调色面板 UI + 实时预览绑定
  7. 滤镜缩略图生成

Phase 1b（转场 + 调色统一合成器）：
  1. ColorAdjustmentCompositor 扩展支持 ping-pong 双轨 opacity ramp
  2. CompositionBuilder 合并 PingPong 路径进 ColorAdjustmentCompositor
  3. 调色 + 转场同时生效的端到端测试
```

Phase 1b 是架构整合，Phase 1a 可以独立交付且不破坏现有转场功能。
