# 文本排版与层级管理规范（v4）

> 版本：v4.0
> 状态：规范定稿，待实现
> 优先级：**P1**
> 对标产品：剪映 iOS（主对标）+ CapCut Desktop（按钮模型参考）
> 依赖：[text-style-fidelity-spec.md](text-style-fidelity-spec.md)（单段 mutate 链路 + attributedString 渲染）；v3 [text-entry-spec.md](../v3/text-entry-spec.md)（`TextEditPanel`）；[competitive-benchmarks-v4.md](competitive-benchmarks-v4.md) §5

---

## 一、覆盖范围

本规范一次性补齐 V4 P1 的 4 个文本编辑增强能力：

1. **文本对齐**（左 / 中 / 右）
2. **字幕智能换行边界完善**（中英文 / Emoji / 标点禁则）
3. **文本样式复制 / 粘贴**（in-memory 剪贴板 + kind 隔离）
4. **文本层级置顶 / 置底 / 上移 / 下移**

4 件功能共享 `TextEditPanel` 入口与 `EditorStore` mutate 链路，合并到同一份 spec 中维护以减少 spec 间引用噪音。

---

## 二、文本对齐

### 2.1 新增枚举

```swift
// Models/SegmentContent.swift
public enum TextAlignment: String, Sendable, Hashable, Codable, CaseIterable {
    case leading   = "leading"   // 左对齐
    case center    = "center"    // 居中（默认，与 v3 视觉一致）
    case trailing  = "trailing"  // 右对齐
}
```

### 2.2 `TextStyle.alignment` 字段

```swift
// TextStyle 新增字段（v4 §3）
public var alignment: TextAlignment = .center
```

Codable 走 `decodeIfPresent(... ?? .center)` 与现有字段同模式（[SegmentContent.swift:347-366](../../Sources/TimelineKit/Models/SegmentContent.swift)）。**旧草稿（v1/v2/v3）反序列化默认 `.center`，与现有视觉零差异。**

### 2.3 渲染端消费

- 预览端 [SubtitleLayerBuilder](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift)（[text-style-fidelity-spec.md §4](text-style-fidelity-spec.md) 引入的 attributedString 通路）：`NSParagraphStyle.alignment = style.alignment.toNSTextAlignment()`，替换硬编码 `.center`
- 导出端 [SubtitleFrameBuilder](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) `renderSubtitle` / `renderText`：同样替换硬编码 `.center`

```swift
// Models/SegmentContent.swift TextAlignment 扩展
public extension TextAlignment {
    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .leading:  return .left
        case .center:   return .center
        case .trailing: return .right
        }
    }
}
```

### 2.4 UI 入口

`TextEditPanel`「样式」Tab 顶部、`stylePresetsRow` 与 `styleSubTabBar` 之间，新增一行三按钮组：

