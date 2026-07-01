# 关键帧动画规范（v6）

> 版本：v6.0
> 状态：规范定稿，待实现
> 优先级：P0-B（架构打底第二阶段，与 image-layer-rendering 紧密耦合）
> 对标产品：剪映 / CapCut（全维 keyframe + 预设缓动）+ FCP（Bezier 控制点 + 40 段 LUT）+ LumaFusion v5.0（Bezier handle 路径 + separable scale）
> 依赖：
> - v6 [image-layer-rendering-spec.md](image-layer-rendering-spec.md) §3-§4：ImageLayerSpec 与 ImageLayerComposer 宿主
> - v6 [competitive-benchmarks-v6.md](competitive-benchmarks-v6.md) §2：关键帧维度覆盖与缓动曲线定档
> - [EditorSegment.swift:38-48](../../Sources/TimelineKit/Models/EditorSegment.swift) `KeyframeSet`（要扩展的数据模型）
> - [SegmentContent.swift:33-51](../../Sources/TimelineKit/Models/SegmentContent.swift) `ImageContent`（新增 `keyframes` 字段的落点）

---

## 一、覆盖范围

本规范覆盖 V6 P0-B「关键帧动画底座」的全部设计与约束：

1. **关键帧数据模型**：V5 已有 `KeyframeSet` + `KeyframePoint<T>` 的重构与扩展
2. **缓动曲线系统**：5 种曲线（linear / ease / easeIn / easeOut / cubicBezier）+ FCP 风格 40 段 LUT 预采样
3. **KeyframeEvaluator**：标准时间因子 0~1 → 指定维度在指定时刻的插值 → 最终 CGAffineTransform
4. **AnimationMacro**：`motionPreset` / `depthEffect` 预设 → 关键帧序列展开

---

## 二、现状与缺口

### 2.1 V5 KeyframeSet 已有能力

**已有**（[EditorSegment.swift:38-48](../../Sources/TimelineKit/Models/EditorSegment.swift)）：

```swift
public struct KeyframeSet: Codable, Sendable {
    public var opacity:  [KeyframePoint<Double>] = []
    public var position: [KeyframePoint<CGPoint>] = []
    public var scale:    [KeyframePoint<CGVector>] = []
    public var rotation: [KeyframePoint<Double>] = []  // radians
}

public struct KeyframePoint<T: Codable & Sendable>: Codable, Sendable {
    public var time: Double      // 绝对秒（V5）
    public var value: T
    public var easing: String    // 魔术字符串（V5）
}
```

**缺口**：

1. `time: Double`（绝对秒）→ 改为 `timeFraction: Double`（0~1），使得用户改 segment 时长后关键帧自动伸缩
2. `easing: String` → 改为 `easing: EasingCurve` 类型安全枚举
3. 缺 `anchor: [KeyframePoint<CGPoint>]` 维度——缩放中心不可控
4. ImageContent 完全忽略 `KeyframeSet`——图片段落没有关键帧消费点

### 2.2 V6 变更清单

| 字段 | V5 | V6 | 兼容处理 |
|---|---|---|---|
| `time` | `Double`（秒）| `timeFraction: Double`（0~1）| 字段改名；旧草稿含 `time` 时 `init(from decoder)` 做迁移：`timeFraction = oldTime / durationHint` |
| `easing` | `String` | `EasingCurve`（enum）| 旧草稿的 String 值映射到匹配的 enum case；不匹配 → `.ease` 默认 |
| `anchor` | 不存在 | `[KeyframePoint<CGPoint>]?` | `decodeIfPresent`；nil → (0.5, 0.5) |
| ImageContent 消费 | 无 | 新增 `keyframes: KeyframeSet?` | nil → AnimationMacro 展开 |

---

## 三、V6 KeyframeSet 最终型

### 3.1 结构定义

在 `EditorSegment.swift` 中重构：

