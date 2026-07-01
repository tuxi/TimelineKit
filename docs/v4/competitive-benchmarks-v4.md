# V4 竞品对标总报告

> 版本：v4.0
> 状态：规范定稿
> 对标产品：剪映 iOS 13.0+（移动端主对标） + Final Cut Pro 11（桌面级专业参考） + CapCut Desktop 3.0+ + LumaFusion 3.x（iPad 中端 NLE）
> 服务对象：V4 P0/P1 全部 5 份 spec 的规则定案依据

本报告把 V4 P0/P1 涉及的全部能力点（样式保真 / 批量应用 / 多轨滚动 / 文本排版与层级 / 音频与轨道控制）按 7 个能力族拉到一起对标。规则定案集中在本文档维护，避免在 5 份 spec 之间重复抄写；各 spec 的「规则段」直接引用本文档对应章节。

---

## 一、文本样式预览刷新策略

### 1.1 各家做法

| 产品 | 策略 | 用户感知 |
|---|---|---|
| **剪映 iOS** | 滑杆 / 颜色拨片 mutate → 编辑画布对应字幕图层直接 `setNeedsDisplay`；预设点击即时切换整套 TextStyle；无 loading 态 | 「点完直接显示，秒变」 |
| **CapCut Desktop** | 同剪映；颜色 / 描边 / 阴影/ 背景全部 in-canvas 实时刷新 | 桌面端因画布更大反馈更明显 |
| **FCP（Titles）** | 检查器面板 mutate → Viewer 立即刷新；样式 dropdown 切换有 200~400ms 过场（含 Motion 模板加载） | 专业用户接受小延迟 |
| **LumaFusion** | Inspector 滑杆 mutate → Viewer 立即刷新；预设走 in-app 浏览器，点击应用 200ms | 移动端体验向 FCP 靠拢 |

### 1.2 对比 v3 现状

| 能力 | 剪映 | CapCut | FCP | LumaFusion | **v3 现状** |
|---|---|---|---|---|---|
| 调字体 / 字号 / 颜色 → 预览刷新 | ✅ 实时 | ✅ 实时 | ✅ 实时 | ✅ 实时 | ✅ 实时（仅这三项） |
| 调描边 / 阴影 / 背景圆角 / 内边距 → 预览刷新 | ✅ 实时 | ✅ 实时 | ✅ 实时 | ✅ 实时 | ❌ **不刷新**（字段已 mutate 但 SubtitleLayerBuilder 不读） |
| 调行间距 / 字间距 / 斜体 → 预览刷新 | ✅ 实时 | ✅ 实时 | ✅ 实时 | ✅ 实时 | ❌ **不刷新** |
| 预设点击应用 | ✅ 即时 | ✅ 即时 | ✅ 即时 | ✅ 即时 | ❌ **点击无响应**（无 tap handler） |
| 导出与预览一致 | ✅ 完全一致 | ✅ 完全一致 | ✅ 完全一致 | ✅ 完全一致 | 🟡 导出端正确，预览端缺字段 → **不一致** |

### 1.3 v4 定案

**采用剪映/CapCut 移动端模型：所有 12 个字段 mutate 后立即触发字幕图层 `setNeedsDisplay`，无 loading 态、无过场。** 详见 [text-style-fidelity-spec.md](text-style-fidelity-spec.md) §2。

---

## 二、文本样式预设入口

### 2.1 各家做法

| 产品 | 入口位置 | 预设数量 | 点击行为 |
|---|---|---|---|
| **剪映 iOS** | 文本编辑底栏「样式」Tab 第一行横向 ScrollView | 8~12 个 | 点击立即应用整套 TextStyle（颜色 + 描边 + 阴影 + 背景），覆盖当前段 |
| **CapCut Desktop** | 右侧 Inspector → Styles → 缩略图网格 | 30+ | 同剪映 |
| **FCP** | Titles 浏览器 → 拖拽到时间线 | N/A（模板而非样式预设）| 拖拽创建新片段 |
| **LumaFusion** | Inspector → Title → Presets | 12 | 点击应用 |

### 2.2 v3 现状

