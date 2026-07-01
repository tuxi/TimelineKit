# TimelineKit V7 立项书

> 版本：v7.0
> 状态：立项定稿，待各 spec 拆任务执行
> 对标产品：剪映 iOS 14.0+（移动端主对标）+ CapCut Desktop 4.0+ + Final Cut Pro 11 + Adobe Premiere 2024 + VN 2.x
> 依赖：V6 P0/P1 全部落地（ImageLayerComposer / KeyframeEvaluator / UnifiedCompositor 扩展 / layer-rendering-rules）

---

## 一、立项背景

### 1.1 V6 完成了什么

V6 解决了图片渲染的架构债：废除 StaticImageRenderer MP4 预合成路径，把图片 clip 升级为「CIImage 原生图层 + 关键帧矩阵变换」，并通过 `ImageLayerComposer` / `KeyframeEvaluator` / `AnimationMacro` 三件基建实现了图片动画与视频同权渲染。

V6 P4（VideoFrameProvider 性能化）同时完成了 `PreviewFrameProvider` / `ExportFrameProvider` 分离，以及图片 3D 假 3D 运镜预设雏形（`image_3d`）。

### 1.2 V6 没有解决的问题：转场

V6 的 transition-compat-spec（P1）虽然规定了「转场与关键帧图层共存」的架构设计，但实际代码层面，转场实现仍停留在：

**问题 1：黑屏/闪跳根因**

`LayerResolver.resolve`（`Sources/TimelineKit/Runtime/LayerResolver.swift:282-293`）在 transition zone 内仅当双侧都是 image 时构造 `TransitionInfo`：

```swift
// 当前代码（V6 现状）
if let fgSpec = imageLayerMap[seg.id],
   let bgSpec = imageLayerMap[nextSeg.id] {
    resolvedTransition = TransitionInfo(...)
}
// video → image / image → video / video → video 三种组合：
// fgSpec 或 bgSpec 为 nil → 静默跳过 → transition zone 内 activeLayers 为空 → 黑屏
```

**问题 2：转场类型只有 dissolve**

`TimelineRenderer.renderFrame`（`Sources/TimelineKit/Runtime/TimelineRenderer.swift:157`）：

```swift
blended = fg.applyingFilter("CIDissolveTransition", parameters: [
    kCIInputTargetImageKey: bg,
    kCIInputTimeKey: easedProgress
])
// EditorTransition.type（fade / slideLeft / zoom / wipe 等）完全未消费
```

`EditorTransition.TransitionType` 定义了 8 个 case，但渲染层只实现了 1 个，其余 7 个与 dissolve 完全一致——用户选不同转场但看到的效果相同。

**问题 3：无 preset 注册体系**

没有 `TransitionPresetRegistry`，没有 `TransitionComposer`，转场逻辑散落在 `TimelineRenderer` 里的两行硬编码。扩展任何新转场都需要在核心渲染器里直接改代码，无封装边界。

**问题 4：服务端转场无安全 fallback**

服务端下发客户端不支持的 `type`（如 `"glitch"`）时，`TimelineImporter` 会构造出 `TransitionType(rawValue: "glitch") = nil`，走 Optional 链条静默失败 → 转场被丢弃 → 黑屏。没有 fallback 到 `crossFade` 的机制。

### 1.3 V7 的目标：不再零散修补，建立转场体系

V7 不是「多加几个转场」，而是**建立 DreamAI Timeline 的视觉模板基座**：

```
ImageAnimationPresetRegistry    （V6 AnimationMacro 已有雏形，V7 完整化）
Image3DPresetRegistry           （V6 image_3d 雏形，V7 完整化）
TransitionPresetRegistry        （V7 新建，核心）
TimelineTemplateConverter       （V7 新建，服务端→客户端模板转换）
```

以后服务端生成 timeline 时，应尽量引用客户端已验证的 `presetID`，而不是随意传自由参数。

---

## 二、范围围栏

### 2.1 ✅ V7 必做（P0 + P1）

