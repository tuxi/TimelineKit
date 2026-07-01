# 转场规范（v2）

> 版本：v2.0
> 状态：规范定稿，待实现
> 依赖：v1 时间轴基线、`EditorTransition` 数据模型（已存在于 v1）

---

## 一、竞品分析

### 1.1 剪映（CapCut / Jianying）—— 对标主体

| 维度 | 数据 |
|------|------|
| 默认时长 | 0.3 s |
| 最小时长 | ~0.1 s（拖拽下限） |
| 最大时长 | 5.0 s |
| Overlap 模型 | 50/50：各片段缩短 D/2 |
| Handle 要求 | 无（不需要额外素材余量，直接重叠现有片段） |
| 类型分层 | 基础（叠化/闪黑）、运镜（缩放/平移）、特效（粒子/故障） |
| 时长调整 | 右侧面板拖拽滑块 |
| 导出行为 | 渲染烘焙到成品 |

剪映的核心模型：**添加转场 = 两个片段各自从相邻端收缩 D/2，重叠区域显示过渡效果**。不需要多余素材（无 handle 约束），总视频时长减少 D。

### 1.2 Final Cut Pro —— 专业参考

| 维度 | 数据 |
|------|------|
| 默认时长 | 30 帧（≈1.0 s @ 30fps） |
| 最小时长 | 0.67 s（Preferences 最低档） |
| 最大时长 | 不设硬限（受素材 handle 约束） |
| Overlap 模型 | 50/50，以 edit point 为中心向两侧延伸 |
| Handle 要求 | **强制**：每侧需有 D/2 额外素材（片段须比入出点更长） |
| 时长调整 | Inspector 面板 / 时间轴直接拖拽 |

FCP 的 handle 约束适合专业剪辑（原始素材远长于成片），不适合移动端（服务端渲染片段长度恰好等于目标时长，无余量）。

### 1.3 LumaFusion —— iPad 参考

| 维度 | 数据 |
|------|------|
| 最小时长 | 0.20 s |
| Overlap 模型 | 50/50 |
| Handle 要求 | 需要（同 FCP 风格） |
| 类型 | Dissolve / Fade / Wipe / Zoom |

LumaFusion 的 0.20 s 最小值是合理的最低交互阈值。

### 1.4 竞品对比汇总

| 维度 | 剪映 | FCP | LumaFusion | **本规范定案** |
|------|------|-----|------------|---------------|
| 默认时长 | 0.3 s | 1.0 s | N/A | **0.5 s** |
| 最小时长 | ~0.1 s | 0.67 s | 0.20 s | **0.2 s** |
| 最大时长 | 5.0 s | 无限 | N/A | **3.0 s** |
| Handle 要求 | 无 | 强制 | 需要 | **无（剪映模型）** |
| Overlap | 50/50 | 50/50 | 50/50 | **50/50** |

> **定案依据**：本项目是移动端短视频工具，服务端渲染的片段无额外素材余量，必须采用剪映的无 handle 模型。默认 0.5 s 比剪映 0.3 s 略长，感知更平滑，同时优于 FCP 的 1.0 s 节奏。

---

## 二、规则定义

### 2.1 转场时长约束

```
minDuration  = 0.2 s
maxDuration  = 3.0 s
defaultDuration = 0.5 s

有效上限 = min(
    maxDuration,
    leadingSegment.targetRange.duration,
    trailingSegment.targetRange.duration
)
```

**解释**：转场不能比任何一侧片段更长（否则片段会被"吃光"）。

### 2.2 Overlap 模型（无 Handle，对齐剪映）

```
添加转场时：
  leadingSegment.targetRange.end  -= duration / 2
  trailingSegment.targetRange.start += duration / 2

  transitionRange = TimeRange(
      start: leadingSegment.targetRange.end,
      duration: duration
  )

移除转场时：
  leadingSegment.targetRange.end  += duration / 2
  trailingSegment.targetRange.start -= duration / 2
```

- 总视频时长减少 `duration`（与剪映一致）
- 两侧片段各"让出"一半时长给过渡区
- 不要求片段有任何额外素材余量

### 2.3 调整转场时长

用户拖动转场手柄时，时长变化量 `Δ` 需对称调整两侧片段：

```
newDuration = clamp(oldDuration + Δ,  minDuration, validMax)
Δactual = newDuration - oldDuration

leadingSegment.end   += Δactual / 2   // 前片段延伸或收缩
trailingSegment.start -= Δactual / 2  // 后片段延伸或收缩
```

### 2.4 转场类型（v2.0 范围）

**Phase 1（本次实现）** — 纯 `AVVideoCompositionLayerInstruction` opacity ramp，无自定义 compositor：

