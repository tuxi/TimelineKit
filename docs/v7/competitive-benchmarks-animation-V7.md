# V7 竞品对标：动画系统深度调研

> 版本：v7.1
> 状态：调研定稿
> 服务对象：[animation-runtime-V7.md](animation-runtime-V7.md) 的架构定档依据
> 对标产品：剪映 iOS 14.0+（移动端主对标）/ CapCut Desktop 4.0+ / VN 2.x / Final Cut Pro 11 / Adobe Premiere 2024
> 说明：本文专注「片段动画」（入场/出场/组合）调研；转场系统调研见 [competitive-benchmarks-v7.md](competitive-benchmarks-v7.md)

---

## 一、动画分类体系对比

### 1.1 剪映（CapCut iOS）—— 移动端主对标

剪映将片段动画分为三大类，通过底部工具栏「动画」入口进入：

**入场动画（Entrance）：**

| 预设名 | 效果描述 | 实现方式 |
|---|---|---|
| 渐显 | opacity 0→1 | opacity ramp |
| 向右滑入 | translateX(-W→0) + opacity 0→1 | transform + opacity |
| 向左滑入 | translateX(+W→0) + opacity 0→1 | transform + opacity |
| 向下滑入 | translateY(-H→0) + opacity 0→1 | transform + opacity |
| 向上滑入 | translateY(+H→0) + opacity 0→1 | transform + opacity |
| 放大 | scale(0.8→1.0) + opacity 0→1 | transform + opacity |
| 缩小 | scale(1.3→1.0) + opacity 0→1 | transform + opacity |
| 旋转放大 | scale(0.8→1.0) + rotation(-15°→0) + opacity | transform + opacity |
| 弹跳 | scale 弹性曲线 + opacity 0→1 | easeOut spring |
| 翻转 | scaleX(0→1) 模拟翻转 | transform |

**出场动画（Exit）：**

与入场对称，方向相反，opacity 1→0，共约 10 个预设。

**组合动画（Combo，全程时长）：**

| 预设名 | 效果描述 | 实现方式 |
|---|---|---|
| 呼吸 | scale 1.0↔1.04 循环往复 | 正弦曲线 scale |
| 漂浮 | translateY 轻微上下浮动 | 正弦曲线 position |
| 心跳 | 两次快速缩放 + 停顿 | 分段 scale |
| 缓慢放大 | scale 1.0→1.12（全程） | 同 Ken Burns |
| 闪烁 | opacity 快速交替 | opacity keyframe |
| 晃动 | rotation 左右摆动 | rotation keyframe |

**关键特征：**
- 入场 + 出场**可以同时存在**，互相独立；组合动画与入场/出场**互斥**（同一 clip 只能选其中一种大类）
- 每种动画有独立的 `duration` slider，但 in.duration + out.duration ≤ segment.duration（超出时 UI 自动约束）
- **自动 Preview**：点击任何预设立即在主预览区播放该片段动画效果，无需额外操作
- 选中状态：预设格高亮描边 + 底部时长 slider 激活

**数据结构（反混淆工程分析）：**

```json
{
  "animations": [
    {
      "id": "animation-uuid",
      "type": "in",
      "category_name": "渐显",
      "resource_id": null,
      "duration": 500000,
      "easing": "ease_out",
      "category_id": "fade_in"
    },
    {
      "id": "animation-uuid-2",
      "type": "out",
      "category_name": "渐隐",
      "resource_id": null,
      "duration": 300000,
      "easing": "ease_in",
      "category_id": "fade_out"
    }
  ]
}
```

存储模型：
- `type`：`"in"` / `"out"` / `"loop"`（组合）
- `category_id`：内建预设标识符（semantic 层）
- `resource_id`：付费/下载预设的资源 ID；内建预设为 null
- `duration`：微秒（内部单位），UI 层换算为秒
- 内建预设实现为 GPU 矩阵变换（非 shader），付费预设可能含 Metal shader

**Runtime 实现方式：**
- 内建预设：CIFilter + CIAffineTransform（CPU/GPU 混合）
- 付费复杂预设：Metal 自定义滤镜
- Preview 与 Export 共用同一渲染路径（同一 CIContext 实例配置不同）

**草稿保存策略：**
- 保存 `semantic`（category_id）+ `duration`，不 bake keyframe
- 旧版本草稿无 animations 字段 → 加载时视为无动画

---

### 1.2 VN（威图）—— 轻量移动端参考

VN 的动画系统比剪映简单，结构相同：三 Tab（入场/出场/组合），但预设数量少（~15 个）。

