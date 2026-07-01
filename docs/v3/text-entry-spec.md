# 手动文本入口与编辑面板规范（v3）

> 版本：v3.0
> 状态：规范定稿，待实现
> 对标产品：剪映 iOS（主要）+ Final Cut Pro
> 依赖：[multi-track-architecture-spec.md](multi-track-architecture-spec.md)（轨道分配）；v1 [TextEditPanel](../../Sources/TimelineKit/Views/TextEditPanel.swift)（已存在的文本面板）；v1 [SubtitleEditPanel](../../Sources/TimelineKit/Views/SubtitleEditPanel.swift)（字幕编辑面板，本规范不改）

---

## 一、立项背景与现状

TimelineKit 当前的「字幕」与「文本」边界完全混淆：

- `SegmentContent` 中 `.text(TextContent)` 与 `.subtitle(SubtitleContent)` 已是独立 case（[SegmentContent.swift:8-9](../../Sources/TimelineKit/Models/SegmentContent.swift)），数据模型层无问题
- 但**用户没有任何 UI 入口创建 `.text` 片段**：底部工具栏 `EditorToolCategory.text` 当前 `isEnabled = false`（[EditorBottomToolbar.swift:20-25](../../Sources/TimelineKit/Views/EditorBottomToolbar.swift)）
- 所有「文字」均来自服务端 STT 流程生成的 `.subtitle` 片段，用户无法手动加标题、备注、解说花字

v3 目标：**启用 `.text` 入口，与「字幕（自动生成）」严格区分，对标剪映「文字」面板的「新建文本」按钮**。

---

## 二、竞品分析

### 2.1 剪映 iOS「文字」一级菜单

| 二级入口 | 行为 |
|---|---|
| 新建文本 | 时间轴当前位置插入空文本片段，自动选中并弹编辑面板 |
| 文字模板 | 预设花字模板（云端） |
| 智能字幕 | 调用 STT 一键生成字幕 |
| 识别歌词 | 调用音乐识别生成歌词字幕 |
| 文字朗读 | 选中文本/字幕 → 调用 TTS 配音 |

**核心要点**：剪映「文字」与「字幕」在视觉上同属一个一级菜单，但在数据上严格区分——「新建文本」走 `.text` 数据通道，「智能字幕」走 `.subtitle` 数据通道，两者互不混合。

### 2.2 Final Cut Pro

- 「Titles」侧边栏：所有文本类资源（字幕 / 标题 / 下三分之一图）
- 字幕用专属 `Caption` 类型（与本项目 `.subtitle` 对应）
- 标题与下三分之一图统称 `Title`（与本项目 `.text` 对应）

FCP 与本项目数据划分基本一致：`Caption` ↔ `.subtitle`、`Title` ↔ `.text`。

### 2.3 定案

| 维度 | 剪映 | FCP | **本规范定案** |
|---|---|---|---|
| 一级菜单合并？ | ✅「文字」一级菜单 | ❌ 分两个侧边栏 | **✅ 一级菜单合并，二级面板内功能区分** |
| 数据通道分离？ | ✅ `.text` vs `.subtitle` | ✅ Title vs Caption | **✅ `.text` vs `.subtitle` 严格分离** |
| 新建文本默认行为 | 插入空文本，自动弹面板 | 拖拽至时间轴 | **点击即创建，自动选中 + 弹 [TextEditPanel](../../Sources/TimelineKit/Views/TextEditPanel.swift)** |
| 文字朗读位置 | 文字面板 + 选中文本时 | N/A（用 Logic Pro）| **`TextEditPanel` 顶部 action 区**（见 [tts-spec.md](tts-spec.md)） |

> **定案依据**：剪映模型最贴合用户心智，且本项目数据模型已经按 `.text` / `.subtitle` 分离，UI 只需启用入口即可。

---

## 三、规则定义

### 3.1 启用 `.text` 工具类别

[EditorBottomToolbar.swift:20-25](../../Sources/TimelineKit/Views/EditorBottomToolbar.swift) 修改：

```swift
var isEnabled: Bool {
    switch self {
    case .clip,  .audio, .text, .transition, .adjust: return true
    case .sticker, .effects: return false  // V3 仍不做
    }
}
```

### 3.2 二级面板内容（`.text` 分类）

[EditorBottomToolbar.swift](../../Sources/TimelineKit/Views/EditorBottomToolbar.swift) `EditorSecondaryToolPanel.toolStubs(for:)` 的 `case .text:` 分支填入：