```swift
/// 关键帧集合——图片图层的可动属性
public struct KeyframeSet: Codable, Sendable {
    /// 使用 0~1 标准化时间因子，使关键帧在 segment 时长变化时自动伸缩
    public var opacity:  [KeyframePoint<Double>]  = []
    public var position: [KeyframePoint<CGPoint>] = []
    public var scale:    [KeyframePoint<CGVector>] = []  // x, y 可分维
    public var rotation: [KeyframePoint<Double>]  = []   // radians
    public var anchor:   [KeyframePoint<CGPoint>] = []   // 默认 (0.5, 0.5)
}

/// 单一关键帧点——标准化时间 + 值 + 缓动曲线
public struct KeyframePoint<T: Codable & Sendable>: Codable, Sendable {
    /// 标准化时间因子 0~1（0 = segment 开头，1 = segment 结尾）
    public var timeFraction: Double
    /// 在此时刻的目标值
    public var value: T
    /// 缓动曲线（从上一个关键帧到此关键帧的过渡方式）
    public var easing: EasingCurve
}

/// 缓动曲线枚举——预设 + 参数化 Bezier
public enum EasingCurve: String, Codable, Sendable {
    case linear
    case ease       // 缓入缓出 = CAMediaTimingFunction(name: .easeInEaseOut)
    case easeIn     // 缓入
    case easeOut    // 缓出
    case cubicBezier(x1: Double, y1: Double, x2: Double, y2: Double)
}
```

### 3.2 与 V5 的兼容迁移（Codable 适配器）

`KeyframeSet` 的 `init(from decoder:)` 做兼容：

```swift
// 旧草稿字段兼容方案
// 1. 检测是否存在 "time" 字段（旧名）vs "timeFraction"（新名）
// 2. 旧 time 值 → timeFraction = max(min(time / durationHint, 1.0), 0.0)
// 3. easing String → EasingCurve(rawValue:)
//    不匹配 → .ease (safe default)
// 4. anchor 不存在 → []
```

`ImageContent` 的兼容：

```swift
// 旧草稿中 ImageContent 不含 keyframes 字段
// decodeIfPresent → nil
// 加载后由 AnimationMacro.expand() 填充
```

### 3.3 锚点的变换公式

锚点不是独立图形变换，而是插入到 `baseScale → rotation → scale → position` 链中：

```
finalMatrix = T(position) * T(anchor_in_canvas) * R(rotation) * S(scale) * T(-anchor_in_image)
```

其中 `T(p)` 是平移矩阵，`R` 是旋转，`S` 是缩放。锚点的默认值 `(0.5, 0.5)` 使得缩放和旋转默认以图片中心为原点。

---

## 四、EasingCurve 求值器 — 40 段 LUT

### 4.1 设计理由

- 每个关键帧之间的过渡区间需要 `timeFraction → easedFraction` 的映射
- 逐帧计算 Bezier 多项式开销高（每次 4 次乘法 + 3 次加法 × 牛顿迭代收敛），对 30fps × 5 关键帧 × 4 维 = 600 次/秒的负担是可感知的
- FCP 的 40 段 LUT 方案将 0~1 域均匀切分为 40 段，预先计算 eased 值；运行时 O(1) 查表 + 段内线性插值

### 4.2 LUT 生成

每种曲线在 `EasingCurve` 的初始化或首次使用时生成长度为 41 的 `[Double]` 数组（40 段 = 41 个端点）：

```swift
func generateLUT(curve: EasingCurve) -> [Double] {
    let segments = 40
    var lut = [Double](repeating: 0, count: segments + 1)
    for i in 0...segments {
        let t = Double(i) / Double(segments)
        lut[i] = switch curve {
        case .linear:
            t
        case .easeIn:
            // CAMediaTimingFunction(controlPoints: 0.42, 0, 1, 1) 的采样值
            cubicBezier(t: t, cp1x: 0.42, cp1y: 0, cp2x: 1, cp2y: 1)
        case .easeOut:
            // CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
            cubicBezier(t: t, cp1x: 0, cp1y: 0, cp2x: 0.58, cp2y: 1)
        case .ease:
            // CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
            cubicBezier(t: t, cp1x: 0.42, cp1y: 0, cp2x: 0.58, cp2y: 1)
        case .cubicBezier(let x1, let y1, let x2, let y2):
            cubicBezier(t: t, cp1x: x1, cp1y: y1, cp2x: x2, cp2y: y2)
        }
    }
    return lut
}
```

### 4.3 运行时求值

