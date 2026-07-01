# 多轨道双栏同步滚动规范（v4）

> 版本：v4.0
> 状态：规范定稿，待实现
> 优先级：**P0**（阻塞 V3 多轨功能的实际可用性）
> 对标产品：剪映 iOS / CapCut Desktop（共享 ScrollView）+ FCP（NSScrollView delegate 同步）
> 依赖：v3 [multi-track-architecture-spec.md](../v3/multi-track-architecture-spec.md)；[competitive-benchmarks-v4.md](competitive-benchmarks-v4.md) §4

---

## 一、问题陈述

V3 多轨架构允许 `.subtitle / .text / .audio / .overlay` 每类最多 8 条同类轨。但 `ClipEditorViewController` 主 UIScrollView 是**横向独享**，左侧 `TrackLabelsView` 是**固定左栏（frame 布局，无 scroll）**——一旦轨道数超过屏幕可视行数（约 5~6 条），**下方轨道既看不到也选不到**。V3 多轨能力实际上被这个 UI 缺陷废掉。

实锤现状：

- [ClipEditorViewController.swift:141-158](../../Sources/TimelineKit/Views/ClipEditorViewController.swift)：`scrollView.showsVerticalScrollIndicator = false`、`alwaysBounceHorizontal = true`；纵向未启用滚动
- [ClipEditorViewController.swift:394-456](../../Sources/TimelineKit/Views/ClipEditorViewController.swift) `TrackLabelsView`：固定左栏，width=52，frame 布局，无 scroll
- [TrackCanvasView.swift:248](../../Sources/TimelineKit/Views/TrackCanvasView.swift)：`totalHeight = rulerHeight + tracks.count × (trackHeight + trackSpacing)`，contentSize.height 已正确计算，但 scrollView 不消费

---

## 二、规则定义

### 2.1 双栏纵向同步滚动（采纳方案 A）

**方案 A（采纳）**：保留两栏分离结构，主 `scrollView` 开启纵向滚动；通过 `scrollViewDidScroll(_:)` 把 `contentOffset.y` 转发给 `TrackLabelsView` 的子视图变换。

**方案 B（未采纳）**：把两栏放进同一个外层垂直 ScrollView，水平滚动留在内层。**未采纳理由**：内外 ScrollView 嵌套对 pinch zoom + pan + trim handle 手势传递链改动太大，回归风险高。

详见 [competitive-benchmarks-v4.md](competitive-benchmarks-v4.md) §4.3。

### 2.2 行高对齐

- TrackLabelsView 顶部 spacer = `TrackCanvasView.rulerHeight = 36`
- 每行 label 高度 = `TrackCanvasView.trackHeight = 40`
- 每行间距 = `TrackCanvasView.trackSpacing = 3`
- 总 labels 内容高度 = `rulerHeight + tracks.count × (trackHeight + trackSpacing)`，**必须与 TrackCanvasView.contentSize.height 完全相等**

行高常量沿用 V3 既有值，不改。

### 2.3 滚动行为

- 纵向滚动启用条件：`contentSize.height > scrollView.bounds.height`（轨道行数足够多）
- 横向滚动保持现状（`alwaysBounceHorizontal = true`）
- pinch zoom：仅影响横向 contentSize.width 与播放头位置；不影响纵向滚动
- 惯性滑动：iOS 默认 `.fast` deceleration（沿用 [ClipEditorViewController.swift:146](../../Sources/TimelineKit/Views/ClipEditorViewController.swift)）

### 2.4 滚动条目超出可视区

- 选中片段时：scrollView 自动滚到该片段所在行可见区域（沿用 v3 已实现的 horizontal scrollTo 逻辑，本期补 vertical 维度）
- 新建轨道 `addTrack` 时：自动滚到新轨道行可见区域

---

## 三、实现

### 3.1 scrollView 配置改动

```swift
// ClipEditorViewController.swift setupScrollView
private func setupScrollView() {
    scrollView = UIScrollView()
    scrollView.showsVerticalScrollIndicator = true        // v4: 启用纵向滚动条
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.alwaysBounceHorizontal = true
    scrollView.alwaysBounceVertical   = false             // v4: 仅在 contentSize 超出可视时才纵向滚动
    scrollView.decelerationRate = .fast
    // ...
}
```

`alwaysBounceVertical = false` 保证轨道少时不出现「弹性回弹」（与 v3 体感一致）。

### 3.2 contentSize 已正确