```
┌─ TextEditPanel.styleTabContent ─────────────────────────┐
│ ┌─ stylePresetsRow ─────────────────────────────────┐  │
│ │ [⃠] [T白] [T黄] [T粉] [T青] [T奶] [T绿]                │  │
│ └────────────────────────────────────────────────────┘  │
│ ┌─ alignmentRow (v4 新增) ──────────────────────────┐  │
│ │  [⫷ 左对齐]   [☷ 居中]   [⫸ 右对齐]                    │  │ ← SF Symbols: text.alignleft/center/right
│ └────────────────────────────────────────────────────┘  │
│ ─────────────── 分割线 ────────────────                    │
│ ┌─ styleSubTabBar ──────────────────────────────────┐  │
│ │ 文本    描边    背景    阴影                          │  │
│ └────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

行为：

- 点击 → 调 `store.setTextAlignment(segmentID:_:)`（新增 API）
- 三按钮始终显示当前选中状态（高亮）

### 2.5 新增 store API

```swift
public extension EditorStore {
    func setTextAlignment(segmentID: UUID, alignment: TextAlignment)
}
```

实现走现有 `mutateSubtitleStyle / mutateTextStyle`，不递增 compositionVersion（S-04）。

---

## 三、字幕智能换行边界完善

### 3.1 当前 V3 现状

V3 字幕单行最大字符数（`SubtitleContent.maxCharsPerLine`，沿用 v3 spec）已落地，按字符总数截断换行。但在三类场景下表现不佳：

1. 中英文混排：纯按字符数切，可能把一个英文单词从中间切开
2. Emoji 渲染：Emoji 在 NSAttributedString 中占多个 Unicode scalars，可能在 grapheme cluster 中间切开
3. 标点禁则：句号 / 逗号 / 问号 等在行首违反中文排版规范

### 3.2 v4 完善规则

#### 中英文混排

- 中文字符：单字符为最小换行单位
- 英文字符：单词为最小换行单位（按空格切）
- 混排：扫描时维护「上一字符类型」，遇到类型切换时优先选择该处作为换行候选

#### Emoji

- 用 Swift `String.unicodeScalars.count` 替换为 `String.count`（grapheme cluster 计数）
- 切分时使用 `String.firstIndex(of:)` 等 grapheme-aware API，**绝不在 cluster 内部切开**

#### 标点禁则（中文优先）

行首禁止：`，。！？；：、）」』】》` 等 14 个标点
行尾禁止：`（「『【《` 等开括号类标点

实现：换行候选位置时检查前后字符是否违反禁则；违反则候选位置前移到上一字。

### 3.3 实现位置

字幕换行计算分两层：

- 渲染端硬换行：由 NSAttributedString + NSParagraphStyle 自动按 boundingRect 处理；本规范不动渲染层 wrapping 算法
- 编辑层软换行：用户在 [TextEditPanel](../../Sources/TimelineKit/Views/TextEditPanel.swift) 看到的字幕文本框 + `maxCharsPerLine` 提示 → 由本规范的禁则算法决定换行符插入位置

```swift
// 新增 utility（建议放 Models/SegmentContent.swift 同目录新文件 TextLineBreaker.swift）
public enum TextLineBreaker {
    /// Insert soft `\n` based on maxCharsPerLine + line-break rules.
    /// - Returns: text with `\n` inserted; original `\n` preserved.
    public static func wrap(_ text: String, maxCharsPerLine: Int) -> String {
        // 1. Split by existing `\n` to preserve user hard breaks
        // 2. For each segment, scan characters maintaining grapheme + script awareness
        // 3. Honor punctuation rules
        // 4. Insert soft `\n` where needed
    }
}
```

### 3.4 验收点

- 「Hello世界你好」maxCharsPerLine=5 → 不切开 "Hello"
- 「😀😀😀」maxCharsPerLine=2 → 切在 emoji 之间，不在 emoji 内部
- 「测试。123」maxCharsPerLine=3 → 「测试」+「。123」（句号不在行首）

---

## 四、文本样式复制 / 粘贴

### 4.1 模型

```swift
// EditorStore 内部新增
private struct StyleClipboard {
    let style: TextStyle
    let sourceKind: EditorSegment.Kind  // .subtitle or .text
}

@MainActor
public final class EditorStore {
    // ...
    private var styleClipboard: StyleClipboard?
}
```

剪贴板**仅 in-memory**，不写系统剪贴板（避免污染、避免跨 App 隐私）。App 进程退出后丢失。

### 4.2 新增 store API

```swift
public extension EditorStore {
    /// Copy the style of `segmentID` into the in-memory style clipboard.
    func copyStyle(segmentID: UUID)

    /// Paste the style from the clipboard to `segmentID`. No-op if:
    ///  - clipboard is empty
    ///  - clipboard.sourceKind != segment.kind (字幕↔文本互不污染)
    func pasteStyle(segmentID: UUID)

    /// Whether paste would succeed for `segmentID`. Used by UI to enable/disable button.
    func canPasteStyle(toSegmentID segmentID: UUID) -> Bool
}
```

### 4.3 UI 入口

`TextEditPanel` 顶部功能按钮区追加两个按钮：

```
[删除] [复制样式] [粘贴样式] [朗读] [应用到本轨同类]
```

- 「复制样式」：始终启用（当前已选中段）
- 「粘贴样式」：仅当 `canPasteStyle` 返回 true 时启用

### 4.4 双段 vs 全段

- 复制粘贴 = 单段精准操作（用户挑两段做样式同步）
- 同轨同类批量 = 一键全覆盖（[bulk-style-apply-spec.md](bulk-style-apply-spec.md)）
- 两套机制并存、不互斥；用户按需选用

### 4.5 双端

iOS：使用 `EditorStore` in-memory 字段
Android：等价的 in-memory 状态由 store 持有；行为定义一致

---

## 五、文本层级置顶 / 置底 / 上移 / 下移

### 5.1 数据模型

```swift
// Models/EditorSegment.swift 新增字段
public struct EditorSegment {
    // ...existing fields...
    /// v4: explicit user-controlled layer order. Higher = front. nil = auto.
    /// When nil, segment stacks per the legacy time-overlap algorithm
    /// (SubtitleLayerBuilder §5.1).
    public var userZOrder: Int?
}
```

Codable 加 `case userZOrder` + `decodeIfPresent(... ?? nil)`，旧草稿默认 `nil`。

### 5.2 渲染端复合排序规则

```
For each (subtitle | text) segment, render order is:
  primary key   = userZOrder ?? defaultZOrder(seg)
  secondary key = targetRange.start (asc)
  tertiary key  = segment.id.uuidString (stable)