```swift
func evaluate(lut: [Double], t: Double) -> Double {
    let segments = 40
    let scaled = max(min(t, 1.0), 0.0) * Double(segments)
    let idx = Int(scaled)                    // 整数段索引
    let frac = scaled - Double(idx)          // 段内插值因子
    let lo = lut[min(idx, segments)]
    let hi = lut[min(idx + 1, segments)]
    return lo + (hi - lo) * frac
}
```

运算量：1 次乘法 + 2 次加法（极小，比贝塞尔求值低 10x+）。

### 4.4 与 V5 easeOut 的对齐验证

V5 StaticImageRenderer 行 181 使用的是直接逐帧贝塞尔采样。V6 的 easeOut LUT 和 V5 逐帧贝塞尔在 0~1 域内四舍五入后重合（两者使用相同的控制点 (0, 0, 0.58, 1.0)），对 1080P 30fps 场景在子像素精度下无可见差异。

P0-C 阶段要建立对照矩阵：12 个 motionPreset × 3 个时长（2s / 5s / 10s）截屏 diff ≤ 2px。

---

## 五、KeyframeEvaluator — 多维度到复合变换

### 5.1 核心接口

```swift
struct KeyframeEvaluator {
    /// 在给定标准化时间和关键帧集合下计算最终的 CGAffineTransform
    /// - Parameters:
    ///   - keyframes: 图片图层的完整关键帧集合
    ///   - timeFraction: 标准化时间 0~1
    ///   - canvasSize: 画布尺寸（用于锚点像素坐标转换）
    /// - Returns: motion 变换矩阵（不含 baseScale——baseScale 由 ImageLayerComposer 单独计算）
    static func evaluate(
        keyframes: KeyframeSet,
        at timeFraction: Double,
        canvasSize: CGSize
    ) -> CGAffineTransform
}
```

### 5.2 单维度插值

对 `[KeyframePoint<T>]` 使用通用插值函数：

```swift
func interpolate<T: Interpolatable>(points: [KeyframePoint<T>], at t: Double) -> T? {
    guard !points.isEmpty else { return nil }
    // 取 t 前后的两个关键帧
    let sorted = points.sorted { $0.timeFraction < $1.timeFraction }
    if t <= sorted[0].timeFraction { return sorted[0].value }
    if t >= sorted.last!.timeFraction { return sorted.last!.value }

    for i in 0..<(sorted.count - 1) {
        if t >= sorted[i].timeFraction && t <= sorted[i+1].timeFraction {
            let localT = (t - sorted[i].timeFraction) /
                         (sorted[i+1].timeFraction - sorted[i].timeFraction)
            let easedT = EasingCurve.evaluate(curve: sorted[i+1].easing, t: localT)
            return T.lerp(sorted[i].value, sorted[i+1].value, easedT)
        }
    }
    return sorted.last!.value
}
```

### 5.3 多维度复合为 CGAffineTransform

```swift
static func evaluate(keyframes: KeyframeSet, at t: Double, canvasSize: CGSize) -> CGAffineTransform {
    let anchorPt = interpolate(points: keyframes.anchor, at: t) ?? CGPoint(x: 0.5, y: 0.5)
    let pos      = interpolate(points: keyframes.position, at: t) ?? .zero
    let scl      = interpolate(points: keyframes.scale, at: t)    ?? CGVector(dx: 1, dy: 1)
    let rot      = interpolate(points: keyframes.rotation, at: t) ?? 0.0

    let anchorInCanvas = CGPoint(x: anchorPt.x * canvasSize.width,
                                 y: anchorPt.y * canvasSize.height)

    var transform = CGAffineTransform.identity
    transform = transform.translatedBy(x: pos.x, y: pos.y)            // position
    transform = transform.translatedBy(x: anchorInCanvas.x, y: anchorInCanvas.y)
    transform = transform.rotated(by: rot)                             // rotation
    transform = transform.scaledBy(x: scl.dx, y: scl.dy)               // scale
    transform = transform.translatedBy(x: -anchorInCanvas.x, y: -anchorInCanvas.y)
    return transform
}
```

**变换链顺序**（左乘即最后 applied 最先写）——等效于 `position → anchor → rotation → scale → translate(-anchor)` 的标准 affine 顺序。

### 5.4 不透明度的独立求值

opacity 不进入 CGAffineTransform（变换矩阵不承载 opacity），而是返回 Double 值交由 `ImageLayerComposer` 或 compositor 以上层混合：

