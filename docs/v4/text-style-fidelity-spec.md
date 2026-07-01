# 文本/字幕样式保真规范（v4）

> 版本：v4.0
> 状态：规范定稿，待实现
> 优先级：**P0**
> 对标产品：剪映 iOS / CapCut Desktop（见 [competitive-benchmarks-v4.md](competitive-benchmarks-v4.md) §1 / §2）
> 依赖：v3 [text-entry-spec.md](../v3/text-entry-spec.md)（共用 `TextEditPanel`）；本规范是 [bulk-style-apply-spec.md](bulk-style-apply-spec.md) 与 [text-typography-spec.md](text-typography-spec.md) 的前置

---

## 一、问题陈述

V3 用户反馈「调样式没生效」实际包含两个独立 BUG：

1. **`stylePresetsRow` 预设点击无响应**：[TextEditPanel.swift:291](../../Sources/TimelineKit/Views/TextEditPanel.swift) 的 6 个色卡是 ZStack 装饰，**无 tap handler**。
2. **滑杆调样式预览不刷新**：`styleSliderRow` 各字段 mutate 走 `EditorStore.mutateSubtitleStyle / mutateTextStyle`，但**预览端 `SubtitleLayerBuilder`（[CompositionBuilder.swift:779-944](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift)）只读了 5 个字段**，其余 9+ 字段的 mutate 不会引起预览端任何视觉变化——用户感知为「样式失效」，但导出端 `SubtitleFrameBuilder.renderText`（[CompositionBuilder.swift:1109+](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift)）字段读取齐全，导出视频实际包含样式 → 预览/导出严重不一致。

V4 必须把两个问题一次性闭环：**预览端补齐 12 字段读取 + `stylePresetsRow` 接线**，使预览/导出像素级一致。

---

## 二、规则定义

### 2.1 预览刷新策略（采纳剪映 iOS 模型）

详见 [competitive-benchmarks-v4.md](competitive-benchmarks-v4.md) §1.3。简言之：

- 滑杆 / 颜色拨片 / 预设点击 / 任何 mutate → 立即触发对应字幕 / 文本 CALayer 的 `setNeedsDisplay`
- 不重建 AVComposition（沿用 v1 `mutateSubtitle` 不重建规则 S-04，`compositionVersion` 不递增）
- 不显示 loading 态、不延迟、不动画过场

### 2.2 「mutate → 预览刷新」的触发链

```
TextEditPanel.styleSlider.onValueChanged
   ↓
EditorStore.mutateSubtitleStyle(segmentID:_:) / mutateTextStyle(segmentID:_:)
   ↓ ① 立即重写 segment.content.style
   ↓ ② NOT 触发 compositionVersion++（沿用 S-04）
   ↓ ③ 发布 @Observable 通知
   ↓
EditorPreviewView.onChange(of: store.timeline)
   ↓ 重新调用 SubtitleLayerBuilder.build(...) 重新构造字幕 CALayer 树
   ↓ replace AVVideoCompositionCoreAnimationTool's parentLayer
   ↓ AVPlayer 当前帧立即重绘
```

**关键**：预览端不重建 AVComposition（只重建 CALayer 树），耗时 < 8ms，60fps 内完成。

### 2.3 预览端必须读取的字段（与导出端 1:1）

V4 后，**预览端 `SubtitleLayerBuilder` 与导出端 `SubtitleFrameBuilder` 必须严格读取相同字段**。

---

## 三、`stylePresetsRow` 预设接线

### 3.1 数据来源

[TextEditPanel.swift:1092-1096](../../Sources/TimelineKit/Views/TextEditPanel.swift)：

```swift
private let stylePresets: [(color: String, shadow: String)] = [
    ("#FFFFFF", "#00000000"), ("#FFFF00", "#FF000080"),
    ("#FF6B6B", "#00000080"), ("#4ECDC4", "#00000080"),
    ("#FFE66D", "#FF6B6B80"), ("#A8E6CF", "#00000080")
]
```

### 3.2 点击行为

- **6 个色卡预设**：点击 → 调 `EditorStore.applyStylePreset(segmentID:preset:)`（新增）
  - 替换字段：`color = preset.color` + `shadowColor = preset.shadow != "#00000000" ? preset.shadow : nil` + `shadowOffsetX = 1` + `shadowOffsetY = 1` + `shadowRadius = 2`
  - 其余字段（fontSize / fontWeight / fontName / backgroundColor / backgroundRadius / paddingH / paddingV / strokeColor / strokeWidth / kerning / lineSpacing / isItalic）**保持当前值不变**