| 优先级 | 序号 | 项目 | 落地 spec |
|---|---|---|---|
| **P0-A** | 1 | 修复 `LayerResolver` 黑屏根因：`TransitionInfo` 扩展为支持 video 侧；image→video / video→image / video→video 转场均能构造出有效 `TransitionInfo` | [transition-system-spec.md](transition-system-spec.md) §2 |
| **P0-B** | 2 | `TransitionPresetRegistry`：可注册、可查询的转场预设目录；首批 8 个 preset 实现 | [transition-system-spec.md](transition-system-spec.md) §3 |
| **P0-C** | 3 | `TransitionComposer`：从 `TimelineRenderer` 提取转场混合逻辑，按 presetID dispatch 到对应实现；Preview 和 Export 共用同一 `blend` 入口 | [transition-system-spec.md](transition-system-spec.md) §4 |
| **P1-A** | 4 | `TimelineTemplateConverter`：服务端 transition 字段 → 客户端 `TransitionSpec`；不支持的类型 fallback 到 `crossFade` + 打日志 + 不黑屏 | [visual-template-registry-spec.md](visual-template-registry-spec.md) §4 |
| **P1-B** | 5 | 转场 UI：底部工具栏「转场」入口 + 面板 Tab / 预览缩略动画 / 时长调整 / 删除 | [transition-ui-spec.md](transition-ui-spec.md) |
| **P1-C** | 6 | 视觉模板注册表基座：`ImageAnimationPresetRegistry` / `Image3DPresetRegistry` / `TransitionPresetRegistry` 统一接口规范 | [visual-template-registry-spec.md](visual-template-registry-spec.md) §2-§3 |

### 2.2 🟡 V7 沿用既有 spec（不重写，仅引用）

| 项目 | 复用 spec |
|---|---|
| 转场时长约束、overlap 模型、数据结构基础 | [docs/v2/transition-spec.md](../v2/transition-spec.md) |
| 关键帧在转场 overlap 期间的求值规则（末态停驻） | [docs/v6/transition-compat-spec.md](../v6/transition-compat-spec.md) §2.3 |
| Preview/Export 同源架构 | [docs/v6/transition-compat-spec.md](../v6/transition-compat-spec.md) §5 |
| 图片图层渲染（ImageLayerComposer）| [docs/v6/image-layer-rendering-spec.md](../v6/image-layer-rendering-spec.md) |
| 关键帧求值（KeyframeEvaluator）| [docs/v6/keyframe-animation-spec.md](../v6/keyframe-animation-spec.md) |

### 2.3 🕓 V7 留 roadmap（P0/P1 上线后单独立 spec）

| 项目 | 备注 |
|---|---|
| 转场 P2 扩展（slideUp/Down / zoomOut / zoomBlurIn/Out / motionBlurSlide） | 首批 8 个稳定后追加 |
| 遮罩类转场（wipeLeft / wipeRight / circleOpen / circleClose） | 需要 Metal shader；V7 P2 |
| 故障/光效类转场（glitch / lightLeak） | Metal particle shader；V7 P3+ |
| AI 转场（基于 AI 生成的过渡帧） | 需要服务端推理能力；V8+ |
| 「应用到全部转场」批量操作 UI | V7 P1 UI 稳定后追加 |
| 转场预览缩略动画（动态 Thumbnail）| V7 P1 UI 追加；P1-B 先做静态 icon |
| 转场导出参数配置（分辨率 / fps 细化） | 沿用 V5/V6 export-config-panel-spec |

### 2.4 ❌ V7 暂不做（明确延后）

| 项目 | 理由 |
|---|---|
| 物理删除 V6 transition 临时代码 | V7 完成后评估；保留作历史参考 |
| 非主轨转场（overlay 轨道转场） | 与剪映一致，仅主轨支持转场 |
| 文字/字幕轨道转场 | 同上 |
| 自定义 duration 超过 3.0s | 沿用 v2-spec §2.1 约束 |
| Dolby Vision / HDR10+ 转场渲染 | 同 V5/V6 ❌ 理由 |

---

## 三、与 v1-v6 边界

### 3.1 不改动 v1-v5 任何已锁文件

V7 仅以下**精确修改 + 新增**：

**修改既有文件（精确到 file:line）**：

- `Sources/TimelineKit/Runtime/LayerResolver.swift:282-293`（`resolve` 内 transition zone 处理分支）：扩展 `TransitionInfo` 初始化，支持 `outgoingVideo/incomingVideo: VideoLayerSpec?` 字段；image→video / video→image / video→video 组合均正确构造；修改后彻底消除黑屏
- `Sources/TimelineKit/Runtime/TimelineRenderer.swift:144-168`（`renderFrame` 的 transition blend 块）：删除硬编码的 `CIDissolveTransition` 调用，替换为 `TransitionComposer.blend(transitionInfo, progress: easedProgress, context: ciContext)`；TransitionComposer 内部按 `transitionInfo.presetID` dispatch
- `Sources/TimelineKit/Models/EditorTransition.swift:32-41`（`TransitionType` 枚举）：新增 `crossFade / fadeThroughBlack / pushLeft / pushRight / blurFade / zoomIn` case；补齐现有 case 的 rawValue 对齐（保持向后兼容）
- `Sources/TimelineKit/Conversion/TimelineImporter.swift`（transition 解码分支）：新增 fallback 逻辑；不认识的 `type` 字符串 → `crossFade`；打 `print("[Transition] Unknown type '\(raw)', fallback to crossFade")` 日志

