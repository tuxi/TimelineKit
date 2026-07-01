# TimelineKit V6 Image 实时渲染播放异常排查文档

> 日期：2026-05-19
> 状态：排查结论 + 修复建议
> 范围：`image / image_motion / image_3d` 从 `StaticImageRenderer` 预合成 MP4 迁移到 `UnifiedCompositor + ImageLayerComposer` 实时渲染后的播放异常

## 一、问题结论

当前现象不是关键帧、插值器或动画幅度问题。

已经通过“绕过 `KeyframeEvaluator`、直接在 `ImageLayerComposer.evaluate` 末尾强制 `translationX = 100 * sin(localTime)`”验证：

- seek 时能看到明显运动
- play 时仍几乎静止
- `UnifiedCompositor.startRequest` 与 `ImageLayerComposer.evaluate` 日志显示播放期间仍在持续计算不同 transform

因此问题收敛为：

**播放链路没有稳定展示每个 `compositionTime` 的实时 compositor 输出，或者 AVFoundation 被当前 instruction 元数据误导，把图片动画当作可复用静态结果。**

## 二、最高概率根因

### 1. `containsTweening` 未标记图片动画

当前 `UnifiedCompositorInstruction` 中：

```swift
var containsTweening: Bool = false
```

构造函数没有根据 `imageLayers`、转场透明度或关键帧动画改成 `true`。

Apple 对 `containsTweening` 的定义是：当同一批 source buffers + 同一个 composition instruction 在不同 `compositionTime` 下可能产生不同输出帧时，应为 `true`。V6 图片动画正是这个模型：图片源不变，instruction 不变，但 `ImageLayerComposer.evaluate(spec:at:)` 会按时间输出不同 transform。

这能解释当前差异：

- seek：单帧请求明确指定 `compositionTime`，所以能看到正确动画状态
- play：播放器实时路径可能基于 `containsTweening=false` 进行帧复用或降低重合成频率，导致视觉上近似静帧

建议修复：

```swift
let hasImageLayers = !imageLayers.isEmpty
let hasTransitionTween = fgOpacityStart != fgOpacityEnd
let hasAnimatedImage = imageLayers.contains { !($0.keyframes?.isEmpty ?? true) }

self.containsTweening = hasTransitionTween || hasAnimatedImage || hasImageLayers
```

保守起见，V6 可以先在 `imageLayers` 非空时一律设为 `true`，因为即使静态图片也必须防止播放路径把“无源图片 instruction”优化成不刷新。

### 2. `enablePostProcessing` 没有把 `imageLayers` 纳入

当前代码只按转场和调色计算：

```swift
let isTransition = backgroundTrackID != nil
let hasColor = !foregroundAdjustment.isIdentity || !backgroundAdjustment.isIdentity
self.enablePostProcessing = isTransition || hasColor
```

但图片图层本身已经是 compositor 生成的后处理输出，不是原始 source frame passthrough。建议改为：

```swift
self.enablePostProcessing = isTransition || hasColor || !imageLayers.isEmpty
```

### 3. 图片 instruction 仍声明了 `requiredSourceTrackIDs`

V6 规范要求图片段落不再依赖 AVAssetTrack，图片 instruction 的 `requiredSourceTrackIDs` 应为空。当前构造函数无条件写入：

```swift
var ids: [NSValue] = [NSNumber(value: foregroundTrackID)]
if let bgID = backgroundTrackID { ids.append(NSNumber(value: bgID)) }
self.requiredSourceTrackIDs = ids
```

而 `CompositionBuilder` 对图片段只生成 `ImageLayerSpec`，并没有向对应 composition track 插入视频样本。这会形成“instruction 声明需要 trackA，但该时间段 trackA 没有 source sample”的矛盾。

建议分支：

```swift
if !imageLayers.isEmpty && backgroundTrackID == nil {
    self.requiredSourceTrackIDs = []
} else {
    var ids: [NSValue] = [NSNumber(value: foregroundTrackID)]
    if let bgID = backgroundTrackID { ids.append(NSNumber(value: bgID)) }
    self.requiredSourceTrackIDs = ids
}
```

注意：视频 + 前景/背景图片 overlay 共存的 instruction 仍需要 source track；纯图片主轨 instruction 才应为空。

## 三、逐项分析

### 已排除

| 怀疑点 | 结论 | 依据 |
|---|---|---|
| Keyframe 生成错误 | 排除 | `resolvedKeyframes scale 1.0 -> 2.75` 已打出 |
| `KeyframeEvaluator` 插值错误 | 排除 | 已绕过 evaluator 仍复现 |
| 动画强度太弱 | 排除 | 强制 100px sin 位移 + 2.75 scale 仍 play 静止 |
| `ImageLayerComposer` 没执行 | 排除 | seek 可见，play 日志也显示持续计算 |
| passthrough 覆盖 imageLayers | 基本排除但需加断言 | 当前 fast passthrough 条件要求 `fgImageLayers == nil && bgImageLayers == nil` |

### 仍需验证

