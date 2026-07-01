# 字幕渲染规范 v1.0
> 对标产品：剪映 iOS（交互 UI）+ Final Cut Pro（图层架构）
> 适用范围：TimelineKit P1 字幕轨道渲染实现

---

## 1. 图层层级定义

```
z-order（从低到高）
─────────────────────────────────────────
0   主视频轨道（VideoTrack）
1   背景叠加层（OverlayTrack，z < 0）
5   字幕轨道（SubtitleTrack）          ← 本规范作用域
10  文字贴纸轨道（TextTrack）
15  普通贴纸（StickerTrack，P2）
20  调节层（AdjustmentTrack，P2）
─────────────────────────────────────────
```

**规则**：
- 字幕永远压在文字贴纸上方；文字贴纸由用户手动放置，字幕由系统自动排列。
- 同一帧多条字幕按 `targetRange.start` 升序排列，靠下的先开始，靠上的后开始。
- 字幕层不参与视频合成指令（`AVMutableVideoCompositionInstruction`），只走 `AVVideoCompositionCoreAnimationTool`——预览时由 SwiftUI `SubtitleOverlayView` 替代，导出时才启用 CoreAnimation Tool（见第 6 节）。

---

## 2. 渲染架构：预览 vs 导出双轨

| 场景 | 渲染方式 | 触发条件 |
|---|---|---|
| 编辑预览 | SwiftUI `SubtitleOverlayView` 实时叠加 | AVPlayerItem 不能挂 animationTool |
| 导出 MP4 | `AVVideoCompositionCoreAnimationTool` 烘焙 | `AVAssetExportSession` 专用 |

**预览路径**（现有 `EditorPreviewView.activeSubtitle`）：
```
store.selection.playheadTime
  → activeSubtitle: SubtitleContent?
  → SubtitleOverlayView(content:)
```
字幕内容变更时只刷新 SwiftUI 状态，**不重建 AVComposition**。

**导出路径**（P1 实现 `CompositionBuilder.buildForExport`）：
```
SubtitleLayerBuilder.build(segments:renderSize:totalDuration:)
  → CATextLayer × N，opacity CAKeyframeAnimation
  → AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer:in:)
  → videoComposition.animationTool = tool
```

---

## 3. 字幕样式全字段映射

### 3.1 `SubtitleStyle` 字段到渲染属性

| SubtitleStyle 字段 | 类型 | CATextLayer 属性 | 默认值 | 剪映对标 |
|---|---|---|---|---|
| `fontSize` | `Double?` | `layer.fontSize` | 16.0 | 正文 16pt，强调 20pt |
| `fontWeight` | `FontWeight?` | NSAttributedString `.font` | `.regular` | 支持 bold/medium |
| `color` | `String?` (hex) | `layer.foregroundColor` | `#FFFFFF` | 纯白 |
| `backgroundColor` | `String?` (hex+alpha) | `layer.backgroundColor` | `#00000099` | 半透明黑底 |
| `positionY` | `Double?` (0..1) | frame.origin.y | 底部留 60pt | 剪映默认居底 1/6 处 |
| `maxCharsPerLine` | `Int?` | 换行约束 | 无限制 | 剪映默认 20 字/行 |

### 3.2 CATextLayer 渲染参数（固定值）

```swift
layer.alignmentMode   = .center
layer.isWrapped       = true
layer.contentsScale   = UIScreen.main.scale
layer.cornerRadius    = 4                     // 背景圆角
// padding: 横向 20pt，纵向 8pt（frame 扩展实现，非 CALayer 原生 padding）
```

### 3.3 字幕行高公式

```
lineH = fontSize * 1.6 + paddingV * 2
frameWidth = renderSize.width - horizontalInset * 2   // inset = 20pt
frameX = horizontalInset
frameY = positionY != nil
         ? renderSize.height * positionY - lineH / 2
         : renderSize.height - lineH - 60              // 底部兜底
```

---

## 4. 字幕入画/出画动画规范

### 4.1 标准淡入淡出（剪映默认）

使用 `CAKeyframeAnimation(keyPath: "opacity")`，时间节点：

```
t0 = (segStart - fadeDuration) / totalDuration    → opacity 0
t1 = segStart / totalDuration                     → opacity 1  ← 淡入完成
t2 = segEnd   / totalDuration                     → opacity 1  ← 开始淡出
t3 = (segEnd  + fadeDuration) / totalDuration     → opacity 0

fadeDuration = 0.08s（约 2 帧 @30fps，剪映实测值）
```