| 顺序 | 标题 | 图标 | enabled | 触发动作 |
|---|---|---|---|---|
| 1 | 新建文本 | `textformat` | ✅ | 调用 `store.createNewTextSegment()` |
| 2 | 文字模板 | `text.badge.star` | ❌（灰显）| 不触发，v3 不做 |
| 3 | 智能字幕 | `text.bubble` | ✅ | 跳转现有 STT 字幕生成流程 |
| 4 | 文字朗读 | `speaker.wave.2` | ✅（仅在选中 `.text` 或 `.subtitle` 段时启用）| 调用 TTS（见 [tts-spec.md §4](tts-spec.md)） |

### 3.3 「新建文本」点击行为

```
点击「新建文本」
  → 构造默认 TextContent
       text: "点击编辑文本"
       style: TextStyle(fontSize: 34, color: "#FFFFFF")
       position: .center
       anchor: .center
       enterAnimation/exitAnimation: nil
  → 构造 EditorSegment
       content: .text(TextContent(...))
       targetRange: TimeRange(start: playheadTime, duration: 3.0)
  → store.addSegmentAutoTrack(kind: .text, segment: newSegment)
       (自动分轨：无重叠则复用最近 .text 轨；重叠则新建一条)
  → store.selection.singleSelect(newSegment.id)
  → activeCategory 切换至 .text，二级面板替换为 TextEditPanel
```

默认时长 3.0 秒（对齐剪映）。

### 3.4 字幕 vs 文本严格隔离

| 维度 | 字幕（`.subtitle`）| 文本（`.text`）|
|---|---|---|
| 创建入口 | 「智能字幕」一键 STT；导入服务端 schema | 「新建文本」手动点击 |
| 轨道 kind | `.subtitle` | `.text` |
| 编辑面板 | [SubtitleEditPanel](../../Sources/TimelineKit/Views/SubtitleEditPanel.swift) | [TextEditPanel](../../Sources/TimelineKit/Views/TextEditPanel.swift) |
| 数据模型 | `SubtitleContent`（segments, style）| `TextContent`（text, style, position, anchor, animations）|
| 默认位置 | 底部居中（positionY 由 SubtitleStyle 控制）| 屏幕居中（NormalizedPoint.center）|
| 默认字号 | 由服务端 / 用户调节 | 34 pt |
| Mutate 入口 | `mutateSubtitleContent`（不重建 composition，S-04）| `mutateTextContent`（不重建 composition）|

**互不转换**：v3 不提供「字幕转文本」或「文本转字幕」操作。两条数据通道完全独立。

### 3.5 点击片段自动唤起规则

```
当 store.selection 单选片段变更时：
  if segment.content == .text(_) → activeCategory = .text，二级面板 = TextEditPanel
  if segment.content == .subtitle(_) → activeCategory = .text，二级面板 = SubtitleEditPanel
  if segment.content == .audio(_) → activeCategory = .audio，二级面板 = （后续音频编辑面板）
  if segment.content == .video(_) / .image(_) → activeCategory = .clip
```

`.text` 与 `.subtitle` 共用 `EditorToolCategory.text` 一级菜单，但二级面板**根据片段类型动态切换**（不依赖 activeCategory 子状态）。

### 3.6 TextEditPanel 现有能力（v3 不改样式编辑）

[TextEditPanel.swift](../../Sources/TimelineKit/Views/TextEditPanel.swift) 已存在以下能力，v3 全部保留：

- 文字内容输入栏（含展开 / 确认按钮）
- 字体（font）/ 样式（text/stroke/background/shadow）/ 花字（fancy，灰显）/ 模板（template，灰显）/ 动画（animation）五个 Tab
- 字号滑块（12-120 pt）
- 9 色调色板 + 取色器

### 3.7 TextEditPanel v3 新增内容

仅新增 **「文本朗读」action 按钮**，放在面板顶部右上角（与「确认」并列）：

```swift
// TextEditPanel 顶部 HStack 末尾
Button {
    Task { await TTSService.shared.regenerate(forSegment: editingSegmentID) }
} label: {
    HStack(spacing: 4) {
        Image(systemName: "speaker.wave.2")
        Text("朗读")
    }
}
.disabled(text.isEmpty)
```

具体交互见 [tts-spec.md §4](tts-spec.md)。

---

## 四、数据模型

### 4.1 无新增字段

`TextContent` / `SubtitleContent` 现有字段（[SegmentContent.swift:66-120](../../Sources/TimelineKit/Models/SegmentContent.swift)）完全够用。v3 不在此 spec 范围内修改任何模型。