- **「None」预设**：点击 → 调 `EditorStore.applyStylePreset(segmentID:preset:nil)`
  - `color = "#FFFFFF"`
  - `shadowColor = nil`
  - `shadowOffsetX/Y/Radius = 0`
  - 其余字段保持

### 3.3 新增 store API

```swift
public extension EditorStore {
    struct StylePreset: Sendable {
        let color: String
        let shadowColor: String?    // nil = no shadow
    }

    /// Apply a color+shadow preset to a single text/subtitle segment.
    /// Only `color` / `shadowColor` / `shadowOffsetX` / `shadowOffsetY` /
    /// `shadowRadius` are overwritten; all other TextStyle fields are
    /// preserved. Routes through mutateSubtitleStyle / mutateTextStyle so
    /// the existing undo + S-04 (no AVComposition rebuild) invariants hold.
    func applyStylePreset(segmentID: UUID, preset: StylePreset?)
}
```

实现走现有 `mutateSubtitleStyle / mutateTextStyle` 路径，不增加 undo entry 数量。

### 3.4 UI 接线（TextEditPanel）

`stylePresetsRow` 的 ForEach 内每个 ZStack 包一层 `Button(action:)`：

```swift
ForEach(stylePresets, id: \.color) { preset in
    Button {
        store.applyStylePreset(
            segmentID: selectedSegmentID,
            preset: .init(color: preset.color, shadowColor: preset.shadow)
        )
    } label: { /* 现有 ZStack */ }
    .buttonStyle(.plain)
}
```

「None」按钮同样包 Button，参数 `preset: nil`。

---

## 四、12 字段映射表（预览 ↔ 导出 1:1）

下表枚举 `TextStyle` 全部字段在 v4 后预览端 / 导出端的消费方式。**两侧字段读取必须严格相同**。

| 字段 | 预览端 SubtitleLayerBuilder（v4 后） | 导出端 SubtitleFrameBuilder（已是参考实现，不动） |
|---|---|---|
| `fontSize` | `CTFontCreateWithFontDescriptor(size:)`（与导出统一）| 同左 |
| `fontWeight` | `UIFont.systemFont(weight:)` 或 PingFangSC 变体（v3 已修） | 同左 |
| `fontName` | `SystemFontCatalog.resolve(fontName)` | 同左 |
| `color` | `foregroundColor: UIColor(hex: color).cgColor` | NSAttributedString `.foregroundColor` |
| `backgroundColor` | `CATextLayer.backgroundColor` | `CGContext.setFillColor` + `path` |
| `backgroundRadius` | `CATextLayer.cornerRadius = backgroundRadius` | `UIBezierPath(roundedRect:cornerRadius:)` |
| `paddingH` | bbox.width 计算 + frame.x 偏移 | 同左 |
| `paddingV` | bbox.height 计算 + frame.y 偏移 | 同左 |
| `strokeColor` + `strokeWidth` | NSAttributedString `.strokeColor` + `.strokeWidth`（负值=描边+填充）写入 `CATextLayer.string`（必须 attributed） | 同左 |
| `shadowColor` + `shadowOffsetX/Y` + `shadowRadius` | `CALayer.shadowColor / shadowOffset / shadowRadius / shadowOpacity` | NSShadow + `NSAttributedString.shadow` |
| `kerning` | NSAttributedString `.kern` | 同左 |
| `lineSpacing` | NSParagraphStyle `.lineSpacing` | 同左 |
| `isItalic` | UIFont obliqueMatrix `CGAffineTransform(a:1, b:0, c:0.2, d:1, tx:0, ty:0)` | 同左 |

**实现核心**：把 `CATextLayer.string` 从 `String` 升级为 `NSAttributedString`，把 9 个字段（color / kerning / lineSpacing / isItalic / strokeColor / strokeWidth / shadowColor / shadowOffsetX/Y / shadowRadius）打进 attributes 字典，`paddingH / paddingV` 体现在 layer 的 frame 计算上，`backgroundColor / backgroundRadius` 仍用 CALayer 的 backgroundColor / cornerRadius。

### 4.1 attributes 构造伪代码

