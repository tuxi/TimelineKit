# AI Timeline 动画参数映射规范（v6）

> 版本：v6.0
> 状态：规范定稿，待实现
> 优先级：P0-C（架构打底第三阶段，依赖 P0-A image-layer-rendering + P0-B keyframe-animation）
> 对标产品：剪映 / CapCut（草稿 JSON 全字段消费 + 3D 照片分层）
> 依赖：
> - v6 [image-layer-rendering-spec.md](image-layer-rendering-spec.md)：ImageLayerSpec 与 ImageLayerComposer
> - v6 [keyframe-animation-spec.md](keyframe-animation-spec.md)：KeyframeSet、KeyframeEvaluator、AnimationMacro
> - [ServerTimelineSchema.swift](../../Sources/TimelineKit/Conversion/ServerTimelineSchema.swift)：`SImageAnimation` / `SDepthModel` / `SCamera`（被部分丢弃的 server schema）
> - [TimelineImporter.swift:93-150](../../Sources/TimelineKit/Conversion/TimelineImporter.swift)（要重写的解码逻辑）

---

## 一、覆盖范围

本规范覆盖 V6 P0-C「AI Timeline 参数 → 前端关键帧」的端到端映射：

1. 重写 `TimelineImporter` 的 image_motion / image_3d 解码
2. `SImageAnimation` 完整字段 → `KeyframeSet`
3. `SCamera` → 多图层 `[ImageLayerSpec]`
4. `SDepthModel` → 2.5D parallax 多层展开规则
5. 相册图 + AI 图统一数据层规则
6. 旧草稿（无新字段）的兼容展开

---

## 二、现状 — V5 丢弃的字段

### 2.1 ServerTimelineSchema 中已存在但未消费的字段

[`ServerTimelineSchema.swift`](../../Sources/TimelineKit/Conversion/ServerTimelineSchema.swift) 行 146-190：

```swift
// === V5 已解码 ===
struct SImageAnimation: Codable {
    let type: String          // "zoom_in" / "pan_left" ... → ImageMotionPreset
    let duration: Double?     // → 仅作 timing 参考
    let easing: String?       // → 丢弃
}
struct SCamera: Codable {
    let move: String?         // "forward" / "backward" / "left" / ... → DepthEffect.moveDirection
    let intensity: Double?    // 0-1 → DepthEffect.intensity（透传但下游不用）
    let duration: Double?     // → 仅作 timing 参考
    let easing: String?       // → 丢弃
}

// === V5 完全丢弃 ===
// SImageAnimation 中有 scaleFrom / scaleTo / translateXFrom / translateYFrom / translateYTo / opacityTo 等字段
// SDepthModel 中有 centerX / centerY / innerRadius / outerRadius / nearValue / farValue / falloff 等字段
```

### 2.2 V5 的映射路径

```
Server JSON → TimelineImporter 行 93-150
  → SImageAnimation.type → ImageMotionPreset enum (zoom_in / zoom_out / pan_left / pan_right / pan_up / pan_down)
  → SCamera.move + intensity → DepthEffect (moveDirection + intensity + duration)
  → SDepthModel → 丢弃
  → ImageContent.motionPreset / depthEffect → 存到 SegmentContent
  → StaticImageRenderer.render() → 在渲染时消费 motionPreset / depthEffect 做采样动画
```

**损耗**：server 下发的连续动画参数（scaleFrom/To 等）被降级为有限预设，造成 AI 工程与自由相册导入工程在动画细腻度上不一致。

---

## 三、V6 端到端映射规则

### 3.1 总流程图

```
Server JSON
  │
  ├── SImageAnimation (type, duration, easing, scaleFrom, scaleTo, translate*, opacityTo)
  │     │
  │     ├── type → 忽略（V6 不再用 motionPreset 枚举驱动渲染）
  │     ├── easing → 映射到 EasingCurve（见表 1）
  │     ├── duration → 关键帧时间跨度（标准化为 timeFraction 0~1）
  │     ├── scaleFrom / scaleTo → KeyframeSet.scale [t=0: scaleFrom, t=1: scaleTo]
  │     ├── translateXFrom / translateXTo / translateYFrom / translateYTo → KeyframeSet.position
  │     └── opacityTo (如有) → KeyframeSet.opacity
  │
  ├── SCamera (move, intensity, duration, easing)
  │     │
  │     ├── move + intensity → 转换为 position / scale / anchor 关键帧（见表 2）
  │     └── easing → 映射到 EasingCurve
  │
  └── SDepthModel (centerX, centerY, innerRadius, outerRadius, nearValue, farValue, falloff)
        │
        └── 分层参数 → 3 层 ImageLayerSpec（前景 / 主层 / 背景各自的 scale + position 关键帧）
```

### 3.2 表 1：SImageAnimation → KeyframeSet 映射表

