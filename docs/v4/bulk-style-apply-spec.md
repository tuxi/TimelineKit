# 批量样式应用规范（v4）

> 版本：v4.0
> 状态：规范定稿，待实现
> 优先级：**P0**
> 对标产品：剪映 iOS（主对标）+ FCP Paste Attributes（二次确认参考）
> 依赖：[text-style-fidelity-spec.md](text-style-fidelity-spec.md)（单段 mutate 链路是批量复用的前置）；[competitive-benchmarks-v4.md](competitive-benchmarks-v4.md) §3

---

## 一、问题陈述

V3 后用户可以在 `TextEditPanel` 上对单段文本/字幕调出符合需求的样式，但同一条字幕轨上 30 段台词的样式还是只能逐条复制——`EditorStore` 无任何 batch / applyToAll 方法。竞品（剪映 / CapCut / FCP）均已提供「调一段、一键应用到全部」的入口。V4 P0 必须把效率拉齐主流。

---

## 二、规则定义

### 2.1 入口

- 位置：`TextEditPanel` 功能按钮区显式按钮（非 More 二级菜单）
- 文案：「应用到本轨同类」
- 图标：SF Symbol `doc.on.doc`
- 启用条件：当前轨道 segments 数量 ≥ 2（仅一段时不显示，避免无意义点击）

### 2.2 作用域

| 当前选中片段 kind | 批量目标 |
|---|---|
| `.subtitle` | 当前轨道所有 `.subtitle` 段 |
| `.text` | 当前轨道所有 `.text` 段 |

**kind 严格隔离**：字幕样式不能批量到文本段，反之亦然（避免字幕样式与文本花字样式互相污染）。

**轨道隔离**：仅作用于源片段所在的轨道，不跨轨（v3 多轨架构 + 用户可能给不同轨道调不同风格）。

### 2.3 覆盖字段（v4 P0 + P1）

#### v4 P0 阶段（本规范）

`TextStyle` 12 字段全集：

```
color, backgroundColor, backgroundRadius, paddingH, paddingV,
strokeColor, strokeWidth,
shadowColor, shadowOffsetX, shadowOffsetY, shadowRadius,
kerning, lineSpacing, isItalic
```

加上 `fontSize / fontWeight / fontName` 共 15 项（见 [text-style-fidelity-spec.md](text-style-fidelity-spec.md) §4 字段表）。

#### v4 P1 扩展（待 [text-typography-spec.md](text-typography-spec.md) 落地后追加）

- `TextStyle.alignment`（P1 新增字段）
- `SubtitleContent.maxCharsPerLine` / `SubtitleContent.positionY`（字幕专属位置 / 单行字数；通过 `includePositionFields: Bool` 参数控制是否包含）

### 2.4 不覆盖字段

| 字段 | 理由 |
|---|---|
| 文本内容 `text` | 用户原意是复用样式，不复用内容 |
| 时长 `targetRange` | 时长是片段固有 |
| 位置 `position` / `positionY`（默认 false） | 各段时间不同，位置批量易破坏排版；只有用户显式勾选才覆盖（P1 阶段提供）|
| `userZOrder`（P1 新增） | 层级是按段独立配置的逻辑值，批量会破坏顺序 |

### 2.5 二次确认弹窗

弹窗 UI：

```
┌────────────────────────────────┐
│     应用到本轨同类                 │
│                                │
│  将当前样式应用到本条轨道的         │
│  其他 N 个同类片段                │
│                                │
│  此操作可撤销                   │
│                                │
│   [ 取消 ]    [ 确认应用 ]        │
└────────────────────────────────┘
```

- N 是除当前片段外、同轨同 kind 的片段数量
- 「取消」：dismiss，不写入
- 「确认应用」：调 store API；toast「已应用到 N 个片段」

---

## 三、新增 store API