### 4.2 EditorStore 新增 API

```swift
extension EditorStore {
    /// 在播放头位置新建一个手动文本片段，自动分轨并选中。
    /// - Returns: 新片段 ID
    @discardableResult
    public func createNewTextSegment(
        defaultText: String = "点击编辑文本",
        defaultDuration: Double = 3.0
    ) -> UUID
}
```

实现：

```swift
public func createNewTextSegment(...) -> UUID {
    let segment = EditorSegment(
        id: UUID(),
        materialID: nil,  // 文本无源素材
        targetRange: TimeRange(start: selection.playheadTime, duration: defaultDuration),
        sourceRange: nil,
        content: .text(.init(
            text: defaultText,
            style: .default,
            position: .center,
            anchor: .center
        ))
    )
    mutate("新建文本") { timeline in
        let trackID = ensureTrackForSegment(in: &timeline, kind: .text, segment: segment)
        timeline.tracks[index(of: trackID, in: timeline)].insert(segment)
    }
    selection.singleSelect(segment.id)
    return segment.id
}
```

其中 `ensureTrackForSegment` 是 [multi-track-architecture-spec §2.2](multi-track-architecture-spec.md) 自动分轨规则的内部实现。

---

## 五、UI 实现方案

### 5.1 EditorBottomToolbar 改造范围

| 文件 | 改造 |
|---|---|
| [EditorBottomToolbar.swift](../../Sources/TimelineKit/Views/EditorBottomToolbar.swift) | `isEnabled` 加 `.text`；`toolStubs(for:)` 加 `case .text:` 分支 |

### 5.2 ClipEditorView 选中切换逻辑

[ClipEditorView.swift](../../Sources/TimelineKit/Views/ClipEditorView.swift) 中现有 selection 变化监听点（v1 已存在 selection ↔ panel 切换骨架），v3 在该 onChange 闭包中扩展：

```swift
.onChange(of: store.selection.singleSelectedID) { _, newID in
    guard let id = newID,
          let segment = store.findSegment(id: id) else {
        activeCategory = nil
        return
    }
    switch segment.content {
    case .text:     activeCategory = .text  // 显示 TextEditPanel
    case .subtitle: activeCategory = .text  // 显示 SubtitleEditPanel（共用菜单）
    case .audio:    activeCategory = .audio
    case .video, .image: activeCategory = .clip
    }
}
```

`EditorSecondaryToolPanel` 内部根据 selection 实际 content 选择具体面板：

```swift
@ViewBuilder
private func dynamicPanel(for category: EditorToolCategory) -> some View {
    if let segID = store.selection.singleSelectedID,
       let seg = store.findSegment(id: segID) {
        switch seg.content {
        case .text:     TextEditPanel(store: store, segmentID: segID)
        case .subtitle: SubtitleEditPanel(store: store, segmentID: segID)
        default:        toolStubs(for: category)
        }
    } else {
        toolStubs(for: category)
    }
}
```

### 5.3 「新建文本」按钮位置

- 当未选中任何片段时：`.text` 二级面板展示 4 个 stub（新建文本 / 文字模板 / 智能字幕 / 文字朗读）
- 当选中 `.text` 片段时：替换为 `TextEditPanel`
- 当选中 `.subtitle` 片段时：替换为 `SubtitleEditPanel`

### 5.4 「智能字幕」入口

复用现有 STT 字幕生成路径（v1 已实装的服务端 STT 调用），仅在二级面板加一个 button 触发。具体实现细节不在本规范范围。

---

## 六、边界情况

| 情况 | 处理 |
|---|---|
| 用户在没有任何片段的空时间轴上点「新建文本」 | 允许，文本片段 targetRange.start = 0，timeline 长度自动撑到 3.0s |
| 当前播放头位置已被现有 `.text` 段占据 | 自动分轨规则触发，新建一条 `.text` 轨 |
| 用户在 TextEditPanel 中清空文字内容 | 允许保留空片段（与剪映一致），不自动删除 |
| 用户选中 `.subtitle` 片段时点击「新建文本」 | 行为不变：新建一个 `.text` 片段（不影响当前字幕选择） |
| 用户切换到 `.text` 一级菜单但当前选中 `.subtitle` 片段 | 二级面板显示 `SubtitleEditPanel`（基于片段类型，不依赖菜单子状态） |
| 「文字朗读」按钮在 `.text` 文字为空时 | 禁用 |
| v1 / v2 旧草稿无 `.text` 片段 | 完全兼容，新增手动文本不影响旧片段 |