| 类型 ID | 名称 | 效果 |
|---------|------|------|
| `fade` | 叠化（Cross Dissolve）| A: 1.0→0.0 opacity，B: 0.0→1.0 opacity |
| `fadeToBlack` | 淡出黑场 | A: 1.0→0.0，黑场→B: 0.0→1.0（两段式） |

**Phase 2（后续版本）** — 需要自定义 `AVVideoCompositing`（CIFilter / Metal Shader）：

| 类型 | 说明 |
|------|------|
| `wipeLeft / wipeRight` | 划像 |
| `zoom` | 缩放推进 |
| `blur` | 模糊过渡 |
| `glitch` | 故障电视效果 |

Phase 2 在本规范中仅占位，不进入当前实现周期。

### 2.5 Easing 规则

| Easing ID | 曲线 | 使用场景 |
|-----------|------|---------|
| `linear` | 匀速 | 极少使用 |
| `easeIn` | 渐快 | 出场效果 |
| `easeOut` | 渐慢 | 入场效果 |
| `easeInOut` | S形 | **默认，所有转场** |

映射到 `AVVideoCompositionLayerInstruction`:
- `easeInOut` → 计算 Bezier 中间帧，对 `setOpacityRamp` 的采样点做非线性插值
- 实现上在 `CompositionBuilder` 里用 8 个分段 ramp 近似 S 曲线

---

## 三、数据模型

### 3.1 现有模型（v1，已存在）

```swift
public struct EditorTransition: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var type: TransitionType
    public var duration: Double
    public var easing: Easing
    public var leadingSegmentID: UUID
    public var trailingSegmentID: UUID
}
```

`TransitionType` 和 `Easing` 的 `rawValue` 已在 `TimelineImporter` 使用。

### 3.2 v2 需要扩展的类型

在 `EditorTransition.TransitionType` 中补充：

```swift
public enum TransitionType: String, Sendable {
    case cut        = "cut"         // 硬切（无效果，duration 忽略）
    case fade       = "fade"        // 叠化 ← Phase 1
    case fadeToBlack = "fade_black" // 淡黑 ← Phase 1
    // Phase 2:
    case wipeLeft   = "wipe_left"
    case wipeRight  = "wipe_right"
    case zoom       = "zoom"
    case blur       = "blur"
    case glitch     = "glitch"
}
```

### 3.3 EditorTimeline 新增操作

```swift
// EditorTimeline 扩展
mutating func addTransition(
    between leadingID: UUID,
    and trailingID: UUID,
    type: EditorTransition.TransitionType,
    duration: Double
) -> EditorTransition?

mutating func removeTransition(id: UUID)
mutating func updateTransition(id: UUID, duration: Double)
```

EditorStore 对应的 undo-tracked 包装：
```swift
public func addTransition(between: UUID, and: UUID, type:, duration:)
public func removeTransition(id: UUID)
public func updateTransition(id: UUID, duration: Double)
```

---

## 四、AVFoundation 渲染方案（Phase 1）

### 4.1 核心约束

AVFoundation 的 `AVMutableVideoCompositionInstruction` 要求：
- 所有指令的 `timeRange` **不能重叠**，且必须覆盖整个 composition 时长
- 转场区间需要**两条独立视频轨道**同时活跃

### 4.2 CompositionBuilder 改造

当前 `CompositionBuilder` 将所有主轨片段插入单条 `AVMutableCompositionTrack`。有转场时，需要：

```
普通片段：单轨插入（同 v1）
转场区间：双轨插入
  - 轨道 A（偶数轨道）：前片段的最后 duration/2
  - 轨道 B（奇数轨道）：后片段的最开始 duration/2
```

交替使用两条视频轨道（"ping-pong" 策略），避免每个转场都新增轨道：

```
segment 0 → trackA
segment 1 → trackB  （过渡区：trackA + trackB 并行）
segment 2 → trackA  （过渡区：trackB + trackA 并行）
segment 3 → trackB
...
```

### 4.3 VideoComposition 指令

**非转场区间**（正常播放）：

```swift
let instruction = AVMutableVideoCompositionInstruction()
instruction.timeRange = normalRange
let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
// opacity = 1.0（不设置即默认）
instruction.layerInstructions = [layerInstruction]
```

**转场区间**（叠化，easeInOut）：