**关键参数**：
```swift
anim.calculationMode = .linear
anim.duration        = totalDuration
anim.beginTime       = AVCoreAnimationBeginTimeAtZero
anim.fillMode        = .both
anim.isRemovedOnCompletion = false
```

### 4.2 高亮段动画（SubtitleSegmentItem）

当字幕有 `segments`（逐字高亮模式）时：
- 主字幕层显示完整文本，颜色为 `style.color`
- 每个 `SubtitleSegmentItem` 叠加一个同位置 CATextLayer，颜色取 `item.color ?? "#FFD60A"`（剪映黄色）
- 高亮层的 opacity 动画只在该 item 的时间段内为 1，其余为 0

### 4.3 暂不支持的动画（P2）
- 弹入/弹出（spring 动画）
- 文字逐字出现（typewriter effect）
- 自定义轨迹路径

---

## 5. 多字幕重叠规则

### 5.1 同一时刻出现多条字幕

剪映行为：自动向上堆叠，间距 8pt。

实现方式：`SubtitleLayerBuilder.build` 阶段，按 `targetRange.start` 排序，检测时间重叠：
```
如果 seg[i].targetRange 与 seg[j].targetRange 有交集：
  seg[j].frameY -= (lineH + 8)   // 向上偏移一行
```
最多支持 3 条同时显示；超出后按 z-order 遮盖（最晚开始的在最上方）。

### 5.2 同轨道防重叠约束（编辑交互）

- 拖拽字幕片段时，不允许与同轨道其他片段重叠（左右边界吸附）；
- 最小片段时长：0.5s；
- 字幕片段与主轨道无时间关联，可自由覆盖任意时间段。

---

## 6. 编辑性能规范

| 操作 | AVComposition 重建 | CALayer 刷新 | 原因 |
|---|---|---|---|
| 修改字幕文本 | ❌ 不重建 | ✅ 仅刷新 SwiftUI 状态 | 预览层是纯 SwiftUI |
| 修改字幕样式（颜色/字号）| ❌ 不重建 | ✅ 仅刷新 | 同上 |
| 修改字幕时间范围 | ❌ 不重建 | ✅ 仅刷新 | 时间跳变由 playheadTime 驱动 |
| 增加/删除字幕片段 | ❌ 不重建 | ✅ 仅刷新 | 字幕不在 AVComposition 轨道内 |
| 导出时 | ✅ 重建（export专用路径）| ✅ 烘焙 CALayer | animationTool 仅用于导出 |

**核心原则**：字幕修改零重建成本；AVComposition 只在视频/音频轨道变更时重建。

---

## 7. 字幕编辑交互规范（对标剪映）

### 7.1 选中态
- 单击字幕片段 → 选中，轨道上高亮显示（描边 + 左右手柄）
- 选中后底部工具栏切换为字幕编辑面板（`EditorSecondaryToolPanel(.subtitle)`）

### 7.2 手柄拉伸约束
```
左手柄最小位置  = max(0, rightEdge - maxDuration)
右手柄最大位置  = min(timelineDuration, leftEdge + maxDuration)
最小时长        = 0.5s
最大时长        = 不限（可覆盖整个工程）
左右不能越过对方（防止时长变负）
```

### 7.3 时间轴位置拖拽
- 字幕片段可自由横向拖拽，不磁吸主轨道（区别于视频片段）
- 拖拽时不触发 AVComposition 重建
- 松手后通过 `store.mutate` 写入 undo 栈

### 7.4 字幕文本编辑
- 双击字幕预览区（`SubtitleOverlayView`）→ 弹出文本编辑键盘
- 键盘弹出时预览区上移，字幕所在行高亮
- 编辑完成 → `store.mutate("编辑字幕")` 写入 undo 栈

---

## 8. 验收标准

| # | 验收项 | 标准 |
|---|---|---|
| S-01 | 字幕显示位置 | 底部居中，与剪映默认位置偏差 < 5pt |
| S-02 | 字幕淡入淡出 | 入/出各 2 帧，肉眼可见平滑过渡 |
| S-03 | 多字幕堆叠 | 同时显示 2 条字幕时不重叠，间距 8pt |
| S-04 | 修改文本不重建 | 修改字幕文本，AVPlayer 无 replaceCurrentItem 调用 |
| S-05 | 导出烘焙 | 导出 MP4 包含字幕，与预览显示位置一致 |
| S-06 | 手柄约束 | 最小时长 0.5s，不能拖出 0 边界 |
| S-07 | 撤销重做 | 文本/样式/时长修改均可 undo/redo |