---

## 七、验收标准

| # | 项目 | 标准 |
|---|---|---|
| TE-01 | `.text` 类别启用 | 底部工具栏出现「文字」入口 |
| TE-02 | 「新建文本」创建片段 | 点击后时间轴新增 1 个 3.0s `.text` 片段，自动选中 |
| TE-03 | 自动入轨 | 与现有 `.text` 段重叠时自动分到新轨；无重叠时复用最近一条 |
| TE-04 | 自动弹 TextEditPanel | 创建后二级面板 200ms 内切换到 TextEditPanel |
| TE-05 | 字幕 vs 文本隔离 | 「新建文本」不影响字幕轨；「智能字幕」不影响文本轨 |
| TE-06 | 选中字幕显示 SubtitleEditPanel | 单选 `.subtitle` 段时二级面板为 SubtitleEditPanel，与「新建文本」入口共存于 `.text` 菜单 |
| TE-07 | 选中视频/图片显示剪辑面板 | 单选 `.video` / `.image` 段时 activeCategory 自动切到 `.clip` |
| TE-08 | 旧草稿兼容 | v1 / v2 旧草稿打开后无报错，无 `.text` 片段也无问题 |
| TE-09 | 「朗读」按钮联动 | 选中文本/字幕段时朗读按钮可用，详见 [tts-spec.md](tts-spec.md) |
| TE-10 | 「文字模板」灰显 | 按钮 enabled = false，点击无反应 |

---

## 八、与 v1 / v2 接口约束

- **不修改** [TextEditPanel](../../Sources/TimelineKit/Views/TextEditPanel.swift) 现有样式编辑能力（font / style / animation 等保持原样），仅在顶部加「朗读」按钮
- **不修改** [SubtitleEditPanel](../../Sources/TimelineKit/Views/SubtitleEditPanel.swift) 任何代码
- **不修改** 服务端字幕导入流程（[TimelineImporter.swift:221-226](../../Sources/TimelineKit/Conversion/TimelineImporter.swift)）
- **不修改** v1 `mutateText` / `mutateSubtitle` 不重建 composition 规则
- 与 v2 [transition-spec](../v2/transition-spec.md) 无交集（文本 / 字幕轨道不支持转场）

---

## 九、字体选择（v3 完善 P1）

### 9.1 立项背景

v3 初版 TextEditPanel 字体 Tab 仅展示 5 张「字体卡片」但无任何切换逻辑，所有 `.text` 段都硬编 PingFangSC 渲染。装饰文字基本无字体可选，与剪映「字体」面板存在明显差距。本节为 `.text` 段（非字幕）补齐字体切换能力。

### 9.2 字体来源

**仅接系统字体白名单**（用户已确认）。不打包内置艺术字体，IPA 不增大。白名单：

| 显示名 | UIFont 家族 | 推荐场景 |
|---|---|---|
| 苹方（默认）| `PingFang SC` | 任何场景，最通用 |
| 宋体 | `Songti SC` | 书法/经典感 |
| 楷体 | `Kaiti SC` | 古风/手写感 |
| 圆体 | `Yuanti SC` | 卡通/可爱 |
| 手写 | `HanziPen SC` | 涂鸦/便签 |

`SystemFontCatalog`（实现细节）维护 family 名 → 各权重 PostScript 名的映射。

### 9.3 数据模型

`TextStyle` 新增可选字段：

```swift
public struct TextStyle: Sendable, Hashable, Codable {
    // ... existing fields ...
    /// UIFont family name (e.g. "PingFang SC", "Songti SC"). nil = default PingFang SC.
    public var fontName: String?
}
```

旧草稿无此字段反序列化为 `nil`，零迁移。

### 9.4 渲染规则

`SystemFontCatalog.resolvePostScript(family:weight:)` 由两处共同调用：

- [EditorPreviewView.textView](../../Sources/TimelineKit/Views/EditorPreviewView.swift)：`Font.custom(postScript, size: scaledFontSize)`
- [CompositionBuilder.makeCTFont](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) → `CTFontCreateWithName(postScript, fontSize, nil)`

字体未在系统中找到（如未来 family 名失效）时 fallback 到 PingFang SC，不报错。

### 9.5 UI 改造

`TextEditPanel.fontTabContent` 改造为可点击的字体卡片网格：
- 每张卡片显示「字体显示名 + 用该字体渲染的『A』预览」
- 当前选中样式：白色边框 + 浅色填充
- 点击调 `store.mutateTextStyle(segmentID:) { $0.fontName = family }`
- 取消选择（恢复默认）：点击「默认/苹方」卡片即可