**新增文件（3）**：

- `Sources/TimelineKit/Rendering/TransitionPresetRegistry.swift` — 转场预设注册表 + 首批 8 个预设实现
- `Sources/TimelineKit/Rendering/TransitionComposer.swift` — 转场混合逻辑（从 TimelineRenderer 解耦）
- `Sources/TimelineKit/Conversion/TimelineTemplateConverter.swift` — 服务端转场字段 → `TransitionSpec` 映射器

**完全不动文件**：

- v1-v6 全部 spec 文档
- `ImageLayerComposer.swift`（V6 P0 已落地）
- `KeyframeEvaluator.swift`（V6 P0 已落地）
- `EasingCurve.swift` / `AnimationMacro.swift`（V6 P0 已落地）
- `VideoLayerComposer.swift`（V6 P4 已落地）
- `CompositionBuilder.swift`（V6 unified 路径完整，V7 不需要改）
- `UnifiedCompositor.swift`（V6 已扩展 imageLayers，V7 不需要改）
- `ColorAdjustmentCompositor.swift`

### 3.2 数据模型变更（最小加法，向下完全兼容）

**`EditorTransition` 新增字段（Codable `decodeIfPresent` 容错）**：

```swift
// V7 扩展
public struct EditorTransition: Identifiable, Sendable, Hashable, Codable {
    // ... 原有字段不变 ...

    /// Resolved preset identifier. Nil = fallback to TransitionType raw mapping.
    /// 新增：服务端可直接传 presetID，优先于 type 字段
    public var presetID: String?

    /// Direction hint for directional transitions (slide / push / wipe).
    /// 新增：旧草稿 nil → preset 默认方向
    public var direction: Direction?

    /// Effect intensity 0.0-1.0. 新增：旧草稿 nil → preset 默认 intensity (1.0)
    public var intensity: Float?

    public enum Direction: String, Sendable, Hashable, Codable {
        case left, right, up, down
    }
}
```

- 旧草稿加载：`presetID / direction / intensity` 均为 nil，按 `type` 字段映射到 preset（V7 TransitionPresetRegistry 内有 TransitionType → presetID 的兼容映射表）
- 无任何字段删除、无重命名、无类型变更
- 草稿 schema 主路径不变（`DraftCodable.swift` 不动）

**`TransitionInfo` 新增字段（仅用于渲染，非持久化）**：

```swift
// V7 扩展（不存草稿，仅 LayerResolver → TimelineRenderer 传递）
public struct TransitionInfo: Sendable {
    public let outgoing: ImageLayerSpec?       // nil if outgoing is video
    public let incoming: ImageLayerSpec?       // nil if incoming is video
    public let outgoingVideo: VideoLayerSpec?  // nil if outgoing is image ← V7 新增
    public let incomingVideo: VideoLayerSpec?  // nil if incoming is image ← V7 新增
    public let rawProgress: Float
    public let easing: EditorTransition.Easing
    public let presetID: String                // V7 新增；fallback = "crossFade"
}
```

### 3.3 兼容承诺

- v1 / v2 / v3 / v4 / v5 / v6 旧草稿 100% 加载；旧 `EditorTransition` 无 `presetID` 字段 → `decodeIfPresent` 返回 nil → 按 `type.rawValue` 查 TransitionPresetRegistry 兼容映射表，找到对应 presetID
- 旧草稿的 `EditorTransition.type == .fade` → 映射到 `presetID = "crossFade"`（dissolve 语义一致）
- 旧草稿的 `.dissolve` → 映射到 `presetID = "crossFade"`
- 旧草稿的 `.slideLeft` → 映射到 `presetID = "slideLeft"` + `direction = .left`
- 旧草稿的其他 case（`.slideRight / .slideUp / .slideDown / .zoom / .wipe`）→ 如果 V7 未实现对应预设，fallback 到 `crossFade`，打日志

---

## 四、里程碑排期

> 调整依据（2026-05-20）：先把地基稳了再堆预设。M1 只做黑屏修复，M2 建立唯一出口，M3 才接第一批稳定预设。