**数据结构：**

```json
{
  "clip_animation": {
    "in": {
      "type": "fade_in",
      "duration": 0.5,
      "timing_function": "ease_out"
    },
    "out": {
      "type": "fade_out",
      "duration": 0.3,
      "timing_function": "ease_in"
    }
  }
}
```

**关键特征：**
- 入场/出场为独立字段（非数组），语义更清晰
- `type` 是 semantic 标识符（`fade_in` / `slide_in_left` 等）
- 无 `resource_id`：全部内建预设，无付费动画
- 时长约束：max = min(2.0s, segDuration * 0.5)
- 无组合动画（仅有静态效果，无呼吸/漂浮类）
- 不支持 intensity / 方向等附加参数

---

### 1.3 Final Cut Pro —— 桌面专业参考

FCP 对片段级动画的设计与移动端有根本性差异：

**对视频 clip：**
- 无内建「入场/出场」预设
- 通过 Inspector → Video → Transform / Opacity 手动设置关键帧
- 「动画」= 手动关键帧编辑；无 preset picker

**对 Title/Text clip：**
- 有「Build In」「Build Out」动画选择（FCP 专有概念）
- 预设由 Motion 模板定义（每个 Title 自带其 Build In/Out）
- 参数通过 Inspector 调整，不是通用的 preset 系统

**核心区别：**
- FCP 没有剪映式的「全局入场预设库」——动画附属于素材类型（Title 才有 Build In/Out）
- Preview/Export 同源：同一 Motion 引擎，只是渲染上下文不同

**对 V7 的参考意义：**
- FCP 模型对 AI 视频生成场景不适用（需要用户手动打关键帧，AI 无法自动生成）
- V7 应采用剪映模型：独立 preset library + duration slider，AI 可直接指定 semantic

---

### 1.4 Adobe Premiere Pro —— 桌面专业参考

Premiere 的片段动画依赖「Effect Controls」面板：

**无入场/出场 preset 概念：**
- 需手动在 Effect Controls 中给 Opacity / Position / Scale / Rotation 打关键帧
- 「预设」= 保存的 Effect Control 组合，通过 Effects 面板的「Presets」文件夹分发

**Premiere 的设计哲学：**
- 完全 keyframe 驱动，无 semantic 中间层
- 数据存储：XML 格式，baked keyframe（时间点 + 参数值）
- Export = Preview 路径同源（Mercury GPU Engine）

**对 V7 的参考意义：**
- Premiere 的 keyframe-baked 模型对动态服务端内容适配性差（服务端不能直接传 keyframe）
- V7 应保持 semantic 层隔离（服务端传 `"fade_in"` 而非 keyframe 坐标）

---

### 1.5 Canva Video —— 轻量 Web 参考

Canva 的「Animate」功能是最简化的入场/出场模型：

```json
{
  "animations": {
    "enter": { "type": "fade", "duration": 0.5 },
    "exit":  { "type": "fade", "duration": 0.3 }
  }
}
```

- 仅支持 4 种入场（Fade / Pan / Rise / Block）+ 4 种出场
- 无组合动画
- 无 intensity / direction 参数
- 所有动画都是 CSS/SVG 变换，非 GPU shader

对 V7 意义：Canva 的最简模型验证了「semantic + duration」是最小可行的动画数据结构。

---

## 二、动画作用对象对比

| 产品 | 视频 clip | 图片 clip | 文本/字幕 | 贴纸/overlay |
|---|---|---|---|---|
| **剪映** | ✅ 入场/出场/组合 | ✅ 入场/出场/组合（组合=Ken Burns类） | ✅ 独立文字动画系统 | ✅ 贴纸有独立动画 |
| **VN** | ✅ 入场/出场 | ✅ 入场/出场 | ✅（有限） | ❌ |
| **FCP** | 手动关键帧 | 手动关键帧 | Build In/Out | ❌（需 Motion） |
| **Premiere** | 手动关键帧 | 手动关键帧 | 有限预设 | ❌ |
| **TimelineKit V6** | ❌（无入场/出场） | ✅ Ken Burns（组合类） | ❌ | ❌ |
| **V7 定档** | ✅ 入场/出场（Phase 1） | ✅ 入场/出场 + 组合迁移（Phase 1 + M6）| 延后 | 延后 |

---

## 三、动画时长模型对比