`stylePresetsRow`（[TextEditPanel.swift:291](../../Sources/TimelineKit/Views/TextEditPanel.swift)）：

- 入口位置：与剪映完全一致——`textStyleContent` 顶部 + 横向 ScrollView
- 预设数量：1 个 None + 6 个色卡阴影组合，共 7 个
- 点击行为：**❌ 无 tap handler**（ZStack 仅为装饰）

### 2.3 v4 定案

**接线剪映行为：6 个色卡预设点击 → 调 `EditorStore.applyStylePreset(segmentID:preset:)`（新增）→ 替换 segment.style 的 `color` + `shadowColor` + `shadowOffsetX/Y` + `shadowRadius` 字段，其他 9 个字段保持当前值不变。** 详见 [text-style-fidelity-spec.md](text-style-fidelity-spec.md) §3。

「None」预设特殊处理：将 `color` 重置为白色（"#FFFFFF"），`shadowColor` 置 `nil`。

---

## 三、批量样式应用

### 3.1 各家做法

| 产品 | 入口 | 作用域 | 二次确认 |
|---|---|---|---|
| **剪映 iOS** | 字幕编辑面板「应用到全部」按钮 | 选择「全部字幕」或「同轨字幕」；自动字幕默认作用于全部 | 有：「将影响 N 条字幕，确定吗？」 |
| **CapCut Desktop** | 右键片段 → Copy Style，再多选其他片段 → Paste Style | 用户手动多选 | 无（依赖多选明确性） |
| **FCP** | Edit → Paste Attributes... → 多选属性对话框 | 单段拷贝、单段粘贴；属性勾选粒度（颜色 / 字体 / 阴影 分项）| 有：属性勾选对话框本身即确认 |
| **LumaFusion** | Inspector → Copy / Paste Style | 单段拷贝、单段粘贴 | 无 |

### 3.2 v3 现状

无任何 batch / applyToAll 方法；EditorStore 单段 mutate 路径完备但无聚合 API。

### 3.3 v4 定案

**取剪映「应用到本轨同类」模型 + FCP 二次确认弹窗**：

- **入口位置**：`TextEditPanel` 功能按钮区显式按钮，文案「应用到本轨同类」（图标 `+ doc.on.doc`）
- **作用域**：当前 segment 所在轨道；字幕段批量到同轨字幕段、文本段批量到同轨文本段（**kind 严格隔离**）
- **覆盖字段**：12 个样式字段全集（与 [text-style-fidelity-spec.md](text-style-fidelity-spec.md) §4 字段映射表对齐）
- **二次确认**：弹窗显示「将影响 N 个片段，操作可撤销」，确认后单条 undo entry
- **不覆盖**：text 内容 / segment 时长 / segment 位置 / 字幕 position 字段（避免误覆盖位置）

详见 [bulk-style-apply-spec.md](bulk-style-apply-spec.md) §2。

---

## 四、多轨道左右双栏滚动同步

### 4.1 各家做法

| 产品 | 实现 | 行高对齐 |
|---|---|---|
| **剪映 iOS** | 左侧轨道头与右侧编辑区**共用同一垂直 ScrollView**，水平 ScrollView 是内层；横竖滚动自然解耦 | 行高常量 = 共享布局 → 0 错位 |
| **CapCut Desktop** | 同剪映 | 0 错位 |
| **FCP（macOS）** | 两个独立 NSScrollView，通过 `scrollView.contentView` 的 NSNotification 同步 `boundsOrigin.y` | 0 错位 |
| **LumaFusion** | 同剪映 | 0 错位 |

### 4.2 v3 现状（实锤）

- `TrackLabelsView`（[ClipEditorViewController.swift:394](../../Sources/TimelineKit/Views/ClipEditorViewController.swift)）：固定左栏，width=52，frame 布局，**不是 ScrollView**
- 主 `scrollView`（[ClipEditorViewController.swift:141](../../Sources/TimelineKit/Views/ClipEditorViewController.swift)）：`alwaysBounceHorizontal = true`，**纵向不滚动**（contentSize.height 与可视高度对齐）
- 行高常量：`TrackCanvasView.trackHeight = 40`，`trackSpacing = 3`，`rulerHeight = 36`
- 多轨时轨道数超过约 5~6 条 → 下方轨道既看不到也选不到