| 里程碑 | 工作内容 | 关键交付 |
|---|---|---|
| **M1：修黑屏** | `LayerResolver.swift:282-293` 修改；`TransitionInfo` 扩展 `outgoingVideo / incomingVideo` 字段；**只用 crossFade** 验证四种内容组合 | 图片↔视频任意组合转场区间 0 黑帧；overlay / text 在 transition zone 内持续正常渲染；crossFade 稳定是唯一验收门槛 |
| **M2：TransitionComposer 唯一出口** | 新增 `TransitionComposer.swift`；`TimelineRenderer.swift:144-168` 删除硬编码 `CIDissolveTransition`，改为 `TransitionComposer.render(outgoing:incoming:preset:progress:context:)`；`TransitionPresetRegistry.swift` 最小骨架（仅注册 crossFade）| **TimelineRenderer 内部不再有任何转场逻辑**；所有转场效果统一由 TransitionComposer dispatch；crossFade 行为与 M1 完全一致 |
| **M3：首批 4 个稳定预设** | 在 TransitionPresetRegistry 追加 3 个：`fadeThroughBlack / slideLeft / pushLeft` | 每个预设通过 4 类内容组合（img→img / img→vid / vid→img / vid→vid）验证；720p 导出帧耗时与 V6 crossFade 基准 ±10% |
| **M4：转场 UI** | 底部切割点菱形图标；`TransitionPickerSheet`（基础 / 移动 Tab）；时长滑块；删除功能 | 用户可在 Timeline 两片段间添加 / 更换 / 删除转场；4 个首批预设均可在面板中选到 |
| **M5：服务端映射** | `TimelineTemplateConverter.swift`；`TimelineImporter` fallback 逻辑；不支持类型安全降级到 crossFade + 打日志 | 服务端下发 `"glitch"` / `"ai_morph"` 等未知类型 → crossFade + 日志；不黑屏；旧草稿 type 字段 100% 正确映射 |
| **M6：补全预设（blur / zoom / mask 类）** | `blurFade / zoomIn / slideRight / pushRight` 及后续遮罩类预设 | 同 M3 验收矩阵；blurFade 帧耗时 ≤ 20ms（A12，720p） |
| **M7：真机回归 + 封版** | 验收清单全绿；旧草稿 v1-v6 100% 加载；720p/40s 导出基准 | V7 验收清单所有项目绿灯 |

排期约束：

- **M1 → M2 严格串行**：M1 修完黑屏、四种组合全绿后才开始 M2；M2 骨架未建立前不做任何新 preset
- **M2 → M3 串行**：TransitionComposer 单出口确立后，M3 各 preset 才有正确的 dispatch 宿主
- **M4 依赖 M3**：UI 面板需要有可展示的 preset 列表；M3 上线后 M4 可并行于 M5
- **M5 不依赖 M4**：服务端映射是纯后端逻辑，与 UI 无交集；M3 完成后即可独立推进
- **M6 是增量**：M3 验证矩阵已覆盖 4 类内容组合；M6 追加预设时复用同一验证框架

---

## 五、黑屏 / 闪跳根因排查结论

根据竞品调研 + 代码逐行分析，V6 现状中转场黑屏/闪跳的全部已知根因：

### 5.1 LayerResolver 转场分支只处理 image→image（**P0-A 修复**）

`LayerResolver.swift:282-293`：

```swift
if let fgSpec = imageLayerMap[seg.id],
   let bgSpec = imageLayerMap[nextSeg.id] {
    resolvedTransition = TransitionInfo(...)
}
```

- `seg.content == .video` → `imageLayerMap[seg.id] == nil` → 整个 if 跳过
- 跳过后 `activeLayers` 在 transition zone 内为空（两侧 segment 都被 continue 掉）
- `TimelineRenderer` 收到 `frame.layers.isEmpty && frame.transition == nil` → 返回 `lastValidPixelBuffer`（最后一个有效帧），即「冻结」最后一帧而非黑屏
- 或者在播放态下，前帧被 AVPlayer decode 路径覆盖，出现闪跳

V7 修复：统一处理四种组合，见 [transition-system-spec.md](transition-system-spec.md) §2.2。

### 5.2 转场期间 overlay / text 丢失（**M1 附带修复**）

`LayerResolver.swift:305`（transition zone 内）：

```swift
if compositionTime >= transStart && compositionTime < transEnd {
    continue  // ← 跳过主轨 segment，正确
}
```

