# 转场兼容与性能缓存规范（v6）

> 版本：v6.0
> 状态：规范定稿，待实现
> 优先级：P1（P0 全部跑通后做）
> 对标产品：剪映 / CapCut（转场与关键帧独立分层）+ FCP（instruction 节点化转场）
> 依赖：
> - v6 [image-layer-rendering-spec.md](image-layer-rendering-spec.md)：ImageLayerComposer 与 UnifiedCompositor
> - v6 [keyframe-animation-spec.md](keyframe-animation-spec.md)：KeyframeEvaluator 在转场 overlap 期间继续求值
> - v2 [transition-spec.md](../v2/transition-spec.md)：v2 转场规则集（反向引用，不改主体）
> - [CompositionBuilder.swift](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) `buildVideoTrackUnified`：转场 instruction 构造

---

## 一、覆盖范围

本规范覆盖 V6 P1 的三大件：

1. **转场与关键帧图层共存**：转场期间两 clips 的关键帧继续求值，转场作为独立的 compositor 叠加层
2. **多图层实时预览性能**：CIContext 共享、CVPixelBuffer pool、降级策略
3. **轻量化缓存替换**：废除 StaticImageRenderer 的临时 MP4 缓存，换以 CIImage + 参数轻量缓存
4. **导出链路对齐**：确保实时渲染结果与 AVAssetWriter 导出结果完全一致

---

## 二、转场与关键帧图层共存

### 2.1 规则

转场只作用于**图层交界**——两个相邻 clip 的重叠时间区间。在同一区间内：

- **两 clips 的关键帧继续独立求值**到各自的 timeRange.end（不冻结）
- **转场效果**（crossfade / wipe / push）作为第三层 compositor 指令叠加在之上
- 转场效果不侵入图片图层内部的动画帧

### 2.2 Compositor instruction 切分

当存在转场时，CompositionBuilder 将时间轴切分为 3 种 instruction 区间（参考 V5 `buildVideoTrackUnified` 中已有的转场切分逻辑，V6 扩展之）：

```
时间轴:
 [0] --- clip A --- [A.end]
                          ← transition overlap →
                                            [B.start] --- clip B --- [B.end]

instruction 切分:
 I1: [A.start, transition.start] → clip A 独自渲染
 I2: [transition.start, transition.end] → clip A 最后一帧持续 + clip B 从第一帧开始，各自关键帧继续求值，转场效果叠加
 I3: [transition.end, B.end] → clip B 独自渲染
```

### 2.3 转场 overlap 期间的关键帧行为

在 transition overlap 区间内：

- **clip A**：`KeyframeEvaluator` 在 `t >= 1.0` 时返回最后关键帧值（规则 3 的末态停驻）
- **clip B**：`KeyframeEvaluator` 在 `t <= 0` 时返回第一关键帧值
- **转场效果**：
  - Crossfade：A 的 opacity 从 1 → 0，B 的 opacity 从 0 → 1，两者通过 `CIImage.sourceOverCompositing` 混合
  - 其他转场类型：由 transition 指令独立处理

### 2.4 转场 instruction 构造

在 CompositionBuilder 中，`buildVideoTrackUnified` 已有的 `transitionSegments` 处理逻辑**保留**（V5.1 的转场修复保留 A/B track 的问题修复）。V6 扩展：

- 转场 instruction 新增 `transitionEffect: TransitionEffect` 字段（来自 v2 transition-spec）
- 转场 instruction 内同时包含 clip A 和 clip B 的 `imageLayers` 数组（如果它们是图片图层）
- 转场 instruction 的 `requiredSourceTrackIDs` = 两个 clip 的视频轨道 ID（如果它们是视频）

### 2.5 video → image 过渡

V5 最常见的转场 BUG 场景（视频段 → image_motion 段）。V6 的处理：

- 视频段提供 sourceFrame via sourceTrackID
- 图片段提供 CIImage via ImageLayerComposer
- compositor 在转场 instruction 期间同时取两者，按 transitionEffect 叠加
- 无需任何 MP4 预合成，两段的帧时序完全一致（同 canvas.fps）

---

## 三、多图层实时预览性能

### 3.1 共享 CIContext

所有 ImageLayerComposer 和 UnifiedCompositor 共享同一个 `CIContext` 实例：

```swift
let sharedContext = CIContext(
    mtlDevice: MTLCreateSystemDefaultDevice(),
    options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .highQualityDownsample: false,   // 预览不追求重采样质量
        .outputPremultiplied: true,
        .cacheIntermediates: false       // 不缓存中间结果（内存）
    ]
)
```

### 3.2 CVPixelBufferPool

UnifiedCompositor 在初次 `requiredPixelBufferAttributesForRenderContext` 时创建一个 `CVPixelBufferPool`（属性匹配画布的 `renderSize` 和像素格式 `kCVPixelFormatType_32BGRA`）。所有帧的输出都从这个 pool 分配，减少内存压力。

```swift
let poolAttributes: [String: Any] = [
    kCVPixelBufferPoolMinimumBufferCountKey as String: 4
]
let pixelBufferAttributes: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: Int(renderSize.width),
    kCVPixelBufferHeightKey as String: Int(renderSize.height),
    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
]
```

### 3.3 降级策略

| 负载 | 策略 | 触发条件 |
|---|---|---|
| 3+ 层 image_3d 同屏 | 降为 2 层（舍弃背景层） | fps < 25 持续 3s |
| Metal 设备不可用 | CPU CIContext 退化 | `MTLCreateSystemDefaultDevice() == nil` |
| 超大图片（>50MP） | 下一帧丢弃 | 当前帧求值 > 16ms 且下帧排队 |