| 产品 | 时长模型 | 最大限制 | 入场+出场约束 |
|---|---|---|---|
| **剪映** | 独立 duration（独立于 clip duration） | min(2.0s, segDuration * 0.5) | in + out ≤ segDuration（UI 强制）|
| **VN** | 同剪映 | min(2.0s, segDuration * 0.5) | 同上 |
| **FCP** | 依赖 Handle 余量（同转场） | Handle 余量决定 | N/A |
| **Premiere** | keyframe 起止时间决定 | 无硬限制 | N/A |
| **V7 定档** | 独立 duration | min(2.0s, segDuration * 0.5) per side | in.duration + out.duration ≤ segDuration |

**V7 定档依据：**
- 采用剪映模型：`duration` 独立存储，不修改 `segment.targetRange`
- 动画只影响渲染（opacity / transform），不影响时间轴
- max duration = `min(2.0, segment.targetRange.duration * 0.5)`（双侧各 50%）

---

## 四、草稿保存策略对比

| 产品 | 保存内容 |
|---|---|
| **剪映** | semantic（category_id）+ duration；**不 bake keyframe** |
| **VN** | semantic（type）+ duration；不 bake |
| **FCP** | baked keyframe（XML 关键帧坐标） |
| **Premiere** | baked keyframe（XML ticks 坐标） |
| **V7 定档** | semantic（AnimationSemantic case）+ duration；**不 bake** |

**V7 定档依据（关键）：**
- 保存 semantic 而非 baked keyframe 的原因：
  1. 服务端可以直接传 semantic 描述意图
  2. 客户端可以升级 preset 实现而不重新生成草稿
  3. DraftStore 数据量小
  4. 旧草稿加载时可重新从 preset 推断动画参数

---

## 五、Preview 与 Export 同源对比

| 产品 | 同源机制 |
|---|---|
| **剪映** | 同一 GPU compositor；Preview 用实时渲染，Export 用离线渲染；动画逻辑代码共享 |
| **VN** | 同一 CIFilter pipeline |
| **FCP** | 同一 Motion Engine 实例，不同配置 |
| **TimelineKit V6** | `TimelineRenderer` 和 `ExportFrameProvider` 共用 `ImageLayerComposer.evaluate` |
| **V7 定档** | `AnimationComposer.apply(...)` 被 `TimelineRenderer` 和 `ExportFrameProvider` 共同调用；禁止 Export 路径单独实现动画逻辑 |

---

## 六、服务端→客户端动画描述映射

剪映服务端（根据 AI 脚本生成 draft）传递的动画字段：

```json
{
  "animation": {
    "in": { "type": "fade", "duration": 0.5 },
    "out": { "type": "slide_out", "direction": "left", "duration": 0.3 }
  }
}
```

VN 类似。

**V7 定档的映射规则（见 animation-draft-compat-V7.md）：**
- 服务端 `type` → `AnimationSemantic`（稳定 semantic 层）
- `AnimationSemantic` → runtime `presetID`（客户端自由决定实现）
- 未知 `type` → `.unknown` → fallback 到 `fadeIn` / `fadeOut`（不黑屏，打日志）

---

## 七、各产品动画分类数量参考

| 产品 | 内建入场 | 内建出场 | 内建组合 | 付费扩展 |
|---|---|---|---|---|
| **剪映 iOS** | ~15 | ~15 | ~8 | ~50+（付费包） |
| **CapCut Desktop** | ~20 | ~20 | ~10 | ~100+（Effect Store）|
| **VN** | ~8 | ~8 | 0 | ❌ |
| **FCP** | N/A | N/A | N/A | Motion 插件无限 |
| **V7 Phase 1 定档** | 4 | 3 | 3 | 0（先建基座） |

---

## 八、V7 定档结论

基于调研，V7 Animation Runtime 定档如下关键决策：

| 调研项 | 结论 | 依据 |
|---|---|---|
| 动画分类 | 入场 / 出场 / 组合 三类 | 剪映 / VN 一致 |
| 动画作用对象 | V7 Phase 1 只做 clip（图片 + 视频）；文字/字幕/sticker 延后 | 先建通用基座 |
| 时长模型 | 独立 duration，max = min(2.0s, segDuration * 0.5) | 剪映模型，符合 AI 场景 |
| 动画预览 | 点击 preset 自动 Preview（clip 从头播放动画段） | 剪映交互规律 |
| 数据结构 | semantic + duration（不 bake keyframe） | 剪映/VN 共同做法 |
| Runtime | CIAffineTransform + opacity（Phase 1 无 Metal shader） | 复杂度可控 |
| 草稿保存 | AnimationSemantic + duration | 语义稳定，服务端可直接传 |
| 导出一致性 | `AnimationComposer.apply` 单出口，Preview/Export 共用 | 剪映/FCP 架构共识 |