但 overlay / text spec 的添加（`LayerResolver.swift:315-335`）在主轨循环之外，与 transition zone 无关，**理论上不会丢失**。

需要验证：若 overlay segment 的 timeRange 与 transition zone 重叠，是否正确加入 activeLayers。M1 验收时需覆盖此用例。

### 5.3 `incomingMap` 处理时序（**需要 M1 验证**）

`LayerResolver.swift:299-305`（incoming transition zone 处理）：

```swift
if let trans = incomingMap[seg.id] {
    let transStart = insertionTimes[i]
    let transEnd   = transStart + trans.duration
    if compositionTime >= transStart && compositionTime < transEnd {
        continue  // trailing segment 在 incoming zone 内被 skip
    }
}
```

这段逻辑在 `outgoingMap` 已经构造了 `resolvedTransition` 的情况下再 `continue` trailing segment，目的是防止 trailing segment body layer 出现在 transition 区间开始的 body zone。但如果 `outgoingMap` 未命中（前述 video 分支静默跳过），此处的 `continue` 可能导致 trailing segment 在 transition zone 起始帧也被跳过 → 双重跳过 → 黑屏。M1 修复后需确认此路径闭环。

---

## 六、风险与依赖

| 风险 | 影响 | 缓解 |
|---|---|---|
| `VideoLayerComposer.evaluate` 在 transition zone 内求值（video→image 等跨类型转场）| 视频帧和图片帧各自来源不同，同一时刻取帧时序需对齐 | `TransitionComposer` 对 outgoing video 用 `VideoLayerComposer.evaluate(at: compositionTime)`，对 incoming video 同理；两帧均取同一 `compositionTime` 的帧，时序对齐 |
| `CIDissolveTransition` 被替换后视觉一致性 | `crossFade` 效果与 V6 不完全一致，用户感知到变化 | M2 中对 `crossFade` preset 用视觉对比测试：在 V6 crossfade 帧和 V7 同时截屏，diff ≤ 1 pixel |
| 移动类转场（slide / push）在视频帧上实现复杂度 | VideoLayerComposer 当前输出的是 CVPixelBuffer，需要转换为 CIImage 才能做矩阵位移 | `TransitionComposer` 先把两侧帧（无论 image 还是 video）统一转换为 CIImage，再做变换；`VideoLayerComposer.evaluateCIImage` 新增方法 |
| blurFade 在低端机型的性能 | `CIGaussianBlur` radius=20 在 A12 以下设备可能超过 16ms | M3 验收时在 iPhone XS（A12）上测 blurFade 帧耗时；若超标则限制 radius ≤ 12 |
| 旧草稿 `EditorTransition.type` 无法找到对应 preset | 兼容映射表覆盖不全 | 兼容映射表在 M2 完成，M4 服务端 fallback 时同步验证旧草稿路径 |
| `TransitionInfo.presetID` 在 LayerResolver 构造时的来源 | LayerResolver 是纯函数，不访问 Registry | LayerResolver 仅传递 `trans.presetID ?? EditorTransition.presetIDFrom(trans.type)` 静态计算结果；Registry 查询在 TransitionComposer 内部 |
| 720p 40s 导出性能劣化 | blurFade / zoomIn 等高代价转场增加导出时间 | V7 转场区间帧数通常 < 15 帧（0.5s @ 30fps）；M7 实测导出时间与 V6 基准对比 ±10% |

---

## 七、验收标准（V7 验收清单）

### 7.1 转场黑屏消除

| 验收项 | 标准 |
|---|---|
| 图片→图片转场 | transition zone 内每帧均有画面内容，0 黑帧 |
| 图片→视频转场 | 同上 |
| 视频→图片转场 | 同上 |
| 视频→视频转场 | 同上 |
| 转场期间 overlay 层 | overlay segment 时间范围覆盖 transition zone 时，overlay 正常渲染，不丢失 |
| 转场期间 text / subtitle | text segment 时间范围覆盖 transition zone 时，文字正常渲染，不丢失 |

### 7.2 转场效果正确性

| 验收项 | 标准 |
|---|---|
| crossFade | progress=0 时全出帧，progress=1 时全入帧，中间平滑混合；与 V6 dissolve 视觉一致（diff ≤ 1px） |
| fadeThroughBlack | 前半段出帧→全黑，后半段全黑→入帧；中点 100% 黑色 |
| slideLeft | 出帧向左平移出画面，入帧从右侧进入；无缝衔接，边界无裁切残影 |
| slideRight | 对称 slideLeft |
| pushLeft | 出帧与入帧同步向左平移，两帧拼接在画布内；中间点两帧各占 50% 画面 |
| pushRight | 对称 pushLeft |
| zoomIn | 出帧以中心点放大 1.0→1.3 同时 opacity 1→0；入帧直接以正常大小淡入 |
| blurFade | 出帧高斯模糊 0→radius + opacity 1→0；入帧 opacity 0→1 |