```swift
public extension EditorStore {
    /// Apply the style of `sourceSegmentID` to all other segments of the same
    /// kind on the same track. Falls into a single `mutate { ... }` block so
    /// the entire batch shows up as one undo entry.
    ///
    /// - parameter trackID: target track. Function looks up the track from
    ///   this ID and rejects if not found.
    /// - parameter sourceSegmentID: the segment whose style is the source.
    ///   Must reside in `trackID`. Style fields copied as defined in
    ///   bulk-style-apply-spec.md §2.3.
    /// - parameter includePositionFields: P1 toggle. When `true`, also copies
    ///   subtitle `positionY` and `maxCharsPerLine`. v4 P0 always passes
    ///   `false`.
    /// - returns: number of segments actually mutated (excludes source).
    @discardableResult
    func applyStyleToTrackSegmentsOfKind(
        trackID: UUID,
        sourceSegmentID: UUID,
        includePositionFields: Bool = false
    ) -> Int
}
```

### 3.1 实现伪代码

```swift
@discardableResult
func applyStyleToTrackSegmentsOfKind(
    trackID: UUID,
    sourceSegmentID: UUID,
    includePositionFields: Bool = false
) -> Int {
    guard let track = timeline.tracks.first(where: { $0.id == trackID }),
          let source = track.segments.first(where: { $0.id == sourceSegmentID })
    else { return 0 }

    var count = 0
    mutate { draft in
        guard let trackIdx = draft.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let targetKind = source.kind  // .subtitle or .text
        for i in draft.tracks[trackIdx].segments.indices {
            let seg = draft.tracks[trackIdx].segments[i]
            guard seg.id != sourceSegmentID, seg.kind == targetKind else { continue }
            switch (source.content, seg.content) {
            case (.subtitle(let src), .subtitle(var dst)):
                dst.style = src.style
                if includePositionFields {
                    dst.positionY        = src.positionY
                    dst.maxCharsPerLine  = src.maxCharsPerLine
                }
                draft.tracks[trackIdx].segments[i].content = .subtitle(dst)
                count += 1
            case (.text(let src), .text(var dst)):
                dst.style = src.style
                if includePositionFields { dst.position = src.position }  // P1 only
                draft.tracks[trackIdx].segments[i].content = .text(dst)
                count += 1
            default: continue  // kind 不匹配，跳过
            }
        }
    }
    return count
}
```

**关键**：单次 `mutate { ... }` 包裹整批改写 → 单条 undo entry；触发 `mutateSubtitle` 不重建路径（沿用 v1 S-04），不递增 `compositionVersion`。

---

## 四、UI 集成

### 4.1 TextEditPanel 按钮位置

`TextEditPanel` 现有功能按钮区（朗读 / 删除 / 替换）旁追加新按钮：

```
┌─ TextEditPanel 顶部功能按钮区 ──────────────────────────┐
│  [删除]  [复制]  [朗读]  [应用到本轨同类]                  │ ← v4 新增最后一项
└─────────────────────────────────────────────────────────┘
```

按钮 disabled 条件：

- 当前未选中 segment（store.selection 为 nil）
- 当前轨道仅有 1 个 segment
- 当前轨道无同 kind 其他 segment

### 4.2 二次确认弹窗

用 `SwiftUI .alert` 实现，title「应用到本轨同类」、message「将当前样式应用到本条轨道的其他 N 个同类片段。此操作可撤销。」，按钮「取消」 + 「确认应用」（destructive style 不适合，用 default style）。

### 4.3 完成后反馈

成功后 toast：`已应用到 \(count) 个片段`。toast 使用 DesignKit 已有的 `ToastView`（沿用 v3 toast 风格）。

---

## 五、关键文件与改动量