[TrackCanvasView.swift:248-480](../../Sources/TimelineKit/Views/TrackCanvasView.swift) 计算 `totalHeight` 与 `contentSize.height` 已与轨道行数对齐，本期不需改动；只需让 scrollView 实际允许纵向滚动。

### 3.3 TrackLabelsView 跟随转发

`TrackLabelsView` 内部所有 row 包在一个内部 `containerView` 里；`containerView` 的 `transform.ty` 跟随主 scrollView 的 `contentOffset.y` 反向变换。

```swift
// ClipEditorViewController scrollViewDidScroll
extension ClipEditorViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 现有横向 scrub 逻辑
        // ...

        // v4: 把纵向 contentOffset.y 转发给左侧 labels
        labelsView.applyVerticalOffset(scrollView.contentOffset.y)
    }
}
```

```swift
// TrackLabelsView 新增
final class TrackLabelsView: UIView {
    private let contentContainer = UIView()  // v4 新增

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 把现有所有 row 加到 contentContainer 而不是 self
        addSubview(contentContainer)
        contentContainer.frame = bounds
        contentContainer.clipsToBounds = false
        // 分割线仍在 self
        // ...
    }

    func applyVerticalOffset(_ offsetY: CGFloat) {
        contentContainer.transform = CGAffineTransform(translationX: 0, y: -offsetY)
    }

    func configure(tracks: [EditorTrack]) {
        // 之前 addSubview 到 self 的 row 全部改为 addSubview 到 contentContainer
        // ...
    }
}
```

### 3.4 「+ new track」按钮的可点击区域

`TrackLabelsView` 的 + 按钮位于最后一条同类轨行右侧。同步滚动后该按钮随 transform 移动 → 用户可能需要先滚到底部才能看到。**行为正确，符合用户预期**。

不做特殊「+ 按钮悬浮」处理（避免与「滚动联动」原则冲突）。

---

## 四、数据模型变更

**无任何字段新增**。本规范是纯 UI 改动。

---

## 五、UI 草图

### 5.1 滚动前（屏幕容纳约 5 条轨道）

```
┌────┬─────────────────────────────────────┐
│尺  │  Ruler 0  1  2  3  4s ...               │ ← rulerHeight = 36
├────┼─────────────────────────────────────┤
│🎬 │  ▓▓▓▓▓▓▓▓▓                              │ ← trackHeight = 40
│主轨 │                                          │
├────┼─────────────────────────────────────┤
│💬 │  ████   ████                            │
│字幕1 │                                          │
├────┼─────────────────────────────────────┤
│💬 │  ██████      ██                          │
│字幕2 │                                          │
├────┼─────────────────────────────────────┤
│T  │  ▓▓▓▓                                    │
│文本1 │                                          │
├────┼─────────────────────────────────────┤
│🎵 │  ░░░░░░░░░░░░                            │
│音频1 │                                          │
└────┴─────────────────────────────────────┘
（音频 2、3 + 文本 2 + 字幕 3、4 不可见，无法滚动）
```

### 5.2 v4 后（纵向滚动启用）

```
┌────┬─────────────────────────────────────┐
│尺  │  Ruler ...                              │
├────┼─────────────────────────────────────┤
│💬 │  ████   ████                            │ ← 用户已纵向滚动 contentOffset.y = 120
│字幕1 │                                          │
├────┼─────────────────────────────────────┤
│💬 │  ██████      ██                          │
│字幕2 │                                          │
├────┼─────────────────────────────────────┤
│T  │  ▓▓▓▓                                    │
│文本1 │                                          │
├────┼─────────────────────────────────────┤
│🎵 │  ░░░░░░░░░░░░                            │
│音频1 │                                          │
├────┼─────────────────────────────────────┤
│🎵 │  ░░░░                                    │
│音频2 │                                          │
└────┴─────────────────────────────────────┘
（labels 与 canvas 同步上移；下方轨道现在可见可选）
```

行高严格对齐 = labels 每行 y 偏移与 canvas 每行 y 偏移完全相等。

---

## 六、关键文件与改动量

| 文件 | 改动 |
|---|---|
| [Views/ClipEditorViewController.swift](../../Sources/TimelineKit/Views/ClipEditorViewController.swift) | `setupScrollView`: 启用纵向滚动条；`scrollViewDidScroll`: 转发 `contentOffset.y` 给 `labelsView.applyVerticalOffset` |
| [Views/ClipEditorViewController.swift TrackLabelsView](../../Sources/TimelineKit/Views/ClipEditorViewController.swift) | 引入 `contentContainer: UIView` 包裹所有 row；新增 `applyVerticalOffset(_:)` 方法；分割线保持挂在 self（不跟滚动）|