```swift
static func evaluateOpacity(keyframes: KeyframeSet, at t: Double) -> Double {
    return interpolate(points: keyframes.opacity, at: t) ?? 1.0
}
```

最终图层不透明度 = `evaluateOpacity(keyframes, at: t) * spec.baseOpacity`。

---

## 六、AnimationMacro — 预设 → 关键帧展开

### 6.1 目的

`motionPreset` / `depthEffect` 作为快捷预设，在运行时展开为标准 `KeyframeSet`。这样播放/导出链路上不会出现「有些图片走了关键帧路径、有些走了 motionPreset 特殊分支」——**全部统一走 KeyframeEvaluator**。

### 6.2 ImageMotionPreset → KeyframeSet

```swift
enum AnimationMacro {
    static func expand(
        motionPreset: ImageMotionPreset?,
        depthEffect: DepthEffect?,
        duration: Double
    ) -> KeyframeSet?
}
```

**motionPreset 映射表**（对齐 StaticImageRenderer 行 224-271 的 6 方向逻辑）：

| motionPreset | 关键帧 | 描述 |
|---|---|---|
| zoom_in | scale: (1,1)@t=0 → (1.15,1.15)@t=1.0, easeOut | 放大推进 |
| zoom_out | scale: (1.15,1.15)@t=0 → (1,1)@t=1.0, easeOut | 缩小拉远 |
| pan_left | position: (0,0)@t=0 → (-30px,0)@t=1.0, easeOut | 左移 |
| pan_right | position: (0,0)@t=0 → (30px,0)@t=1.0, easeOut | 右移 |
| pan_up | position: (0,0)@t=0 → (0,-30px)@t=1.0, easeOut | 上移 |
| pan_down | position: (0,0)@t=0 → (0,30px)@t=1.0, easeOut | 下移 |

位移量 30px 是 StaticImageRenderer 中对应到 1080P 画布的值（由运动安全边距计算得出：`motionSafetyMargin = canvas.width * 0.05 ≈ 54px`，位移量约为其一半）。

### 6.3 depthEffect → KeyframeSet（2.5D parallax 展开）

由 [ai-timeline-mapping-spec.md](ai-timeline-mapping-spec.md) §3 详细定义落点到 `SCamera` → 3 层 ImageLayerSpec 的展开逻辑。`AnimationMacro` 负责把 `DepthEffect`（moveDirection + intensity + duration）转换为每层的 position + scale + opacity 关键帧。

---

## 七、验证点

| 验证项 | 预期行为 | 方法 |
|---|---|---|
| linear 缓动 | 均匀过渡 | 截屏 t=0, 0.25, 0.5, 0.75, 1.0 的 scale 值，5 点应在一条直线上 |
| easeOut LUT vs V5 逐帧贝塞尔 | diff ≤ 2px | 12 组 motionPreset × 3 时长对比截屏 |
| cubicBezier(0.17,0.67,0.83,0.67) | 与传统 CSS ease-in-out 对齐 | LUT 值与 Chrome / Safari 输出对比 |
| anchor (0.2, 0.2) + scale 2x | 缩放以图片左上角区域为中心 | 截屏验证缩放中心偏移 |
| segment 时长由 5s 改为 10s | 关键帧自然伸缩，动画不变形 | 两个时长截屏时间点对应 canvas 位置一致 |
| 旧草稿 KeyframeSet.time → timeFraction | 动画与 V5 一致 | 加载 V5 草稿 → 播放截屏 与 V5 对比 |
| opacity 1 → 0 → 1 over 3 keyframes | 淡入淡出平滑 | 截屏中点 t=0.5 半透明 |
| position + scale + rotation 三组合 | 三个维度同时求值，矩阵复合正确 | 截屏与单一复合矩阵手工计算对比 |

---

## 八、V6 固定交互约束重申

> 见 [V6-initiation.md §7](V6-initiation.md)。实现本 spec 时须遵守：
> - **关键帧 5 维即 MVP 上限**：新增维度推到 V6.1+
> - **预设作为语法糖、运行时一律展开为关键帧**：`motionPreset` / `depthEffect` 不在渲染链路单独成分支
> - **关键帧时间因子标准化（0~1）**：不与 absolute CMTime 互转
> - 其他约束全文见 V6-initiation.md §7