```

其中 `defaultZOrder(seg)` = v3 现有按时间重叠次数计算的 stackDepth（保留向下兼容）。

### 5.3 「置顶 / 置底 / 上移 / 下移」语义

| 操作 | 行为 |
|---|---|
| **置顶** | `userZOrder = max(其他所有同位置段 userZOrder ?? 0) + 1` |
| **置底** | `userZOrder = min(其他所有同位置段 userZOrder ?? 0) - 1` |
| **上移一层** | 找到当前 z 之上、与当前段有时间重叠的最近段，交换 userZOrder |
| **下移一层** | 找到当前 z 之下、与当前段有时间重叠的最近段，交换 userZOrder |

「其他所有同位置段」= 时间上与当前段重叠的同类（subtitle/text）段。

### 5.4 UI 入口

`TextEditPanel`「位置」Tab 内（仅字幕和带位置的文本有此 Tab）新增「层级」段落：

```
┌─ TextEditPanel.positionTabContent ──────────────────────┐
│ ┌─ existing position rows ─────────────────────────┐  │
│ │ 位置 Y      [────●─────]                              │  │
│ │ ...                                                  │  │
│ └────────────────────────────────────────────────────┘  │
│ ┌─ layerOrderRow (v4 新增) ─────────────────────────┐  │
│ │  层级:  [⏶置顶] [⏷置底] [↑上移] [↓下移]                │  │
│ └────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### 5.5 新增 store API

```swift
public extension EditorStore {
    func bringSegmentToFront(segmentID: UUID)
    func sendSegmentToBack(segmentID: UUID)
    func bringSegmentForward(segmentID: UUID)
    func sendSegmentBackward(segmentID: UUID)
}
```

实现走 `mutateSubtitle`（不重建 composition），调整 `userZOrder` 整数；UI 单段 undo entry。

---

## 六、数据模型变更汇总

```swift
// Models/SegmentContent.swift
public enum TextAlignment: String, Sendable, Hashable, Codable, CaseIterable {
    case leading, center, trailing
}

public struct TextStyle {
    // ... existing 16 fields ...
    public var alignment: TextAlignment = .center  // v4 新增
}

// Models/EditorSegment.swift
public struct EditorSegment {
    // ... existing fields ...
    public var userZOrder: Int? = nil  // v4 新增
}
```

两个加法均向下完全兼容（Codable `decodeIfPresent`，旧草稿默认值即与 v3 视觉一致）。

---

## 七、UI 草图总览

```
┌─ TextEditPanel ──────────────────────────────────────────────┐
│ ┌─ topActionsRow ──────────────────────────────────────────┐│
│ │ [删除] [复制样式] [粘贴样式] [朗读] [应用到本轨同类]               ││ ← §4
│ └──────────────────────────────────────────────────────────┘│
│ ┌─ tabBar ─────────────────────────────────────────────────┐│
│ │  内容  样式  位置                                            ││
│ └──────────────────────────────────────────────────────────┘│
│                                                              │
│  样式 Tab:                                                   │
│   ┌─ stylePresetsRow ────────────────────────────────────┐  │
│   │ [⃠] [T白] [T黄] [T粉] [T青] [T奶] [T绿]                   │  │
│   └──────────────────────────────────────────────────────┘  │
│   ┌─ alignmentRow ────────────────────────────────────────┐  │
│   │  [⫷ 左对齐] [☷ 居中] [⫸ 右对齐]                            │  │ ← §2
│   └───────────────────────────────────────────────────────┘  │
│   ┌─ styleSubTabBar ─────────────────────────────────────┐  │
│   │  文本   描边   背景   阴影                                 │  │
│   └──────────────────────────────────────────────────────┘  │
│                                                              │
│  位置 Tab:                                                   │
│   ┌─ position rows ─────────────────────────────────────┐   │
│   │  位置 Y / X / 单行字数 / ...                              │   │
│   └─────────────────────────────────────────────────────┘   │
│   ┌─ layerOrderRow ─────────────────────────────────────┐   │
│   │  层级:  [⏶置顶] [⏷置底] [↑上移] [↓下移]                    │   │ ← §5
│   └─────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
```

---

## 八、关键文件与改动量