### 3.4 预览 vs 导出上下文分离

预览（AVPlayerItem）和导出（AVAssetWriter）使用**不同的 CIContext**：

- 预览：`highQualityDownsample: false`, `cacheIntermediates: false`
- 导出：`highQualityDownsample: true`, `cacheIntermediates: true`, `workingColorSpace: exportColorSpace`

这样可以确保导出帧的质量不因预览帧的资源节约而降级。

---

## 四、轻量化缓存替换

### 4.1 废除的旧缓存

- StaticImageRenderer 的 `/tmp/img_{key}.mp4` 临时文件（常驻 300MB+）
- `AssetCache` 中可能缓存的 AVURLAsset 引用

### 4.2 V6 图片图层缓存模型

使用 `NSCache<NSURL, CIImage>` 缓存 CIImage 实例（注意不是 CGImage——CIImage 是 recipe，内存极小）：

```swift
actor ImageCache {
    private let cache = NSCache<NSURL, CIImage>()
    
    init() {
        cache.countLimit = 20       // 缓 20 张不同图片
        cache.totalCostLimit = 0    // CIImage 成本极小，不需要大小限制
    }
    
    func image(for url: URL) -> CIImage? {
        return cache.object(forKey: url as NSURL)
    }
    
    func setImage(_ image: CIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

// ImageLayerComposer 中使用
func evaluate(spec: ImageLayerSpec, at compositionTime: CMTime, ciContext: CIContext) async -> CIImage? {
    // ...
    let ciImage = await imageCache.image(for: spec.imageURL)
        ?? CIImage(contentsOf: spec.imageURL)
    // cache if not already cached
    if await imageCache.image(for: spec.imageURL) == nil {
        await imageCache.setImage(ciImage, for: spec.imageURL)
    }
    // ...
}
```

### 4.3 关键帧参数缓存

关键帧的 LUT（见 [keyframe-animation-spec.md](keyframe-animation-spec.md) §4）是 256 bytes 编译期常量——无运行时缓存需要。KeyframeEvaluator 的 `evaluate(keyframes:at:)` 是纯计算，无需缓存中间结果。

### 4.4 缓存预算

| 缓存项 | 大小 | 目标 |
|---|---|---|
| ImageCache (CIImage 引用) | < 5MB（20 个 CIImage recipe） | CIImage recipe 仅存储 URL + 变换链，不存储像素 |
| CVPixelBufferPool | ~8MB（4 个 1080P BGRA buffer） | 由 pool min/max 控制 |
| 总峰值 | < 100MB | vs V5 MP4 缓存 300MB+ |

---

## 五、导出链路对齐

### 5.1 实时渲染 = 导出渲染

V6 保证：`CompositionBuilder.build` 构建的 `AVMutableVideoComposition`（用于 AVPlayerItem），与 `VideoExporter` 导出的 `AVAssetReader + AVAssetWriter` 管道，使用**完全相同的 CIImage 出帧路径**。

具体通道：

1. AVPlayerItem 的 `AVVideoComposition.customVideoCompositorClass = UnifiedCompositor.self` → 每帧进 `startRequest`
2. AVAssetReader 的 `AVVideoComposition.customVideoCompositorClass = UnifiedCompositor.self` → 每帧进 `startRequest`

两个路径的差异仅在 CIContext 配置（见 §3.4），不改变图片图层求值逻辑。

### 5.2 复用 V5 的 export-config 体系

V5 的 [render-pipeline-unification-spec.md](../v5/render-pipeline-unification-spec.md) 定义了 AVAssetWriter 改造方案（M3 SDR / M4 HDR）。V6 P2 阶段接入该 spec 时，图片图层的 CIImage 输出路径不需要任何特殊处理——AVAssetWriter 接收 CVPixelBuffer 与视频段落的 CVPixelBuffer 完全相同。

### 5.3 ffprobe 校验

导出文件的 ffprobe 报告须满足：

- `r_frame_rate` = 工程 canvas.fps（30/1, 60/1 等）
- `width x height` = 导出配置的分辨率（或 renderSize）
- 图片段落与视频段落的帧时间和帧数一致，无空帧插入

---

## 六、验证点

| 验证项 | 预期行为 | 方法 |
|---|---|---|
| video→image 转场 | 转场过程无冻结，无闪帧 | 截屏整个 overlap 区间的 5 帧 |
| image→video 转场 | 同上 | 同上 |
| image→image 转场 | 两图片的关键帧继续求值，转场叠加 | crossfade 区间中段截屏可见两个图片的混合 |
| 3 层 image_3d + 转场 | fps ≥ 25，降级阈值不触发 | Metal HUD |
| 缓存命中 | `ls /tmp/img_*.mp4` 无新文件 | 无 MP4 生成 |
| 导出与预览一致 | ffprobe 帧数、帧率、分辨率一致 | ffprobe vs Metal HUD |
| 首帧缓存 | 第二次进入同一工程，首帧 ≤ 300ms | Timer 测量 |

---

## 七、V6 固定交互约束重申

> 见 [V6-initiation.md §7](V6-initiation.md)。实现本 spec 时须遵守：
> - **图片图层渲染走唯一 unified 路径**
> - **转场只作用于图层交界，不入侵图片内部动画帧**
> - **导出公共 API 签名不变**：`VideoExporter.export(timeline:)`
> - **CompositionBuilder.build 向后兼容**
> - 其他约束全文见 V6-initiation.md §7