| 验证项 | 预期 | 方法 |
|---|---|---|
| `currentItem.videoComposition` 是否为 V6 composition | 非 nil，且 `customVideoCompositorClass == UnifiedCompositor.self` | 在 `CompositionCoordinator.rebuild` 与点击播放后各打一条 |
| 纯图片 instruction 的 `requiredSourceTrackIDs` | 应为 `[]` | 构建完成遍历 `videoComposition.instructions` |
| 图片 instruction 的 `containsTweening` | 应为 `true` | 同上 |
| 图片 instruction 的 `enablePostProcessing` | 应为 `true` | 同上 |
| play 与 seek 是否同一 item | 应共用 `CompositionCoordinator.player.currentItem` | 打印 player/item ObjectIdentifier |
| source 是否遮挡 image layer | 临时 `sourceImage = nil` 后，play 仍应有动画 | 只作为验证，不作为最终方案 |

## 四、竞品调研结论

主流竞品的共性不是“把图片先生成视频再播放”，而是把图片作为一等 clip/layer 放进实时 compositor：

- 剪映 / CapCut：图片、视频、文字都可作为 timeline clip，Transform 参数通过关键帧驱动，position / scale / rotation / opacity 等会在播放时插值。
- CapCut 官方 keyframe 页面明确将 position、scale、rotation、opacity 作为 keyframe 可控参数，并由编辑器自动插值。
- Final Cut Pro：Ken Burns 与 Transform animation 都是 still image clip 的实时运动能力，播放时由时间线上参数驱动。
- LumaFusion：图片/视频层共用 Size、Position、Rotation、Opacity 等控制组，并支持 keyframe animation。

对 TimelineKit V6 的启示：

1. 图片不应被降级成“无 source、但又声明 source track 的特殊视频段”。
2. 图片动画必须被 AVFoundation 明确标记为 time-varying instruction。
3. 播放、seek、全屏预览、导出要共享同一个 compositor 输出语义；差异只能在输出尺寸和字幕交互层，不应在图片动画求值链路分叉。

参考：

- Apple `containsTweening` 文档：https://developer.apple.com/documentation/avfoundation/avvideocompositioninstructionprotocol/containstweening
- Apple `enablePostProcessing` 文档：https://developer.apple.com/documentation/avfoundation/avmutablevideocompositioninstruction/enablepostprocessing
- CapCut keyframe animation：https://www.capcut.com/tools/keyframe-animation
- Apple Final Cut Pro effects / Ken Burns：https://support.apple.com/en-lamr/guide/final-cut-pro/verfc8a5050/12.0/mac/15.6
- LumaFusion Reference Guide：https://www.luma-touch.com/wp-content/uploads/2020/07/LumaFusion-Reference-Guide.pdf

## 五、建议修复顺序

### Step 1：修正 instruction 元数据

在 `UnifiedCompositorInstruction.init` 中：

- `imageLayers` 非空时，`enablePostProcessing = true`
- `imageLayers` 非空时，`containsTweening = true`
- 纯图片 instruction 的 `requiredSourceTrackIDs = []`
- 视频 + overlay 图片共存时保留 source track IDs

这是最小、最符合当前症状的修复。

### Step 2：补充 debug 断言

在 `CompositionBuilder` 构造 unified instructions 后加 DEBUG 检查：

```swift
for instr in instructions {
    if !instr.imageLayers.isEmpty {
        assert(instr.containsTweening)
        assert(instr.enablePostProcessing)
    }
}
```

纯图片主轨还应断言：

```swift
assert(instr.requiredSourceTrackIDs?.isEmpty == true)
```

### Step 3：恢复 `ImageLayerComposer.evaluate` 正常路径

当前文件里存在临时验证代码：

```swift
let test = ciImage
    .transformed(by: baseTransform)
    .transformed(by: CGAffineTransform(translationX: 100 * sin(localTime), y: 0))
    .cropped(to: CGRect(origin: .zero, size: spec.renderSize))
return test
```

修完播放链路后必须删除这段，恢复 `KeyframeEvaluator.evaluate(...)` 正常输出。

### Step 4：做播放路径回归矩阵

| 场景 | seek | play | 全屏预览 | 导出 |
|---|---|---|---|---|
| 单张静态 image | 画面稳定 | 画面稳定 | 画面稳定 | 画面稳定 |
| image_motion zoom | 有运动 | 有运动 | 有运动 | 有运动 |
| image_3d pan/zoom | 有运动 | 有运动 | 有运动 | 有运动 |
| video -> image 转场 | 双段继续输出 | 双段继续输出 | 双段继续输出 | 双段继续输出 |
| image + subtitle | 图片动，字幕正确叠加 | 同左 | 同左 | 同左 |
| overlay image behind video | overlay 在底层运动 | 同左 | 同左 | 同左 |

## 六、最终判断

当前最像是 AVFoundation instruction 元数据错误，而不是 renderer 算法错误。

最小闭环修复是：

1. 把 image layer instruction 标记为 `containsTweening=true`
2. 把 image layer instruction 标记为 `enablePostProcessing=true`
3. 对纯图片 instruction 清空 `requiredSourceTrackIDs`
4. 删除临时强制 sin 位移，恢复真实 keyframe

这四点完成后，再验证 `sourceImage = nil`、`playerItem.videoComposition`、play/seek item identity 等路径问题。如果仍复现，再进入 AVPlayerLayer 展示层或 CVPixelBufferPool 生命周期排查。