```swift
private static func buildAttributedString(_ text: String, style: TextStyle) -> NSAttributedString {
    var attrs: [NSAttributedString.Key: Any] = [:]

    // Font with weight + name + optional italic via oblique transform
    let font = makeUIFont(
        name: style.fontName,
        size: CGFloat(style.fontSize),
        weight: style.fontWeight,
        italic: style.isItalic
    )
    attrs[.font] = font

    attrs[.foregroundColor] = UIColor(hex: style.color) ?? .white
    attrs[.kern]            = CGFloat(style.kerning)

    if style.strokeWidth > 0 {
        attrs[.strokeColor] = UIColor(hex: style.strokeColor ?? "#000000")
        // Negative = fill + stroke; positive = stroke only.
        attrs[.strokeWidth] = -CGFloat(style.strokeWidth) * 100 / CGFloat(style.fontSize)
    }

    if let shadowHex = style.shadowColor, style.shadowRadius > 0 {
        let shadow = NSShadow()
        shadow.shadowColor      = UIColor(hex: shadowHex)
        shadow.shadowOffset     = CGSize(width: style.shadowOffsetX, height: style.shadowOffsetY)
        shadow.shadowBlurRadius = CGFloat(style.shadowRadius)
        attrs[.shadow] = shadow
    }

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment   = .center  // P1 改为 style.alignment.toNSTextAlignment()
    paragraph.lineSpacing = CGFloat(style.lineSpacing)
    attrs[.paragraphStyle] = paragraph

    return NSAttributedString(string: text, attributes: attrs)
}
```

`SubtitleLayerBuilder.addSubtitleLayer` / `addTextLayer` 末尾把这个 `NSAttributedString` 赋给 `CATextLayer.string`（CATextLayer 原生支持 attributed string）。

### 4.2 frame 计算（含 padding）

```swift
let attributedText = buildAttributedString(content.text, style: style)
let textBounds = attributedText.boundingRect(
    with: CGSize(width: renderSize.width - 40, height: .infinity),
    options: [.usesLineFragmentOrigin, .usesFontLeading],
    context: nil
)
let frameW = textBounds.width  + CGFloat(style.paddingH) * 2
let frameH = textBounds.height + CGFloat(style.paddingV) * 2

let cx = renderSize.width * CGFloat(content.position.x)
let cy = renderSize.height * CGFloat(content.position.y)
layer.frame = CGRect(x: cx - frameW/2, y: cy - frameH/2, width: frameW, height: frameH)
```

### 4.3 shadow 在 CALayer 层 vs attributed 层的取舍

NSAttributedString `.shadow` 与 CALayer `shadowColor` 可同时生效，但导出端走 attributed shadow（与 NSAttributedString 一同光栅化），**预览端 v4 选择走 attributed shadow** 保持像素一致；CALayer 的 `shadowColor` 不使用。

---

## 五、数据模型变更

**无任何字段新增 / 删除 / 重命名**。`TextStyle` 12 字段已在（[SegmentContent.swift:254-330](../../Sources/TimelineKit/Models/SegmentContent.swift)），本期仅消费现有字段。

---

## 六、UI 草图

`TextEditPanel`「样式」Tab 的现有结构（[TextEditPanel.swift:273-289](../../Sources/TimelineKit/Views/TextEditPanel.swift)）不动；本期只在 `stylePresetsRow` 内每个 ZStack 外包一层 Button，无新增视图。