### 7.3 Preview / Export 一致性

| 验收项 | 标准 |
|---|---|
| 同一帧内容一致 | 导出视频第 N 帧与 Preview 同时刻截图的视觉差异 ≤ 2px（颜色空间差异除外）|
| 导出帧率不变 | `ffprobe r_frame_rate` = 工程 canvas.fps；无空帧插入 |
| 转场区间帧数正确 | 0.5s / 30fps 转场 = 精确 15 帧过渡 |

### 7.4 服务端 fallback

| 验收项 | 标准 |
|---|---|
| 已知 type 正常映射 | `"dissolve"` → `crossFade`；`"fade"` → `crossFade`；`"slide_left"` → `slideLeft` |
| 未知 type 安全降级 | `"glitch"` / `"ai_morph"` 等 → `crossFade` + `print("[Transition] Unknown...")` + 不黑屏 |
| 旧草稿无 presetID | `decodeIfPresent` nil → `type.rawValue` 查兼容映射表 → 找到对应 presetID |

### 7.5 性能

| 验收项 | 标准 |
|---|---|
| 720p / 30fps / 40s 导出耗时 | 与 V6 基准持平 ±10%（转场总帧数 < 5% 总帧数，应无明显劣化）|
| blurFade 单帧渲染时间（A12，720p）| ≤ 20ms（含 CIGaussianBlur）|
| crossFade 单帧渲染时间 | ≤ 8ms（与 V6 dissolve 基准一致）|

---

## 八、固定交互约束（V1-V6 已锁，V7 全程沿用，禁止改动）

| 约束 | 来源 |
|---|---|
| 转场仅作用于主轨（videoTrack）片段之间 | V2 transition-spec.md §6 |
| 转场时长：min=0.2s / max=3.0s / default=0.5s | V2 transition-spec.md §2.1 |
| 50/50 overlap 无 Handle 模型（总时长减少 duration） | V2 transition-spec.md §2.2 |
| 非主轨（字幕 / 音频 / overlay）无转场 | V2 transition-spec.md §6 |
| `mutateSubtitle` 不重建 compositionVersion | V1 已锁 |
| `isMainTrack` 唯一性 | V1 已锁 |
| 全屏预览为只读沉浸式上下文（不可在全屏内编辑）| V5 已定稿 |
| 导出公共 API 签名锁定：`VideoExporter.export(timeline:)` | V5 已定稿 |
| 图片图层渲染走唯一 unified 路径 | V6 新增隐性约束 |
| 关键帧时间因子标准化（0~1）| V6 新增隐性约束 |

V7 自身新增的隐性约束（写入各 spec）：

- **`TransitionComposer.render` 是唯一转场混合出口**：`TimelineRenderer` / `ExportFrameProvider` / 任何其他调用方内部**禁止直接写 `if dissolve / if slideLeft / CIDissolveTransition`**；所有 preset dispatch 必须在 `TransitionComposer` 内部完成
- **Overlay / Text / Subtitle 不参与主轨转场**：转场效果只作用于主轨的 main visual（outgoing / incoming 帧）；overlay / text / subtitle 层按自身 timeRange 独立渲染，叠加在转场结果之上；禁止在 TransitionComposer 内对 overlay/text 做任何位移 / 透明度 / 模糊处理——否则文字会随主画面闪、丢失或重复出现
- **Transition 不允许修改 segment 的 source timeline duration**：
  - `addTransition` / `removeTransition` / `updateTransitionDuration` 禁止修改任何 `segment.targetRange`（当前实现已正确，禁止回退）
  - 转场收缩只在 `LayerResolver.timelineTiming` cursor 算法中体现（`cursor += seg.targetRange.duration - transDur`）
  - subtitle / audio / TTS / voiceover / seek 均基于 `segment.targetRange`，修改 duration 会导致全线错位
  - `EditorTimeline.duration` 必须与 `timelineTiming` cursor 算法一致（返回 composition 实际时长），不能用 `max(targetRange.end)`（见 M1 修改项）