```swift
let instruction = AVMutableVideoCompositionInstruction()
instruction.timeRange = transitionRange  // duration = D

// 前片段：opacity 1.0 → 0.0
let instrA = AVMutableVideoCompositionLayerInstruction(assetTrack: trackA)
instrA.setOpacityRamp(fromStartOpacity: 1.0, toEndOpacity: 0.0, timeRange: transitionRange)

// 后片段：opacity 0.0 → 1.0
let instrB = AVMutableVideoCompositionLayerInstruction(assetTrack: trackB)
instrB.setOpacityRamp(fromStartOpacity: 0.0, toEndOpacity: 1.0, timeRange: transitionRange)

instruction.layerInstructions = [instrB, instrA]  // B 在上（先绘制），A 在下
```

**淡黑（fadeToBlack）**：

```swift
// 前半段：A opacity 1.0 → 0.0
// 后半段：B opacity 0.0 → 1.0
// 中点没有任何可见内容 → 自然出现黑场
// 实现：拆成两个相邻指令，各自独立 ramp
```

### 4.4 easeInOut 近似

`setOpacityRamp` 是线性的。用 8 段分步 ramp 近似 cubic easeInOut：

```swift
func makeEasedRamp(
    from leading: AVMutableVideoCompositionLayerInstruction,
    startOpacity: Float, endOpacity: Float,
    timeRange: CMTimeRange, steps: Int = 8
) {
    let curve: [Float] = cubicEaseInOut(steps: steps)  // 预计算缓动采样
    let stepDur = CMTimeMultiplyByFloat64(timeRange.duration, multiplier: 1.0 / Double(steps))
    for i in 0..<steps {
        let t = CMTimeAdd(timeRange.start, CMTimeMultiply(stepDur, multiplier: Int32(i)))
        let segRange = CMTimeRange(start: t, duration: stepDur)
        let oStart = startOpacity + (endOpacity - startOpacity) * curve[i]
        let oEnd   = startOpacity + (endOpacity - startOpacity) * curve[i + 1]
        leading.setOpacityRamp(fromStartOpacity: oStart, toEndOpacity: oEnd, timeRange: segRange)
    }
}
```

---

## 五、时间轴 UI（TrackCanvasView 扩展）

### 5.1 视觉表现

- 转场标识：切割点上方覆盖一个**菱形图标** + 宽度等于转场时长的半透明条带
- 颜色：白色半透明（与片段颜色区分）
- 仅主轨（videoTrack）的切割点有转场 UI

### 5.2 交互

| 操作 | 行为 |
|------|------|
| 点击切割点空白区域 | 弹出转场类型选择器（bottom sheet） |
| 点击已有转场标识 | 弹出编辑面板（类型切换 + 时长滑块） |
| 左右拖拽转场标识两侧手柄 | 实时调整时长（对称调整两侧片段） |
| 长按转场标识 | 弹出删除确认 |

### 5.3 时长滑块约束

```
min = 0.2 s
max = min(leadingSegment.duration, trailingSegment.duration)
step = 0.1 s
```

---

## 六、边界情况处理

| 情况 | 处理规则 |
|------|---------|
| 片段时长 < minDuration×2 | 禁止添加转场（按钮灰化） |
| 调整时长超过有效上限 | 自动 clamp 到有效上限，不报错 |
| 移除转场后两侧片段恢复 | 原子 mutate，undo 一步还原 |
| `cut` 类型 | duration 忽略，无渲染指令，等同于无转场 |
| 主轨以外的轨道 | **不支持转场**（字幕/音频/叠加层无转场） |
| 导入的服务端转场 | 继续走 TimelineImporter 现有路径，渲染层新增支持即可生效 |

---

## 七、与 v1 的接口约束

- **不修改** `EditorTransition` 的 `leadingSegmentID` / `trailingSegmentID` / `easing` 字段语义
- **不修改** `TimelineImporter` 现有的转场解析逻辑
- `CompositionBuilder.build(from:)` 接口签名不变，内部新增转场渲染分支
- `compositionVersion` 变更触发时机不变：添加/移除/修改转场都通过 `mutate()` 路径，正常触发 rebuild

---

## 八、验收标准

| 项目 | 标准 |
|------|------|
| 叠化转场渲染 | 前后片段在过渡区平滑混合，无闪烁、无黑帧 |
| easeInOut 曲线 | 肉眼可见 S 形渐入渐出，非线性 |
| 时长约束 | 拖拽到边界自动卡位，不允许超出两侧片段时长 |
| 添加/移除原子性 | 一次 undo 完整还原两侧片段时长 + 转场状态 |
| 服务端导入转场 | 已有 `EditorTransition` 自动渲染，无需额外操作 |
| 性能 | 转场 rebuild 时间 ≤ 300 ms（与 v1 rebuild 基准一致） |
| 静态图 / 字幕 / 音频轨道 | 无转场 UI，无转场渲染，行为与 v1 完全相同 |