### 4.3 v4 定案

**方案 A（推荐采纳）：保留两栏分离结构，主 `scrollView` 开启纵向滚动 + `scrollViewDidScroll(_:)` 把 `contentOffset.y` 转发给 `TrackLabelsView` 的子视图变换。**

理由：

- 改动局限于 `ClipEditorViewController.setupScrollView` + `scrollViewDidScroll` + `TrackLabelsView` 内部一个 `transform` 属性，零侵入式
- 不破坏 v3 多轨 + 横向 pinch zoom + trim handle 手势的现有耦合
- 与 FCP macOS 实现模型一致（更专业、风险已知）

方案 B（**未采纳**）：把两栏放进同一个外层垂直 ScrollView，水平滚动留在内层。理由：内外 ScrollView 嵌套对 pinch zoom + pan 手势的传递链改动太大，回归风险高。

详见 [multi-track-scroll-spec.md](multi-track-scroll-spec.md) §2。

---

## 五、文本对齐 / 智能换行 / 复制粘贴 / 层级

### 5.1 文本对齐

| 产品 | 选项 | UI |
|---|---|---|
| **剪映 iOS** | 左 / 中 / 右 三按钮 | 文本编辑「样式」Tab 内独立段落 |
| **CapCut Desktop** | 左 / 中 / 右 / 两端对齐 四选项 | Inspector dropdown |
| **FCP** | 左 / 中 / 右 / 两端对齐 四选项 | Inspector |
| **LumaFusion** | 左 / 中 / 右 三选项 | Inspector |

**v4 定案**：与剪映一致——`leading / center / trailing` 三选项；不做两端对齐（中文场景需求弱）。详见 [text-typography-spec.md](text-typography-spec.md) §2。

### 5.2 智能换行边界

| 场景 | 剪映 | CapCut | FCP |
|---|---|---|---|
| 中英文混排 | ✅ 中文按字 / 英文按词 | ✅ | ✅ |
| Emoji 完整渲染（不被截断）| ✅ | ✅ | ✅ |
| 标点禁则（标点不出现在行首）| ✅ | ✅ | ✅ |

**v4 定案**：沿用 V3 字幕单行最大字符数现有逻辑，补完善上述三类边界。详见 [text-typography-spec.md](text-typography-spec.md) §3。

### 5.3 复制 / 粘贴样式

| 产品 | 剪贴板 | kind 隔离 |
|---|---|---|
| **剪映 iOS** | in-memory 应用内剪贴板（不污染系统剪贴板）| 是（字幕样式不能粘贴到普通文本，反之亦然）|
| **CapCut Desktop** | 同上 | 是 |
| **FCP** | 系统 Edit → Copy / Paste Attributes 链路 | 否（FCP 字幕/文本是一类）|
| **LumaFusion** | in-memory | 是 |

**v4 定案**：取剪映模型——in-memory 剪贴板 + kind 隔离。详见 [text-typography-spec.md](text-typography-spec.md) §4。

### 5.4 层级置顶 / 置底 / 上移 / 下移

| 产品 | 入口 | 数据模型 |
|---|---|---|
| **剪映 iOS** | 选中文本/字幕 → 二级菜单「层级」→ 四按钮（置顶 / 置底 / 上移 / 下移）| 每段独立 zPosition 整数 |
| **CapCut Desktop** | 右键 → Bring to Front / Send to Back / Bring Forward / Send Backward | 同上 |
| **FCP** | Connected clip 自动按 attach 顺序堆叠；Arrange → Lift / Lower | 顺序数组 |
| **LumaFusion** | Inspector → Layer Order | 整数 |

**v4 定案**：取剪映按钮模型；新增 `EditorSegment.userZOrder: Int?`，渲染端按 `(userZOrder ?? 0, sortIndex)` 复合排序。详见 [text-typography-spec.md](text-typography-spec.md) §5。

---

## 六、音频淡入 / 淡出

### 6.1 各家做法