- **转场不冻结 KeyframeEvaluator**：overlap 期间两侧 clip 的关键帧继续独立求值（见 v6 transition-compat-spec §2.3）
- **所有 `TransitionType` case 必须在 `TransitionPresetRegistry` 中有对应 preset 或 fallback 映射**：V7 起不允许出现静默丢弃转场的情况
- **服务端不认识的转场 type 必须降级到 `crossFade`，且要打日志**

---

## 八·五、Visual Runtime 三层架构原则（V7 M5 后锁定）

> M5 落地后，`TransitionSemantic` 验证了三层架构的完整性。现将此模式提升为
> DreamAI Timeline 所有视觉效果的总原则，后续所有 Preset 系统均须遵守。

### 架构定义

```
Server Intent（服务端描述意图，随服务端迭代变动）
        ↓
Client Semantic（客户端稳定语义，只描述"做什么"，不关心"怎么做"）
        ↓
Runtime Preset（客户端实现细节，可重构、可多端差异化）
```

### 已落地

| 效果类别 | Server Intent | Client Semantic | Runtime Preset |
|---|---|---|---|
| 转场 | `STransition.type` | `TransitionSemantic` | `TransitionPreset` / `presetID` |

### 待扩展（保持同构）

| 效果类别 | Server Intent | Client Semantic | Runtime Preset |
|---|---|---|---|
| 图片运动 | `SImageAnimation.type` | `MotionSemantic` | `ImageAnimationPreset` |
| 图片 3D | `SCamera` | `CameraMotionSemantic` | `Image3DPreset` |
| 视觉效果 | `SEffect.type` | `EffectSemantic` | `EffectPreset` |

### 约束（禁止打破）

1. **服务端不持有 presetID**：服务端 JSON 只描述语义意图，客户端自行决定 preset 实现
2. **Semantic 层只增不改**：已有 case 禁止改名或删除（旧数据永久可解析）
3. **presetID 改名只影响 `resolvedPresetID` 一处**：不波及服务端和语义层
4. **未知 intent 必须 fallback + log**：不允许静默黑屏或 crash
5. **多端可独立映射**：iOS / Android / Web 的 `resolvedPresetID` 可以不同，只要 Semantic 一致

---

## 九、不在本立项范围（转场系统）

- 任何 V6 已落地代码的重构（V6 unified compositor / ImageLayerComposer / KeyframeEvaluator 等）
- v1 / v2 / v3 / v4 / v5 / v6 已有文档的修订
- 非主轨转场（overlay / text / audio）
- 遮罩 / 故障 / 光效 / AI 类转场（V7 P2+）
- 转场「应用到全部」批量 UI（V7 P1 UI 稳定后追加）
- 导出 ProRes / Dolby Vision 时的转场处理（同 V5/V6 ❌）

---

## 十、V7 全线升级：Animation Runtime（2026-05-21 正式立项）

> 经评估，V7 在转场系统基础上全线升级为 **V7 Animation Runtime**。
> Animation Runtime 是与转场系统并行的独立主线，共用三层架构原则（见 §八·五）。

### 10.1 背景与动机

V7 转场系统（M1-M7）解决了「转场黑屏 + preset 体系缺失」问题，确立了 `TransitionSemantic` 三层架构。

但 TimelineKit 还缺少一套等价的**片段动画架构**：

1. `ImageAnimationPreset`（Ken Burns）只适用于图片，不适用于视频
2. 只有「组合」类（全程时长），没有「入场」「出场」独立动画
3. 服务端直接传 presetID（无语义层），与转场系统架构不同构
4. `image_3d` / `SCamera` / `SImageAnimation` 在 `TimelineImporter` 各自特判，未统一

### 10.2 Animation Runtime 核心目标

建立 TimelineKit 统一动画架构基座，不是「做很多动画」：

1. **统一动画模型**：`ClipAnimation`（不是 `ImageAnimation` / `VideoAnimation`）
2. **三层架构**：Server Intent → `AnimationSemantic` → RuntimePreset（与转场系统同构）
3. **入场/出场/组合**：三类动画时序，各自独立，按规则互斥
4. **单出口**：`AnimationComposer.apply(...)` — Preview 和 Export 共用
5. **动画不改 duration**：只影响渲染，不修改 `segment.targetRange`
6. **DraftStore 稳定**：`ClipAnimation` 字段以 `decodeIfPresent` 方式附加到 `EditorSegment`
7. **M6 收口**：`image_3d` / Ken Burns 统一进 `AnimationSemantic`，`TimelineImporter` 不再特判

### 10.3 Animation Runtime 范围围栏

