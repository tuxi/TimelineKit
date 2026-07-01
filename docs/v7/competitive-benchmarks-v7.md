# V7 竞品对标：转场系统深度调研

> 版本：v7.0
> 状态：调研定稿
> 服务对象：[transition-system-spec.md](transition-system-spec.md) / [visual-template-registry-spec.md](visual-template-registry-spec.md) 的规则定档依据
> 对标产品：剪映 iOS 14.0+ / CapCut Desktop 4.0+ / Final Cut Pro 11 / Adobe Premiere 2024 / VN 2.x / Canva Video

---

## 一、转场数据结构对比

### 1.1 剪映（CapCut）—— 移动端主对标

剪映转场存储在 `draft_content.json` 的片段间节点（反混淆工程分析）：

```json
{
  "type": "dissolve",
  "name": "叠化",
  "duration": 500000,       // 微秒，500ms
  "easing": "ease_in_out",
  "category": "基础",
  "resource_id": "xxx",    // 内建预设无 resource_id
  "leading_segment_id": "uuid-A",
  "trailing_segment_id": "uuid-B"
}
```

部分高级转场（移动、模糊、遮罩类）含额外参数：

```json
{
  "type": "slide_left",
  "direction": "left",
  "intensity": 0.8,          // 部分移动类转场强度
  "blur_strength": 0.5       // 模糊类转场专属
}
```

**关键特征：**
- 转场作为**独立对象**存储在两个片段 ID 之间，不附加到任何一侧
- duration 使用微秒整数（内部计时单位），UI 层换算为秒
- 支持跨内容类型：图片→视频 / 视频→图片 / 图片→图片 / 视频→视频 均可用同一转场对象
- 同一片段的入场和出场各使用独立的转场对象（两个片段共享一个 transition 节点，双向引用）

### 1.2 Final Cut Pro —— 专业桌面参考

FCP 转场以 **Transition Clip** 形式存储，是 Storyline 上的独立时间轴对象：

```xml
<transition name="Cross Dissolve" offset="12s" duration="1s" ref="r1">
  <param name="Ease" key="9999/10003/..." value="easeInEaseOut"/>
</transition>
```

**关键特征：**
- 转场 clip 自身有 `offset`（在主时间轴上的起点）和 `duration`
- 参数通过 `<param>` 子节点扩展，每种转场有各自参数模板（FxPlug Schema）
- **必须有 Handle**（前后片段的有效素材超出 In/Out 点的余量）：转场区域实际读取的是两侧 clip 的"溢出"帧
- 跨内容类型：图片 = 固定帧视频 clip，转场逻辑完全相同
- Preview/Export 完全同源（同一 GPU compositor 实例，不同渲染上下文配置）

### 1.3 Adobe Premiere Pro —— 专业桌面参考

Premiere 转场存储在序列 XML 的 `<transitionitem>` 节点：

```xml
<transitionitem>
  <start>2400</start>           <!-- 以 ticks 计的起始点 -->
  <end>4800</end>               <!-- 以 ticks 计的结束点 -->
  <alignment>start-black</alignment>  <!-- center/start-black/end-black -->
  <effect>
    <name>Cross Dissolve</name>
    <effectid>CrossDissolve</effectid>
    <effectcategory>Dissolve</effectcategory>
  </effect>
</transitionitem>
```

**关键特征：**
- `alignment` 决定转场在切点的对齐方式：`center`（50/50）/ `start-black`（仅出场）/ `end-black`（仅入场）
- 同样需要 Handle；无 Handle 时 Premiere 用「重复帧」填充（与剪映策略不同）
- GPU 加速：大多数内置转场是 GLSL shader + Mercury GPU 引擎

### 1.4 VN（威图）—— 轻量移动端参考

VN 转场结构简单：

```json
{
  "transitionType": "slide_in_left",
  "duration": 0.4,
  "timingFunction": "easeInOut"
}
```

**关键特征：**
- 无 resource_id，全部内建预设
- 不支持 intensity / blur_strength 等额外参数
- 预设数量少（约 20 个），全部 CIFilter 实现

### 1.5 Canva Video —— 轻量 Web 参考

Canva 将转场视为「场景间动画」：

```json
{
  "animation": {
    "type": "dissolve",
    "duration": 0.5
  }
}
```

- 仅支持 dissolve / fade-to-black / slide / zoom 四种
- 不区分 easing，全部用默认 ease
- 无遮罩 / 模糊 / 故障类转场

---

## 二、转场如何挂在两个片段之间