| 产品 | UI | 实现 |
|---|---|---|
| **剪映 iOS** | 音频编辑「淡化」二级面板 → 两个滑杆（0~5s）| ramp keyframe |
| **CapCut Desktop** | Inspector 双滑杆 + 时间线段端 fade handle 拖拽 | ramp + handle |
| **FCP** | 时间线段端 fade handle 拖拽 + Inspector 数值 | ramp |
| **LumaFusion** | Inspector 双滑杆 | ramp |

### 6.2 v3 现状

- `AudioContent.fadeInDuration / fadeOutDuration`（[SegmentContent.swift:170-171](../../Sources/TimelineKit/Models/SegmentContent.swift)）：✅ 字段已在，Codable 已读写
- `CompositionBuilder` 音频 mix（[CompositionBuilder.swift:664-738](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift)）：仅 `setVolume(_:at:)` keyframe，**未调 `setVolumeRamp`** → fade 字段是死字段
- `AudioEditPanel`：无淡入淡出 UI

### 6.3 v4 定案

**取剪映「Inspector 双滑杆」模型（暂不做时间线 fade handle 拖拽，留后续迭代）**：

- UI：`AudioEditPanel` 新增「淡入」「淡出」两个滑杆，范围 `0...min(2.0, segment.duration/2)` 秒
- 渲染：`CompositionBuilder` 在 `setVolume(_:at:)` 基础上叠加 `setVolumeRamp`：
  - fade in：`setVolumeRamp(fromStartVolume:0, toEndVolume:volume, timeRange:[segStart, segStart+fadeIn])`
  - fade out：`setVolumeRamp(fromStartVolume:volume, toEndVolume:0, timeRange:[segEnd-fadeOut, segEnd])`
  - isMuted 时仍硬 `setVolume(0, at:.zero)` 优先，ramp 不生效

详见 [audio-track-controls-spec.md](audio-track-controls-spec.md) §2。

---

## 七、轨道静音 / 锁定 / 隐藏

### 7.1 各家做法

| 产品 | 静音 | 锁定 | 隐藏 |
|---|---|---|---|
| **剪映 iOS** | 喇叭图标，点击切换；导出生效 | 锁图标，点击切换；锁定后该轨拒绝任何编辑手势 | 眼睛图标；隐藏后预览 + 导出均不显示 |
| **CapCut Desktop** | 同剪映 | 同 | 同 |
| **FCP（角色 Roles）** | Roles 单独开关静音 | Roles 锁定 | Roles 隐藏（仅编辑期，导出仍渲染）|
| **LumaFusion** | 轨道头图标 | 图标 | 图标 |

### 7.2 v3 现状

- `EditorTrack.isMuted / isLocked / isHidden`（[EditorTrack.swift:9-11](../../Sources/TimelineKit/Models/EditorTrack.swift)）：✅ 字段都在
- `isMuted`：✅ **已全链路接入**——`CompositionBuilder` 音频 mix 在 isMuted 时 `setVolume(0, at:.zero)`（[CompositionBuilder.swift:725-726](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift)）；`EditorStore.muteTrack` 已 undo 跟踪
- `isLocked`：❌ 字段存在，但 canvas 手势端无任何 check
- `isHidden`：❌ 字段存在，但渲染端无任何 check

### 7.3 v4 定案

**取剪映语义（移动端用户最直觉，与编辑期视觉一致）**：

| 标志 | 编辑期 | 导出 |
|---|---|---|
| `isMuted` | 音频段静音 | 不输出该轨音频（v3 已是此行为）|
| `isLocked` | 该轨所有段拒绝长按 / drag / trim handle；图标显示锁 | 不影响（锁定仅是编辑期保护）|
| `isHidden` | 预览端字幕 / 文本 / 视频叠加层不绘制；图标显示眼睛斜线 | **导出不渲染**（音频静音、视频叠加层 skip、字幕文本 skip） |

UI：`TrackLabelsView` 每行右侧增加三图标（静音 / 锁 / 隐藏，点击切换）。

详见 [audio-track-controls-spec.md](audio-track-controls-spec.md) §3。

---

## 八、磁吸精度补强（音频 fade handle）

V3 音频片段拖拽磁吸已上线（[docs/v3/audio-feature-spec.md](../v3/audio-feature-spec.md)）；V4 仅在新增的 fade handle 拖拽场景下补磁吸反馈：