### 9.6 验收（新增 TE-11）

| # | 项目 | 标准 |
|---|---|---|
| TE-11 | 字体切换 | 在 5 个系统字体间切换，预览实时变化；草稿往返保真；旧草稿（fontName=nil）渲染为 PingFang SC |
| TE-12 | 渲染一致 | SwiftUI 预览与 CATextLayer 导出对同一字体使用同一 PostScript 名 |

---

## 十、字号数值精准输入（v3 完善 P1）

### 10.1 现状

字号滑块（12-120pt）已可拖动调节，但用户无法精准输入特定值（如 88pt）。本节补充数值输入入口。

### 10.2 交互

`fontSizeRow` 顶部原本只显示数字 + 单位的 label 改为「点击弹出 TextField」：

```
"88 pt"  ← 点击切换为可编辑 TextField；输入后回车 / 失焦时 commit
```

- TextField 限定数字键盘（`.numberPad` + 自定义键盘工具栏「完成」按钮，因 numberPad 无 return key）
- 输入值 clamp 到 12...120
- commit 走 `store.mutateTextStyle(segmentID:) { $0.fontSize = clamped }`，与滑块共享同一通道

### 10.3 验收

| # | 项目 | 标准 |
|---|---|---|
| TE-13 | 数值字号输入 | 点击「88 pt」label → 弹键盘 → 输入 56 → 完成 → 字号变 56pt，滑块同步 |
| TE-14 | 越界 clamp | 输入 200 → commit 后字号被钳到 120pt |

---

## 十一、完整样式面板（v3 完善 P4）

### 11.1 立项背景

`TextEditPanel` 样式 Tab 内有 4 个子页面（文本 / 描边 / 背景 / 阴影），但 v3 P1 之前 3 个灰显，行/字间距/斜体也无入口。装饰文字与剪映对标缺口最大的就是这一块。本节按用户已确认的 4 项范围一次性补齐：底色 / 描边 / 阴影 / 行间距+字间距+斜体。

### 11.2 数据模型扩展（TextStyle）

[SegmentContent.swift](../../Sources/TimelineKit/Models/SegmentContent.swift) `TextStyle` 新增字段（全部 Optional/有默认值，旧草稿 0 迁移）：

```swift
public struct TextStyle: Sendable, Hashable, Codable {
    // 已有：fontSize, fontWeight, color, backgroundColor, backgroundRadius,
    //       paddingH, paddingV, fontName

    // 描边
    public var strokeColor: String?       // hex; nil = 无描边
    public var strokeWidth: Double        // 0...10 pt, 默认 0 = 不描边

    // 阴影
    public var shadowColor: String?       // hex; nil = 无阴影
    public var shadowOffsetX: Double      // -10...10 pt
    public var shadowOffsetY: Double      // -10...10 pt
    public var shadowRadius: Double       // 0...20 pt blur

    // 段落与字形
    public var kerning: Double            // -5...20 pt
    public var lineSpacing: Double        // 0...30 pt
    public var isItalic: Bool             // 斜体
}
```

> **设计取舍**：shadowOffset 拆成 X/Y 两个 Double 而非 SIMD2，理由是 Codable 自动合成更稳，UI 也好分两个滑块。

### 11.3 渲染规则

#### 11.3.1 SwiftUI 预览路径（[EditorPreviewView.TextOverlayView](../../Sources/TimelineKit/Views/EditorPreviewView.swift)）

```swift
Text(content.text)
    .font(.custom(postScript, size: scaledFontSize))
    .italic(style.isItalic)                                  // 斜体（系统字体无 Italic 变体时仅斜变）
    .kerning(style.kerning)                                  // 字间距
    .lineSpacing(style.lineSpacing)                          // 行间距
    .foregroundStyle(textColor)
    .padding(...)
    .background(bg)
    .shadow(color: shadowColor, radius: shadowRadius,        // 阴影
            x: shadowOffsetX, y: shadowOffsetY)
    // 描边：4 向无半径 shadow 模拟（SwiftUI Text 无原生 stroke API）
    .modifier(TextStrokeModifier(color: strokeColor, width: strokeWidth))
```

`TextStrokeModifier` 用 4 向 zero-radius shadow 在 8 个方向叠加来模拟描边：