**Phase 1（Am1-Am5）必做：**
- `ClipAnimation` 数据模型 + `EditorSegment.animations` 字段
- `AnimationSemantic` 三层架构 + `AnimationPresetRegistry`
- `AnimationComposer` 插入 `TimelineRenderer` / `ExportFrameProvider`
- 首批预设：fadeIn / slideIn（4方向）/ zoomIn / fadeOut / slideOut / zoomOut / slowZoom / drift / float
- `AnimationPickerSheet` UI（入场/出场/组合 Tab + 时长 slider + Live Preview）
- `TimelineImporter` 动画字段解码 + 未知类型 fallback

**M6（image_3d 统一，与转场系统 M6 同期）：**
- `ImageAnimationPreset` 全部映射到 `AnimationSemantic.combo` 对应 case
- `TimelineImporter` 删除 `SCamera` / `SImageAnimation` 特判
- `ImageAnimationPanel` 标记 deprecated，`AnimationPickerSheet` 完整接管

**暂不做（Animation Runtime P2+）：**
- Metal shader 动画（3D 翻转 / 粒子 / 光效）
- 文字/字幕/sticker 动画
- 「应用到全部动画」批量操作
- 动画强度（intensity）高级参数 UI
- AI 生成动画参数（V8+）

### 10.4 Animation Runtime 依赖约束

```
DraftStore 归一化（docs/timeline-draft-store-unification-plan.md，进行中）
        ↓（不强依赖，但归一化完成后 Animation Runtime 字段路径更稳定）
Animation Runtime Am1（基座骨架）
        ↓
Am2（AnimationComposer 渲染集成）
        ↓
Am3（首批 Phase 1 预设完整）
        ↓
Am4（UI 面板）  ← 可与 Am5 并行
Am5（服务端映射）
        ↓
Am6（image_3d / Ken Burns 迁移，与转场 M6 同期）
```

**转场系统 M1-M3 需先稳定，再推进 Animation Runtime Am1。**

### 10.5 规范文档索引

| 文档 | 内容 |
|---|---|
| [competitive-benchmarks-animation-V7.md](competitive-benchmarks-animation-V7.md) | 竞品调研：剪映/VN/FCP/Premiere 动画系统对比 |
| [animation-runtime-V7.md](animation-runtime-V7.md) | 核心架构：三层架构 / ClipAnimation / AnimationComposer / 首批预设 |
| [animation-draft-compat-V7.md](animation-draft-compat-V7.md) | DraftStore 集成 + TimelineImporter 边界 |
| [animation-ui-spec-V7.md](animation-ui-spec-V7.md) | UI 规范：AnimationPickerSheet / 入场出场组合 Tab |

---

## 十、文档间引用图

```
docs/v7/
   ├── README.md
   ├── V7-initiation.md  （本文档）
   ├── competitive-benchmarks-v7.md
   │      ↳ 被 transition-system-spec / visual-template-registry-spec 引用
   ├── transition-system-spec.md  （P0）
   │      ↳ 依赖 v6/image-layer-rendering-spec：ImageLayerComposer 作为 image 侧帧源
   │      ↳ 依赖 v6/transition-compat-spec：overlap 期间关键帧行为规则
   │      ↳ 依赖 v2/transition-spec：时长约束 / overlap 模型 / 数据结构基础
   │      ↳ 修改 LayerResolver.swift / TimelineRenderer.swift（精确到 line）
   │      ↳ 新增 TransitionPresetRegistry.swift / TransitionComposer.swift
   ├── visual-template-registry-spec.md  （P1）
   │      ↳ 依赖 transition-system-spec：TransitionPresetRegistry 作为四件之一
   │      ↳ 依赖 v6/ai-timeline-mapping-spec：AnimationMacro 与 ImageAnimationPresetRegistry 关系
   │      ↳ 新增 TimelineTemplateConverter.swift
   └── transition-ui-spec.md  （P1）
          ↳ 依赖 transition-system-spec：8 个预设的 presetID / 分类
          ↳ 依赖 v2/transition-spec：时长滑块约束 / 转场 UI 入口
          ↳ 依赖 v3/text-entry-spec §约束：底部工具栏布局规则

外部依赖（沿用不重写）：
   - docs/v2/transition-spec.md          → 时长约束 / overlap 模型
   - docs/v6/transition-compat-spec.md   → 关键帧在 overlap 期间的行为
   - docs/v6/image-layer-rendering-spec.md → ImageLayerComposer 帧源
   - docs/v6/keyframe-animation-spec.md  → KeyframeEvaluator
```