| Server 字段 | 存在条件 | V6 映射目标 | 默认值 (缺失时) |
|---|---|---|---|
| `type` | 必有 | **不再映射到 motionPreset**；仅供兼容日志 | — |
| `duration` | 可选 | `timeFraction = 1.0` 对应 duration 秒 | segment.targetRange.duration |
| `easing` | 可选 | `EasingCurve` 枚举 | `.easeOut` (与 V5 一致) |
| `scaleFrom` | 可选 | `scale` keyframe at t=0 | `CGVector(dx: 1.0, dy: 1.0)` |
| `scaleTo` | 可选 | `scale` keyframe at t=1 | `CGVector(dx: 1.0, dy: 1.0)` |
| `translateXFrom` | 可选 | `position.x` keyframe at t=0 | `0` |
| `translateXTo` | 可选 | `position.x` keyframe at t=1 | `0` |
| `translateYFrom` | 可选 | `position.y` keyframe at t=0 | `0` |
| `translateYTo` | 可选 | `position.y` keyframe at t=1 | `0` |
| `opacityTo` | 可选 | `opacity` keyframe at t=1 | `1.0` |
| `opacityFrom` (如有) | 可选 | `opacity` keyframe at t=0 | `1.0` |

**Easing 字符串映射表**：

| Server `easing` 值 | V6 EasingCurve |
|---|---|
| `"linear"` | `.linear` |
| `"easeIn"` / `"ease_in"` | `.easeIn` |
| `"easeOut"` / `"ease_out"` | `.easeOut` |
| `"easeInOut"` / `"ease_in_out"` | `.ease` |
| 其他 / 缺失 | `.easeOut` |

### 3.3 表 2：SCamera → KeyframeSet 映射表

SCamera 在 V5 中被映射到 `DepthEffect`（单层 parallax），在 V6 中展开为**单层关键帧**（简单模式）或 **3 层 ImageLayerSpec**（`SDepthModel` 存在时）。

**简单模式（无 SDepthModel）**：

| move | V6 position 关键帧 |
|---|---|
| `"forward"` | scale: (1,1)→(1.12,1.12), position 微调中心 |
| `"backward"` | scale: (1.12,1.12)→(1,1) |
| `"left"` | position.x: 0→-36px, scale 微增 1.04 |
| `"right"` | position.x: 0→+36px, scale 微增 1.04 |
| `"up"` | position.y: 0→-36px, scale 微增 1.04 |
| `"down"` | position.y: 0→+36px, scale 微增 1.04 |

位移量 = `canvas.width * 0.05 * intensity`（最大覆盖 54px @ 1080P）。

---

## 四、2.5D Parallax 分层展开 (SDepthModel)

### 4.1 何时触发分层

当 `SDepthModel` 存在（`image_3d` 段落且 server 下发了深度模型）时，走 **3 层 ImageLayerSpec**路径：

- **主层**（zPosition=0）：原图，保留原始 scale/position 关键帧（来自 SImageAnimation 或默认），opacity=1
- **前景层**（zPosition=1）：原图 + 遮罩（中心区域），更大的 scale 关键帧，opacity 从 0.5→1
- **背景层**（zPosition=-1）：原图 + 遮罩（外围区域），更小的 scale 关键帧，opacity 从 0→0.3

### 4.2 depthModel 参数含义与 V6 映射

| Server 字段 | 物理含义 | V6 映射 |
|---|---|---|
| `centerX / centerY` (0~1) | 深度焦点在图片中的归一化位置 | 前景层锚点 = centerX/Y；背景层锚点 = (0.5, 0.5) |
| `innerRadius` (0~1) | 焦点区域半径（清晰无位移） | 前景层裁剪区域半径 |
| `outerRadius` (0~1) | 过渡区域外半径 | 前景→背景过渡区间 |
| `nearValue` (0~1) | 最近景深度 | 前景层 scale 振幅最大值 |
| `farValue` (0~1) | 最远景深度 | 背景层 scale 振幅最大值 |
| `falloff` (0~1) | 深度过渡陡峭度 | 前景层 opacity 衰减速率 |

### 4.3 展开算法

```
输入: depthModel, camera (move + intensity + duration), segmentDuration, imageURL, renderSize

1. 计算振幅：
   frontAmplitude = nearValue * intensity * 0.15   (max scale 1.15)
   backAmplitude  = farValue  * intensity * 0.10   (max scale 0.90)
   
2. 生成主层 ImageLayerSpec：
   keyframes = SImageAnimation → KeyframeSet (或默认 identity)
   zPosition = 0, opacity = 1.0

3. 生成前景层 ImageLayerSpec：
   keyframes.scale = [(0, 1+frontAmplitude*0.3, easeOut), (1, 1+frontAmplitude, easeOut)]
   keyframes.position = camera.move → direction displacement (amplified 1.5x vs 主层)
   keyframes.opacity = [(0, 0.5), (0.3, 1.0, easeOut)]
   keyframes.anchor = [(0, depthModel.centerX/Y)]
   zPosition = 1

4. 生成背景层 ImageLayerSpec：
   keyframes.scale = [(0, 1-backAmplitude*0.3, easeOut), (1, 1-backAmplitude, easeOut)]
   keyframes.position = camera.move → direction displacement (inverted direction: background 向反方向运动)
   keyframes.opacity = [(0, 0.0), (0.5, falloff*0.3, easeOut)]
   zPosition = -1

5. 输出: [backgroundSpec, mainSpec, foregroundSpec]
```