```swift
struct TextStrokeModifier: ViewModifier {
    let color: Color?
    let width: CGFloat
    func body(content: Content) -> some View {
        guard let color, width > 0 else { return AnyView(content) }
        return AnyView(content
            .shadow(color: color, radius: 0, x:  width, y:  0)
            .shadow(color: color, radius: 0, x: -width, y:  0)
            .shadow(color: color, radius: 0, x:  0,     y:  width)
            .shadow(color: color, radius: 0, x:  0,     y: -width)
        )
    }
}
```

#### 11.3.2 CoreText 导出路径（[CompositionBuilder.renderText](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift)）

升级现有 NSAttributedString 构造，挂上额外 attributes：

| TextStyle 字段 | NSAttributedString.Key |
|---|---|
| strokeColor | `kCTStrokeColorAttributeName` |
| strokeWidth | `kCTStrokeWidthAttributeName`（负数 = fill+stroke） |
| kerning | `.kern` |
| lineSpacing | `NSParagraphStyle.lineSpacing` |
| isItalic | font descriptor 加 `.traitItalic`（系统字体无 italic 变体时退回正体） |

阴影：CATextLayer 原生属性 `shadowColor / shadowOffset / shadowRadius / shadowOpacity` 直接设。但因 renderText 当前是把文字烘焙到 CIImage 后再放进 composition，需在 CIImage 渲染前用 CGContext 设 `setShadow(offset:blur:color:)` 后再 drawCTText。

### 11.4 UI 改造（TextEditPanel）

[TextEditPanel.swift](../../Sources/TimelineKit/Views/TextEditPanel.swift) 三个原本 `placeholderContent` 的子页面解封：

| Tab | 子 Tab | 控件清单 |
|---|---|---|
| 样式 | 文本 | 颜色（已有）/ 字号（已有）/ 字重（已有）/ + **行间距滑块 0-30** / + **字间距滑块 -5...20** / + **斜体 Toggle** |
| 样式 | 描边 | 颜色选择器（含「无描边」按钮）/ 宽度滑块 0-10 |
| 样式 | 背景 | 颜色选择器（含「无背景」按钮）/ 圆角滑块 0-30 / 横向 padding 滑块 0-20 / 纵向 padding 滑块 0-20 |
| 样式 | 阴影 | 颜色选择器（含「无阴影」按钮）/ 横向偏移 -10..10 / 纵向偏移 -10..10 / 模糊半径 0-20 |

所有控件 commit 走 `store.mutateTextStyle(segmentID:) { $0.xxx = newValue }`。颜色选择器统一复用现有 9 色调色板 + 「无」按钮（点击置 nil）。

### 11.5 Store API

无新增。复用现有 `mutateTextStyle(segmentID:, label:, _:)`（v3 P1 已落地）。

### 11.6 与其他系统的关系

- **字体白名单 (§9)**：斜体依赖 fontName 当前变体是否支持 italic trait。中文字体大多无 italic 变体，渲染层会退回到正体（不报错）。spec UI 不提示「不支持」，由用户自行验证
- **草稿 (Codable)**：所有新字段 Optional 或有默认值，旧草稿反序列化无报错
- **导出（CATextLayer / CoreText）**：升级 NSAttributedString 后导出 mp4 字幕样式与预览保持视觉一致
- **字幕 SubtitleStyle**：本期**不动**字幕样式（spec 只覆盖 `.text`），SubtitleStyle 字段不扩展

### 11.7 验收（新增 TE-15 ~ TE-22）

| # | 项目 | 标准 |
|---|---|---|
| TE-15 | 底色填充 | 背景 Tab 选颜色 → 文字立即出现底色矩形；切回「无」清除；圆角/padding 滑块实时生效 |
| TE-16 | 描边宽度 | 描边 Tab 选黑色 + 宽度 4 → 文字呈现 4pt 黑色描边；宽度 0 = 无描边 |
| TE-17 | 阴影 | 阴影 Tab 设黑色 / 偏移 (4, 4) / 模糊 6 → 文字右下出现柔和阴影 |
| TE-18 | 字间距 | 字间距 +10 → 字符明显拉开 |
| TE-19 | 行间距 | 多行文本 + 行间距 +20 → 行间距明显拉开 |
| TE-20 | 斜体 | 斜体 Toggle 开 → 字符向右倾斜（中文系统字体可能退回正体，属预期） |
| TE-21 | 草稿往返 | 全部 8 个新字段持久化保真；旧草稿（字段缺失）反序列化为默认值 |
| TE-22 | 导出一致 | 设全套样式后导出 mp4，QuickTime 播放外观与预览一致（描边/阴影/段落） |