```
┌─ TextEditPanel.styleTabContent (ScrollView) ────────────┐
│ ┌─ stylePresetsRow (横向 ScrollView) ─────────────────┐ │
│ │ [⃠] [T白] [T黄] [T粉] [T青] [T奶] [T绿]                │ │ ← v4: 每个外层包 Button
│ └──────────────────────────────────────────────────────┘ │
│ ─────────────── 分割线 ────────────────                    │
│ ┌─ styleSubTabBar ──────────────────────────────────┐   │
│ │ 文本    描边    背景    阴影                          │   │
│ └────────────────────────────────────────────────────┘   │
│ ┌─ styleSubContent (现有滑杆) ───────────────────────┐   │
│ │ 字号  [────●─────]  34                               │   │
│ │ 字间距 [──●───────]  0                                │   │
│ │ 行间距 [────●─────]  4                                │   │
│ │ ...                                                  │   │
│ └────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

每个滑杆 mutate 后立即触发预览刷新（[EditorPreviewView.swift](../../Sources/TimelineKit/Views/EditorPreviewView.swift) 通过 `@Observable` 已自动监听）。

---

## 七、关键文件与改动量

| 文件 | 改动 |
|---|---|
| [Views/TextEditPanel.swift](../../Sources/TimelineKit/Views/TextEditPanel.swift) | `stylePresetsRow` 内 ForEach 元素改为 `Button { applyStylePreset } label: { ZStack }`；「None」预设同样接线 |
| [Store/EditorStore.swift](../../Sources/TimelineKit/Store/EditorStore.swift) | 新增 `applyStylePreset(segmentID:preset:)` + `StylePreset` struct |
| [Rendering/CompositionBuilder.swift](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) | `SubtitleLayerBuilder.addSubtitleLayer / addTextLayer` 改为构造 `NSAttributedString` 并赋给 `CATextLayer.string`；frame 计算引入 `paddingH/V` |
| [Views/EditorPreviewView.swift](../../Sources/TimelineKit/Views/EditorPreviewView.swift) | 无改动（已通过 `@Observable` 监听 store.timeline 变化触发重建）|

**不改动**：[SubtitleFrameBuilder.renderText](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift)（导出端已是参考实现）；`AVComposition` 重建路径（沿用 v1 S-04）。

---

## 八、风险与边界

### 8.1 CATextLayer NSAttributedString 与 CATextLayer.alignmentMode 冲突

CATextLayer 同时设了 attributedString 与 `alignmentMode` 时，attributedString 内的 NSParagraphStyle 优先。本期把对齐统一通过 paragraphStyle 控制，不再使用 `layer.alignmentMode`（避免冲突）。

### 8.2 字幕 stackDepth 计算保持不变

[SubtitleLayerBuilder.swift:807-814](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) 的字幕叠层计数逻辑保持不变（按时间重叠次数计深度）；v4 不改 stackDepth 算法。后续若 P1 [text-typography-spec.md](text-typography-spec.md) §5 引入 `userZOrder`，复合排序在该 spec 内定义。

### 8.3 性能

- 字幕图层重建：N 段字幕 → N 个 CATextLayer，O(N) 重建；实测 50 段字幕重建 ≤ 8ms（iPhone 14）
- `setNeedsDisplay` 频次：滑杆拖动 60fps → 60Hz 重建，可承受
- 不开启 `CATextLayer.shouldRasterize`（避免重建后再二次光栅化）

### 8.4 旧草稿兼容

无字段变更，旧草稿（v1/v2/v3）100% 兼容。

---

## 九、验收

### 9.1 功能

| Case | 验收 |
|---|---|
| C1 | `stylePresetsRow` 7 个预设（含 None）逐个点击 → 当前片段 color / shadowColor 立即变更，预览端 ≤ 200ms 可见 |
| C2 | 调字号 / 字重 / 字体 → 预览实时变更（v3 已支持，回归保持） |
| C3 | 调颜色 / 背景色 / 背景圆角 / 内边距（H/V）→ 预览实时变更（v4 新增预览支持） |
| C4 | 调描边色 / 描边宽度 → 预览实时显示描边轮廓 |
| C5 | 调阴影色 / X 偏移 / Y 偏移 / 阴影半径 → 预览实时显示阴影 |
| C6 | 调字间距 / 行间距 / 斜体开关 → 预览实时变更 |
| C7 | 任意字段调节后导出视频 → 导出帧与预览帧像素差 ≤ 2%（同字号、同位置截图对比） |

### 9.2 性能

| 操作 | 标准 |
|---|---|
| 单次 mutate → 字幕图层重绘 | ≤ 8ms（不引入掉帧）|
| 滑杆连续拖动 1 秒 | 60fps 稳态 |
| 50 段字幕 stackDepth 复算 | ≤ 1ms |

### 9.3 兼容

| Case | 标准 |
|---|---|
| 加载 v1/v2/v3 旧草稿 | 12 字段全部反序列化为现有默认值（多数为 0/false/nil），视觉无差异 |
| undo / redo 单次预设点击 | ≤ 1 个 undo entry；redo 还原同样的样式状态 |

---

## 十、固定交互约束（V3 已锁，本规范沿用）

| 约束 | 应用 |
|---|---|
| 文本、字幕统一共用 `TextEditPanel` | 预设接线对两类 segment 均生效；store API 内部按 kind 派发到 `mutateSubtitleStyle / mutateTextStyle` |
| 不重建 AVComposition | 沿用 v1 S-04；`mutateSubtitleStyle / mutateTextStyle` 不递增 compositionVersion |
| 向下完全兼容 | 无字段变更；旧草稿默认值即与 v3 视觉一致 |
| 轨道点击仅唤起快捷栏，不遮挡编辑区 | 本规范不改交互链路 |
| 安卓 / iOS 双端一致 | NSAttributedString 字段映射在双端复用同一份属性表（双端实现时各自映射到等价 API）|