- fade-in handle 拖到段首 → 磁吸 0（无 fade）
- fade-out handle 拖到段尾 → 磁吸 0
- fade 长度拖到段长一半（fadeIn + fadeOut ≥ duration）→ 磁吸到段长 / 2 上限
- 复用 v3 磁吸触觉反馈 `UIImpactFeedbackGenerator(style: .light)`

不重写 v3 磁吸阈值与吸附帧规则。详见 [audio-track-controls-spec.md](audio-track-controls-spec.md) §4。

---

## 九、能力点 × 产品对照汇总

| 能力点 | 剪映 iOS | CapCut Desktop | FCP | LumaFusion | **V4 定案** |
|---|---|---|---|---|---|
| 12 字段预览实时刷新 | ✅ | ✅ | ✅ | ✅ | ✅ 与剪映对齐 |
| 6 预设点击应用 | ✅ | ✅ | N/A | ✅ | ✅ 与剪映对齐 |
| 同轨同类批量样式 | ✅（有确认）| 🟡 多选 | 🟡 多选 | 🟡 单段 | ✅ 取剪映 + FCP 确认 |
| 双栏纵向同步滚动 | ✅ 共享 ScrollView | ✅ | ✅ delegate 同步 | ✅ | ✅ 取 FCP 同步模型（方案 A）|
| 文本对齐 | 左/中/右 | 左/中/右/两端 | 左/中/右/两端 | 左/中/右 | 左/中/右 |
| 智能换行 | ✅ | ✅ | ✅ | 🟡 | ✅ 与剪映对齐 |
| 复制粘贴样式 | ✅ in-memory | ✅ | ✅ Paste Attrs | ✅ | ✅ 取剪映 + kind 隔离 |
| 层级置顶置底 | ✅ 四按钮 | ✅ 右键 | 🟡 lift/lower | ✅ | ✅ 取剪映按钮 |
| 音频淡入淡出 | ✅ 双滑杆 | ✅ 双滑杆 + handle | ✅ handle | ✅ 双滑杆 | ✅ 取剪映双滑杆（handle 留后续）|
| 轨道静音 | ✅ | ✅ | ✅ | ✅ | ✅ v3 已实现 |
| 轨道锁定 | ✅ | ✅ | ✅ | ✅ | ✅ 取剪映 |
| 轨道隐藏（导出语义）| 不导出 | 不导出 | 仍导出 | 不导出 | **不导出**（剪映语义）|

---

## 十、未对标项 / 后续 roadmap

以下能力本期不对标定案，留 V4 P0/P1 上线后再单独 spec：

- 视频定格画面（freeze frame）：剪映 / CapCut 都有「定格」按钮，需要静帧渲染管线扩展
- 文本入场动画（渐入 / 缩放弹出 / 平移出现）：剪映 / CapCut 有 30+ 动画预设，本期 v1 enterAnimation 字段已在，仅需补 UI；但 P1 容量不足
- 工程模板（保存 / 一键复用）：剪映「剪辑模板」深度功能，需要 DraftStore 扩展 + 模板素材依赖

这些项目在 [V4-initiation.md](V4-initiation.md) §2.3 roadmap 段已声明，本期不写 spec。

---

## 十一、引用关系

本文档被以下 5 份 spec 引用，作为规则定案的唯一权威：

- [text-style-fidelity-spec.md](text-style-fidelity-spec.md) §1（预览刷新策略 §1）、§3（预设接线 §2）
- [bulk-style-apply-spec.md](bulk-style-apply-spec.md) §1（批量应用 §3）
- [multi-track-scroll-spec.md](multi-track-scroll-spec.md) §1（双栏同步 §4）
- [text-typography-spec.md](text-typography-spec.md) §1（对齐 / 换行 / 复制粘贴 / 层级 §5）
- [audio-track-controls-spec.md](audio-track-controls-spec.md) §1（音频 fade §6 / 轨道控制 §7 / 磁吸 §8）

如本文档与各 spec 出现冲突，**以本文档为准**；后续修订应同步刷新各 spec 引用段落。