| 产品 | 挂载方式 | 时长模型 |
|---|---|---|
| **剪映** | 独立 transition 对象，双向引用 leading/trailing segment ID | 50/50 overlap：前后片段各缩短 D/2，总时长减少 D |
| **FCP** | Storyline 上的 Transition Clip，占据切点两侧各 D/2 | 需要 Handle；总时长不变（素材余量覆盖） |
| **Premiere** | transitionitem 节点，center alignment = 50/50 | 同 FCP Handle 策略；或重复帧填充 |
| **VN** | 附加在前片段的出场属性上 | 前片段在最后 D 内播放转场动效，后片段正常开始 |
| **TimelineKit v2 规范** | 独立 `EditorTransition`，双向 segmentID 引用 | 50/50 overlap，无 Handle，总时长减少 D（采用剪映模型）|
| **V7 定档** | 沿用 v2 `EditorTransition` 数据结构，**新增 presetID / direction / intensity** | 沿用 50/50 overlap 无 Handle 模型 |

**V7 定档依据**：继续沿用剪映的无 Handle 50/50 模型，因为 DreamAI 服务端生成的片段时长恰好等于目标时长，无素材余量，无法走 FCP/Premiere 的 Handle 策略。

---

## 三、转场时长吃掉前后片段时间的方式

### 50/50 Overlap 模型（剪映 / DreamAI 采用）

```
添加转场：
  leadingSegment.targetRange.end   -= duration / 2
  trailingSegment.targetRange.start += duration / 2
  transitionRange.start = leadingSegment.targetRange.end （新收缩后位置）
  transitionRange.duration = duration

删除转场：
  leadingSegment.targetRange.end   += duration / 2
  trailingSegment.targetRange.start -= duration / 2
```

- 总时长 = 原时长 - transition.duration
- 两侧片段各让出一半时间给过渡区
- 不要求素材有任何额外余量（适合 DreamAI AI 工程）

### Handle 模型（FCP / Premiere）

前后片段的有效播放区间不变，而是通过读取素材超出 In/Out 点的"handle 区"的帧来实现过渡。总时长不变，但需要素材原始长度 > 目标时长。移动端 AI 工程不适用。

---

## 四、转场是否允许跨内容类型

| 产品 | image→video | video→image | video→video | image→image | 文字/字幕轨道 |
|---|---|---|---|---|---|
| **剪映** | ✅ | ✅ | ✅ | ✅ | ❌ |
| **FCP** | ✅（图片 = 静帧视频）| ✅ | ✅ | ✅ | ❌ |
| **Premiere** | ✅ | ✅ | ✅ | ✅ | ❌ |
| **VN** | ✅ | ✅ | ✅ | ✅ | ❌ |
| **TimelineKit v6** | ❌ **黑屏** | ❌ **黑屏** | ❌ **黑屏** | ✅ | ❌ |
| **V7 定档** | ✅ | ✅ | ✅ | ✅ | ❌（沿用） |

**V7 必须修复**：当前 `LayerResolver`（`Sources/TimelineKit/Runtime/LayerResolver.swift:282-293`）的转场分支仅在 `imageLayerMap[seg.id]` 和 `imageLayerMap[nextSeg.id]` 两者均不为 nil 时才构造 `TransitionInfo`，否则静默跳过 → 黑屏。

---

## 五、预览和导出是否同源

| 产品 | 同源机制 |
|---|---|
| **剪映** | 同一 GPU compositor 实例，Preview 用实时渲染，Export 用离线渲染；转场 shader 代码完全共享 |
| **FCP** | Motion 引擎实例化两次（Preview context / Export context），转场参数完全相同 |
| **Premiere** | Mercury GPU Engine 处理 Preview 和 Export；显示 GPU 加速时两者使用同一 shader |
| **TimelineKit v6** | `TimelineRenderer.renderFrame` 和 `ExportFrameProvider.frame(at:)` 均调用 `ImageLayerComposer.evaluate`——同源 |
| **V7 定档** | `TransitionComposer.blend` 被 `TimelineRenderer` 和 `ExportFrameProvider` 共同调用；禁止 Export 路径单独实现转场逻辑 |

---

## 六、转场分类体系对比

### 6.1 剪映转场分类（iOS 14.0+ 参考）