| 文件 | 改动 |
|---|---|
| [Store/EditorStore.swift](../../Sources/TimelineKit/Store/EditorStore.swift) | 新增 `applyStyleToTrackSegmentsOfKind(trackID:sourceSegmentID:includePositionFields:)` |
| [Views/TextEditPanel.swift](../../Sources/TimelineKit/Views/TextEditPanel.swift) | 顶部功能按钮区新增「应用到本轨同类」按钮 + `.alert` 修饰符 + 完成后 toast 触发 |
| [Models/SegmentContent.swift](../../Sources/TimelineKit/Models/SegmentContent.swift) | 无改动（字段已在）|

**不改动**：渲染管线、其他 mutate 路径、Codable。

---

## 六、风险与边界

### 6.1 并发选择切换

批量过程中用户切换选中片段：mutate 块内同步完成，UI 切换在 mutate 完成后才生效，不会出现「应用到一半」状态。

### 6.2 大轨道性能

字幕轨极限 100 段场景：100 段 style 替换 ≤ 50ms（v3 mutateSubtitle 单段 ≤ 0.5ms，100 × 0.5 = 50ms）。不超 KPI 上限。

### 6.3 当前片段被锁定轨道

若 v4 P1 [audio-track-controls-spec.md](audio-track-controls-spec.md) 引入轨道锁，源片段所在轨道锁定时：

- 按钮 disabled（与 trim / drag 一致）
- API 调用直接 return 0（防御性）

### 6.4 字幕的 `positionY` / `maxCharsPerLine` 默认不批

v4 P0 阶段固定 `includePositionFields = false`。**理由**：位置批量易破坏用户已有的画面排版；用户期望「样式跟着调，位置保留」。`includePositionFields = true` 留给 P1 [text-typography-spec.md](text-typography-spec.md) 的高级菜单。

---

## 七、验收

### 7.1 功能

| Case | 验收 |
|---|---|
| C1 | 单轨 5 段字幕，选中段 1 调样式 → 点击「应用到本轨同类」→ 弹窗显示「将影响 4 个片段」→ 确认 → 4 段字幕样式同步 |
| C2 | 同上场景，点击「取消」→ 无任何变更 |
| C3 | 轨道仅 1 段字幕 → 「应用到本轨同类」按钮 disabled |
| C4 | 轨道 A 有 3 段字幕，轨道 B 有 5 段字幕；在 A 段 1 上点批量 → 仅 A 的另外 2 段同步，B 完全不动 |
| C5 | 轨道有 3 段字幕 + 2 段文本（v3 多轨架构禁止同轨混 kind，故此 case 不存在；保留作为 negative test）| 
| C6 | 整批完成后单次 undo → 4 段全部回滚到改前样式 |
| C7 | redo → 4 段再次同步到源样式 |
| C8 | 字幕段批量样式 → `positionY` 不变；`maxCharsPerLine` 不变 |
| C9 | 文本段批量样式 → `position.x / position.y` 不变 |

### 7.2 性能

| 操作 | 标准 |
|---|---|
| 10 段批量 | ≤ 16ms |
| 50 段批量 | ≤ 30ms |
| 100 段批量 | ≤ 50ms |
| 批量后单次 undo | ≤ 8ms |

### 7.3 兼容

| Case | 标准 |
|---|---|
| v1/v2/v3 旧草稿加载 | 无字段变更，100% 兼容 |
| 批量后再次保存草稿 → 重启加载 | 所有段样式与批量后一致 |

---

## 八、固定交互约束（V3 已锁，本规范沿用）

| 约束 | 应用 |
|---|---|
| 文本、字幕共用 `TextEditPanel` | 按钮在两类 segment 上行为一致；store API 按 kind 派发 |
| 不重建 AVComposition | 单次 mutate 内部统一走字幕图层重绘，不递增 compositionVersion |
| 向下完全兼容 | 无字段新增 / 删除 |
| 底部工具栏二态 | 选中片段时显示编辑快捷操作（包含此新按钮）；未选中时不显示 |
| 单条 undo entry | 整批改写归为一条 undo entry |
| 安卓 / iOS 双端一致 | 弹窗文案、图标、行为定义在本 spec，双端按 spec 实现 |