**不改动**：[TrackCanvasView.swift](../../Sources/TimelineKit/Views/TrackCanvasView.swift)（contentSize.height 已正确）；其他 UI 链路；store 层。

---

## 七、风险与边界

### 7.1 与 pinch zoom 的耦合

pinch zoom 仅改 scrollView.zoomScale → 等价改 contentSize.width → 触发 `scrollViewDidScroll`（横向位置变化）但不动 `contentOffset.y`。`applyVerticalOffset(0)` 不引入额外位移 → 与现状视觉一致。

### 7.2 trim handle 拖拽期间

trim handle pan 与 scrollView pan 同时存在；v1 已设 `shouldRecognizeSimultaneouslyWith` 拒绝两者并存（[ClipEditorViewController.swift:386](../../Sources/TimelineKit/Views/ClipEditorViewController.swift) `if other === scrollView.panGestureRecognizer { return false }`）。本期不改这部分逻辑，trim 期间 scrollView 不滚（包括横纵）。

### 7.3 「+ new track」点击响应

新建轨道时 contentSize.height 增加 → 主 scrollView 自动允许滚到新行；同步触发 labelsView 重新 configure。若新轨道在底部不可见区，本期建议在 `addTrack` 完成后调 `scrollView.setContentOffset(...)` 自动滚到新行可见区域（v3 [multi-track-architecture-spec.md](../v3/multi-track-architecture-spec.md) §4.1 已暗示「新建后选中」语义，本期补可见性确保）。

### 7.4 内容高度小于可视区

`alwaysBounceVertical = false` 保证轨道少时（如只有主轨）不出现纵向弹性回弹。labelsView.applyVerticalOffset(0) 保持原状。

### 7.5 双端实现差异

Android 端 RecyclerView + 横向 HorizontalScrollView 的嵌套结构与 iOS 不完全等价，但「label 跟随 canvas 垂直同步」语义一致，由 Android 端单独实现等价手势链。

---

## 八、验收

### 8.1 功能

| Case | 验收 |
|---|---|
| C1 | 单轨场景（仅主轨）→ 无纵向滚动条，无弹性回弹 |
| C2 | 添加 2 条字幕轨 + 1 条文本轨 + 2 条音频轨（共 6 轨）→ 滚动条出现；纵向滑动平滑 |
| C3 | 8 字幕 + 8 文本 + 8 音频 + 主轨（共 25 轨）→ 纵向滚动到最底部，所有行可见可选 |
| C4 | 滚动过程中，左侧 labels 每行的 y 坐标与右侧 canvas 对应行的 y 坐标 0 差异（截图对照像素级一致）|
| C5 | 滚动过程中，rulerHeight=36 顶部区不跟随纵向滚动（pinned 在顶部）|
| C6 | 选中底部一条字幕段 → scrollView 自动滚到该行可见 |
| C7 | 点击「+ new audio track」→ 新轨追加到底部 → scrollView 自动滚到新轨可见 |
| C8 | pinch zoom 横向放大 5x → 纵向滚动状态不变 |
| C9 | trim handle 拖拽期间，scrollView 横纵都不滚（沿用 v1 规则）|

### 8.2 性能

| 操作 | 标准 |
|---|---|
| 纵向滚动 25 轨场景 | 60fps 稳态；`applyVerticalOffset` 单次 ≤ 1ms |
| 1000 次连续纵向滚动事件 | 0 漂移；contentOffset.y 与 labels.contentContainer.transform.ty 1:1 一致 |

### 8.3 稳定

| Case | 标准 |
|---|---|
| 加载多轨草稿（5+ 轨） | labels 与 canvas 初始位置 0 偏移 |
| 删除中间一条轨 → relayout | labels 重新 configure 后位置正确 |
| 设备旋转（仅 iPad 横竖屏切换场景） | 旋转后行高常量不变，offset 自动重新校正 |

---

## 九、固定交互约束（V3 已锁，本规范沿用）

| 约束 | 应用 |
|---|---|
| 轨道点击仅唤起快捷栏，不遮挡编辑区 | scrollView 滚动不触发任何选中状态变化 |
| 文本字幕共用 `TextEditPanel` | 本规范不涉及编辑面板 |
| 底部工具栏二态 | 本规范不涉及工具栏 |
| 向下完全兼容 | 无字段变更，纯 UI 改动 |
| 安卓 / iOS 双端一致 | 「label 跟随 canvas 垂直同步」语义双端共享；行高常量在 spec 中固定（36 / 40 / 3）|