| 大类 | 代表预设 | 实现方式 |
|---|---|---|
| 基础 | 叠化、闪黑、闪白、渐隐渐现 | `CIDissolveTransition` / opacity ramp |
| 运镜 | 左移、右移、上移、下移、推进、拉远 | GPU 矩阵位移变换 |
| 缩放 | 放大、缩小、模糊放大、模糊缩小 | scale transform + optional blur |
| 模糊 | 高斯模糊、运动模糊 | `CIGaussianBlur` / `CIMotionBlur` |
| 遮罩 | 横扫、圆形展开、圆形收拢 | Metal shader stencil |
| 光效 | 闪光、镜头光晕 | Metal particle + flare shader |
| 故障 | RGB 错位、数字故障、VHS | Metal glitch shader |
| MG 动效 | 各种花式 MG | Metal + 顶点变换 |

**剪映总量**：约 180+ 预设（含付费）；免费约 40 个。

### 6.2 CapCut Desktop 分类

与剪映基本一致，追加：
- **3D 转场**（翻转 / 折叠 / 旋转）— Metal 3D 矩阵变换
- **AI 转场**（基于 AI 生成的过渡帧）— 服务端推理 + 本地合成

### 6.3 Final Cut Pro 转场分类

| 大类 | 代表预设 |
|---|---|
| Dissolves | Cross Dissolve, Dip to Color, Fade to Black |
| Motion | Flip, Page Curl, Spin |
| Wipes | Band Wipe, Barn Door, Center Wipe, Radial |
| Objects | Cube, Doorway |
| Stylized | Colorize, Desaturate |

FCP 内置约 30 个免费转场，Motion 插件可扩展到数百个。

### 6.4 V7 首批实现定档

调研结论：**先做基础稳定的 8 个，不追求数量**，这 8 个覆盖了剪映免费转场里 80% 的用户使用率：

| 大类 | presetID | 实现技术 |
|---|---|---|
| 基础 | `crossFade` | `CIDissolveTransition` |
| 基础 | `fadeThroughBlack` | opacity ramp to black + opacity ramp from black |
| 移动 | `slideLeft` | 出帧右出 / 入帧右进（Translation transform） |
| 移动 | `slideRight` | 出帧左出 / 入帧左进 |
| 移动 | `pushLeft` | 出帧与入帧同步水平位移（Push：两帧同速移动） |
| 移动 | `pushRight` | 同上，反方向 |
| 缩放 | `zoomIn` | 出帧 scale 1→1.3 + opacity 1→0；入帧直接出现 |
| 模糊 | `blurFade` | `CIGaussianBlur` radius 0→20 + opacity 1→0 on outgoing；incoming opacity 0→1 |

剩余预设（slideUp/Down、zoomOut、zoomBlurIn/Out、motionBlurSlide、wipe 类、circle 类）进入 V7 P2（视觉模板注册表完整落地后追加）。

---

## 七、各竞品转场 UI 交互规律

### 7.1 剪映 — 转场入口与操作流程

1. **入口**：主轨两片段切割点处出现「菱形图标」；点击唤起底部转场面板
2. **面板结构**：
   - Tab：基础 / 运镜 / 缩放 / 模糊 / 风格化（对应分类）
   - 列表：2×N 宫格缩略图，带动态预览循环动画（约 1s 循环）
   - 已选：高亮描边 + 勾选标记
3. **时长调整**：面板底部滑块，实时更新，步长 0.1s
4. **应用范围**：支持「应用到全部转场」批量操作
5. **删除**：面板内 X 按钮 / 长按转场图标弹出删除操作

### 7.2 FCP — 转场入口与操作流程

1. **入口**：Transitions Browser 面板（独立窗口），拖拽到切割点
2. **时长调整**：Inspector 中输入精确值，或时间轴上拖拽两侧手柄
3. **Preview**：Viewer 中实时预览

### 7.3 V7 UI 定档

对齐剪映 iOS 体验，见 [transition-ui-spec.md](transition-ui-spec.md)。

---

## 八、服务端转场字段映射（DreamAI 协议分析）

根据 [ServerTimelineSchema.swift](../../Sources/TimelineKit/Conversion/ServerTimelineSchema.swift) 和 [TimelineImporter.swift](../../Sources/TimelineKit/Conversion/TimelineImporter.swift) 中已有的 `EditorTransition` 解码逻辑，服务端当前下发的转场字段：

```json
{
  "type": "dissolve",
  "duration": 0.5,
  "easing": "ease_in_out"
}
```

V7 需要能够处理服务端未来可能下发的扩展字段（`direction` / `intensity` / `name`），并在客户端不支持时安全 fallback 到 `crossFade`。

**V7 定档的服务端→客户端转场映射规则**见 [visual-template-registry-spec.md](visual-template-registry-spec.md) §4。