### 4.4 性能考虑

3 层 image_3d 全景深模式需要在每帧加载 3 次 `CIImage(contentsOf: url)`——但 CIImage lazy 共享同一文件句柄，不会产生 3 倍磁盘 I/O 或内存开销。

iPhone 13 baseline 30fps 目标（见 [competitive-benchmarks-v6.md](competitive-benchmarks-v6.md) §5.2），若真机测试低于 25fps，启用降级路径：前景+主层合并为 2 层（舍弃背景层）。

---

## 五、相册图 + AI 图统一数据层规则

### 5.1 两种入口的差异抹平

| 入口 | V5 行为 | V6 行为 |
|---|---|---|
| **相册导入** | ImageContent.motionPreset=nil, depthEffect=nil → StaticImageRenderer 以 identity transform 循环编码 → MP4 | ImageContent.keyframes=nil → 内部等价于 keyframes=[], KeyframeEvaluator 返回 identity →
ImageLayerComposer 仅应用 baseScale |
| **AI 下发 image_motion** | ImageContent.motionPreset=zoom_in, keyframes=nil → StaticImageRenderer 按 motionPreset 采样 motion → MP4 | ImageContent.keyframes 由 TimelineImporter 解码 `SImageAnimation` 填充，包含 scale 等关键帧 |
| **AI 下发 image_3d** | ImageContent.motionPreset + depthEffect → StaticImageRenderer 按 SCamera 采样 → MP4 | ImageContent.keyframes 由 TimelineImporter 解码完整 SCamera → 可能带 3 层 ImageLayerSpec |

**统一点**：三种入口生成的 `EditorSegment` 都在 `SegmentContent.ImageContent.keyframes` 中携带完整的 `KeyframeSet`（或 nil = identity）。渲染链路仅根据 keyframes 和 ImageLayerSpec 执行——不知道也不关心素材来自哪个入口。

### 5.2 相机权限 / 存储差异不在此范围

相册导入的权限流与 AI 图片下发流 **不在本规范范围内**。本规范仅覆盖「图片已经作为 EditorSegment.asset.url 存在后的渲染链路」。

---

## 六、TimelineImporter 改造范围

### 6.1 重写行 93-150

**入参不变**：`SImageAnimation?`、`SDepthModel?`、`SCamera?`（从 server JSON 解码）。

**出参变更**：
- **不再**输出 `ImageMotionPreset` 枚举（V5 路径）
- **改为**输出 `KeyframeSet`（V6 路径）
- ImageContent 的两个字段：
  - `motionPreset: ImageMotionPreset?` — 保留（UI 入口仍用，但不进入渲染链路）
  - `keyframes: KeyframeSet?` — **新增**（V6 唯一渲染数据源）

### 6.2 向后兼容：旧草稿迁移

旧草稿从 `DraftStore` 加载时，若 `ImageContent.keyframes == nil` 但 `motionPreset != nil || depthEffect != nil`：

```swift
// 在 EditorTimeline 或 DraftStore 的加载后补丁中
if img.keyframes == nil {
    img.keyframes = AnimationMacro.expand(
        motionPreset: img.motionPreset,
        depthEffect: img.depthEffect,
        duration: seg.targetRange.duration
    )
}
```

此补丁只执行一次——第二次保存草稿时 `keyframes` 已非 nil。

---

## 七、验证点

| 验证项 | 预期行为 | 方法 |
|---|---|---|
| SImageAnimation.scaleFrom/To 被消费 | AI 工程导入后 ImageContent.keyframes.scale 非空，截图显示缩放动画 | breakpoint on TimelineImporter line 104 → 验证 keyframes 填充 |
| SDepthModel 全部字段被消费 | AI image_3d 工程导入后 3 层 ImageLayerSpec 被创建 | UnifiedCompositorInstruction.imageLayers.count == 3 |
| SCamera.move="forward" + intensity=0.5 | 主层 scale 由 1 到 1.06，前景层 scale 更大 | 截屏与 StaticImageRenderer V5 forward/0.5 对比 |
| 旧草稿 motionPreset=zoom_in + keyframes=nil | 加载后 AnimationMacro 填充 keyframes，与 V5 动画一致 | 截屏 diff ≤ 2px |
| 相册导入图 + AI image_motion 同放 timeline | 两者行为一致；转场衔接正常 | 肉眼 + 逐帧截屏 |
| Server easing="linear" | KeyframeSet 使用 EasingCurve.linear | 动画无缓动效果 |

---

## 八、V6 固定交互约束重申

> 见 [V6-initiation.md §7](V6-initiation.md)。实现本 spec 时须遵守：
> - **预设作为语法糖、运行时一律展开为关键帧**
> - **相册导入图片 / AI 下发图片行为差异在数据源头抹平**
> - **2.5D parallax 用分层 2D 图层实现**
> - 其他约束全文见 V6-initiation.md §7