| 文件 | 改动 |
|---|---|
| [Models/SegmentContent.swift](../../Sources/TimelineKit/Models/SegmentContent.swift) | 新增 `TextAlignment` 枚举 + `TextStyle.alignment` 字段 + Codable 兼容 |
| [Models/EditorSegment.swift](../../Sources/TimelineKit/Models/EditorSegment.swift) | 新增 `userZOrder: Int?` 字段 + Codable 兼容 |
| [Models/TextLineBreaker.swift](../../Sources/TimelineKit/Models/) | 新文件：智能换行 + 标点禁则 utility |
| [Rendering/CompositionBuilder.swift](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) | `SubtitleLayerBuilder` + `SubtitleFrameBuilder` 消费 `alignment`；layer 输出按 `userZOrder` 复合排序 |
| [Store/EditorStore.swift](../../Sources/TimelineKit/Store/EditorStore.swift) | 新增 `setTextAlignment` / `copyStyle` / `pasteStyle` / `canPasteStyle` / `bringSegmentToFront/Back/Forward/Backward`；新增私有 `styleClipboard` |
| [Views/TextEditPanel.swift](../../Sources/TimelineKit/Views/TextEditPanel.swift) | 顶部按钮区追加复制/粘贴；样式 Tab 内新增对齐三按钮组；位置 Tab 内新增层级四按钮组 |

**不改动**：v1 / v2 / v3 其他文件。

---

## 九、风险与边界

### 9.1 alignment 与 paddingH 的交互

paddingH 在 `.leading` 对齐下视觉上 = 左侧留白；在 `.center` 下 = 左右等留白；在 `.trailing` 下 = 右侧留白。本期遵循 NSAttributedString 默认行为，不做额外补偿。

### 9.2 字幕渲染的 stackDepth vs userZOrder

- v3 `stackDepth` 基于时间重叠计数（实现自动堆叠）
- v4 `userZOrder` 是用户显式排序覆盖
- 复合排序键：`(userZOrder ?? 0, stackDepth, time.start, id)`
- 当 `userZOrder == nil` 时视觉行为与 v3 一致（默认值 0 + stackDepth）

### 9.3 智能换行性能

`TextLineBreaker.wrap` O(N) where N = 字符数；100 字字幕 ≤ 0.5ms。可在 `mutateSubtitle` 后实时调用，不引入掉帧。

### 9.4 in-memory 剪贴板生命周期

App 后台再回前台：剪贴板保留（同进程）。App 进程被杀：剪贴板丢失（符合用户预期）。

### 9.5 跨段层级与导出

`userZOrder` 不导出到服务端 TimelineExporter（与 `EditorSegment.sourceZIndex` 不同字段，避免混淆）；导出视频按客户端最终 layer 渲染结果直接合并到帧，服务端不感知层级语义。

---

## 十、验收

### 10.1 功能

| Case | 验收 |
|---|---|
| C1 | 选中字幕段 → 点击「左对齐」→ 预览实时左对齐；导出帧与预览一致 |
| C2 | 同上 → 「居中」「右对齐」 |
| C3 | 「Hello世界」maxCharsPerLine=5 → 智能换行不切开 "Hello" |
| C4 | 复制 A 段样式 → 粘贴到 B 段（同 kind）→ B 样式与 A 同步；A 不变 |
| C5 | 复制字幕段样式 → 粘贴到文本段 → 按钮 disabled；toast「跨类型无法粘贴」 |
| C6 | 3 段时间重叠字幕，对中段点「置顶」→ 中段层级最高；预览/导出一致 |
| C7 | 同上场景，对中段点「下移一层」→ 与时间重叠的最低段交换 z |

### 10.2 性能

| 操作 | 标准 |
|---|---|
| `setTextAlignment` mutate + 重绘 | ≤ 8ms |
| `pasteStyle` mutate + 重绘 | ≤ 8ms |
| `bringSegmentToFront` mutate + 重绘 | ≤ 8ms |
| `TextLineBreaker.wrap` 100 字 | ≤ 0.5ms |

### 10.3 兼容

| Case | 标准 |
|---|---|
| 加载 v1/v2/v3 旧草稿 | `alignment` = `.center`、`userZOrder` = `nil`；视觉零差异 |
| 保存草稿 → 重启加载 | 字段保持 |

---

## 十一、固定交互约束（V3 已锁，本规范沿用）

| 约束 | 应用 |
|---|---|
| 文本、字幕共用 `TextEditPanel` | 对齐 / 复制粘贴 / 层级按钮在两类 segment 上行为一致；alignment 字段属于通用 TextStyle |
| 不重建 AVComposition | 所有 4 件功能均走 `mutateSubtitle` 路径，不递增 compositionVersion |
| 向下完全兼容 | alignment 默认 `.center`、userZOrder 默认 `nil`；旧草稿零差异 |
| 单条 undo entry | 每次按钮点击 = 一条 undo entry |
| 安卓 / iOS 双端一致 | alignment 枚举、剪贴板语义、层级按钮文案在本 spec 固定 |
