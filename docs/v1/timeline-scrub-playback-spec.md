# 播放 & 时间轴拖拽联动规范 v1.0
> 对标产品：剪映 iOS（手势 & 磁吸 & 播放头行为）+ Final Cut Pro（scrub 策略）+ LumaFusion（性能降级）
> 适用范围：TimelineKit P1 播放控制 & 时间轴交互实现

---

## 1. 播放头（Playhead）行为规范

### 1.1 状态机

```
IDLE（停止/未加载）
  → 挂载 AVPlayerItem 后 → PAUSED
  → 用户点击播放 → PLAYING
  → 播放到结尾 → PAUSED（自动停止，播放头留在结尾）
  → 用户 scrub → SCRUBBING（暂停播放，预览跟随）
  → scrub 松手 → 回到 PLAYING 或 PAUSED（取决于 scrub 前状态）
  → replaceCurrentItem（rebuild）→ PAUSED（播放头恢复前位置）
```

### 1.2 播放头边界约束

```
playheadTime ∈ [0, timeline.duration]

规则：
  - 播放到 timeline.duration - 0.05s 时触发 actionAtItemEnd = .pause
  - 不能拖出 0（左边界硬锁）
  - 不能超出 timeline.duration（右边界动态更新：工程时长变化时自动同步）
  - 点击「下一段」到最后一段后：playheadTime → 最后一段 targetRange.start
  - 点击「上一段」在第一段前：playheadTime → 0
```

### 1.3 从头播放逻辑

```swift
// EditorStore.play()
if p.currentTime().seconds >= timeline.duration - 0.05 {
    p.seek(to: .zero)   // 已在结尾 → 从头开始
}
p.play()
```

---

## 2. 时间轴 Scrub 拖拽规范

### 2.1 手势定义（剪映范式）

| 手势 | 行为 | 触发区域 |
|---|---|---|
| 单指横向拖拽（时间轴滚动）| 滚动时间轴，播放头固定居中 | 整个 TrackArea |
| 单指拖拽播放头指针 | 播放头移动，时间轴不滚动 | 播放头指针上方 ±20pt |
| 双指捏合 | 缩放 pps（pixels per second）| 整个 TrackArea |

> 剪映设计选择：**时间轴跟着手指走，播放头固定在屏幕中心**。  
> FCP 设计选择：**播放头跟着手指走，时间轴不动**。  
> **本项目选择剪映范式**：时间轴滚动 = 改变 scrollView.contentOffset，播放头始终在屏幕正中显示。

### 2.2 Scrub 节流规范（对标 LumaFusion）

```
目标：scrub 时帧率 ≥ 30fps，seek 响应 ≤ 33ms

节流策略：
  onChanged 每次回调：
    1. 计算 newPlayheadTime（canvas.time(at: x)）
    2. 距上次 seek > 33ms（或位移 > 2pt）→ 执行 seek
    3. 否则跳过本次 seek（避免 seek 队列堆积）

实现：
  private var lastScrubTime: CFTimeInterval = 0
  private let scrubInterval: CFTimeInterval = 0.033  // ~30fps

  if CACurrentMediaTime() - lastScrubTime > scrubInterval {
      store.seek(to: newTime)
      lastScrubTime = CACurrentMediaTime()
  }
```

### 2.3 Scrub 期间播放状态管理

```
scrub 开始（gesture .began）：
  wasPlaying = store.isPlaying
  if wasPlaying { store.pause() }

scrub 中（gesture .changed）：
  store.seek(to: time)           // 只 seek，不 play
  store.selection.playheadTime = time   // UI 同步

scrub 结束（gesture .ended / .cancelled）：
  if wasPlaying { store.play() }  // 恢复播放
  // 否则保持 paused
```

### 2.4 预览分辨率动态降级（LumaFusion 策略）

| 状态 | 渲染分辨率 | AVPlayer.preferredMaximumResolution |
|---|---|---|
| 静止播放 | 全分辨率（canvas 原始尺寸）| 不限制 |
| Scrubbing 中 | 降至 540p（若 canvas > 720p）| `CGSize(width: 960, height: 540)` |
| AVComposition rebuild 中 | 维持旧 item 播放 | 不变 |

```swift
// scrub 开始时降级
player.currentItem?.preferredMaximumResolution = CGSize(width: 960, height: 540)

// scrub 结束 0.5s 后恢复
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    player.currentItem?.preferredMaximumResolution = .zero  // 无限制
}
```

---

## 3. 播放头与时间轴联动规范

### 3.1 播放时时间轴自动滚动（跟随播放头）

剪映行为：播放时，时间轴始终跟随播放头滚动，播放头固定在屏幕中心。

```
播放中每帧（30fps timeObserver）：
  targetOffset = canvas.x(for: playheadTime) - scrollView.frame.width / 2
  scrollView.contentOffset.x = clamp(targetOffset, 0, maxOffset)
  // 不用动画（scrollRectToVisible 有延迟），直接设 contentOffset
```

### 3.2 Scrub 时时间轴不联动

用户用手指拖拽时间轴时（scrollView panGesture）：
- 播放头 x 位置 = `scrollView.frame.width / 2`（固定屏幕中心）
- 播放头时间 = `canvas.time(at: scrollView.contentOffset.x + visibleCenter)`
- **不**触发 scrollView 主动滚动（是用户在滚动，不是代码滚动）

```swift
// TrackCanvasView.handleScroll（scrollViewDidScroll delegate）
guard !isUserScrolling else { return }  // 用户自己滚动时不干预
let t = canvas.time(at: scrollView.contentOffset.x + scrollView.frame.width / 2)
store.selection.playheadTime = t
store.seek(to: t)
```

### 3.3 pps（像素/秒）缩放规范

```
默认 pps：80 pt/s（与 TrackCanvasView.defaultPixelsPerSecond 一致）
最小 pps：20 pt/s（整个工程在一屏内可见，最长 30s）
最大 pps：400 pt/s（精细编辑短片段）

捏合手势：
  newPPS = clamp(gesture.scale * currentPPS, minPPS, maxPPS)
  // 以播放头为缩放锚点，保证播放头屏幕位置不变
  anchorTime = currentPlayheadTime
  anchorX    = scrollView.frame.width / 2  // 播放头固定中心
  newOffset  = canvas.x(for: anchorTime) * (newPPS / currentPPS) - anchorX
```

---

## 4. 主轨道磁吸（Magnetic Timeline）规范

### 4.1 磁吸原则（FCP 设计）

主视频轨道片段：
- **任意时刻不允许有间隙**（gap = black frame）
- **任意时刻不允许有重叠**
- 删除/缩短一个片段 → 后续片段自动前移（ripple delete）
- 插入新片段 → 插入点后的片段自动后移（ripple insert）

音频/字幕/文字轨道：
- **自由排列**，允许间隙，允许重叠（多音轨混音）
- 不参与 ripple 联动

### 4.2 主轨道拉伸联动（ripple trim）

已实现于 `EditorStore.trimSegment`：
```
缩短 seg[i]（右手柄左移）：
  → seg[i].duration -= delta
  → seg[i+1..n].start -= delta（全部前移）

延长 seg[i]（右手柄右移）：
  → seg[i].duration += delta
  → seg[i+1..n].start += delta（全部后移）
  → 同时延长 timeline.duration
```

### 4.3 跨片段拖拽（P1 暂不支持）

主轨道片段顺序调换（拖拽换位）已有 `EditorStore.reorderSegments`，P1 交互实现：
- 长按片段 0.3s → 进入拖拽模式（片段悬浮）
- 拖拽过半到相邻片段 → 触发位置交换
- 松手 → `store.reorderSegments` + ripple 重排

---

## 5. 播放头片段边缘吸附（对标剪映）

### 5.1 吸附触发规则

Scrub 过程中，播放头距任意片段边缘 ≤ 吸附阈值时自动对齐：

```
吸附阈值：max(4pt, 0.05s × currentPPS)
  @ 80pps：4pt = 0.05s   → 吸附阈值 4pt
  @ 400pps：4pt < 20pt   → 吸附阈值 20pt

吸附目标（按优先级）：
  1. 主轨道片段边缘（所有起止点）
  2. 音频轨道片段边缘
  3. 字幕片段边缘
  4. 工程开头 (t=0)
  5. 工程结尾 (t=timeline.duration)
```

### 5.2 吸附视觉反馈

```
吸附触发时：
  - 播放头颜色从 systemRed → systemYellow（持续吸附期间）
  - 轻触觉：UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
  - 吸附线：被吸附片段边缘显示竖线高亮（颜色 #FFD60A，宽 2pt，持续 0.3s）

离开吸附区时：
  - 播放头恢复 systemRed
  - 高亮线消失
```

---

## 6. AVComposition Rebuild 期间的 UX 规范

### 6.1 重建过程中 UI 行为

```
isRebuilding = true（CompositionCoordinator 标志位）

UI 规则：
  - 播放头继续显示当前时间（不闪烁、不跳变）
  - 播放/暂停按钮正常响应
  - 时间轴可继续拖拽（操作缓存，rebuild 完成后合并应用）
  - 预览区保持旧 AVPlayerItem 画面（不黑屏）
  - 可选：预览区右上角显示 spinning indicator（16pt，0.3s 延迟出现）
```

### 6.2 重建完成后状态恢复

```
rebuild 完成后（CompositionCoordinator.rebuild 末尾）：
  1. 恢复 savedTime（isValid && > 0 时 seek）
  2. wasPlaying == true → 自动恢复播放
  3. spinner 消失
```

### 6.3 快速连续编辑的防抖

```
连续操作（如拖拽手柄）：每次 onChange → scheduleRebuild(debounce: 300ms)
前一个 pendingTask 被 cancel，新 task 重新计时
只有松手后 300ms 无操作才真正触发 rebuild

immediate: true 场景（立即重建，不防抖）：
  - 首次加载
  - 添加/删除视频片段
  - 切换素材 URL
```

---

## 7. 播放控制 API 规范

### 7.1 EditorStore 公开 API 约定

```swift
// 所有播放控制走 store，不允许外部直接操作 AVPlayer

store.play()                    // 播放（从当前位置 or 从头）
store.pause()                   // 暂停
store.togglePlayback()          // 切换
store.seek(to: Double)          // 跳转（同时移动播放头 + AVPlayer seek）
store.seekToPreviousSegment()   // 跳到上一片段头部
store.seekToNextSegment()       // 跳到下一片段头部

// 只更新 UI 指示，不驱动 AVPlayer（内部 timeObserver 反向同步用）
store.selection.playheadTime    // 只写 UI 层，外部只读
```

### 7.2 播放头同步双向路径

```
正向（用户操作 → player）：
  store.seek(to:) → activePlayer.seek(to:) + selection.playheadTime = t

反向（player → UI）：
  AVPlayer 周期回调（30fps）→ selection.playheadTime = time.seconds
  仅在 isPlaying == true 时执行反向同步
  scrub 期间（isUserScrolling）：正向优先，暂停反向同步
```

---

## 8. 验收标准

| # | 验收项 | 标准 |
|---|---|---|
| P-01 | Scrub 帧率 | 拖拽时 seek 频率 ≤ 33ms/次，UI 不卡顿 |
| P-02 | Scrub 继续播放 | 拖拽前正在播放，松手后自动继续，无延迟感 |
| P-03 | 播放头居中 | 播放时时间轴跟随滚动，播放头始终在屏幕中央 ±4pt |
| P-04 | 边界约束 | 播放头不超出 [0, timeline.duration]，无论拖拽还是键盘操作 |
| P-05 | 吸附触觉 | 吸附片段边缘时有触觉反馈，误触发率 < 5% |
| P-06 | rebuild 不黑屏 | 编辑操作触发 rebuild 期间，预览区保持上一帧画面 |
| P-07 | 磁吸无间隙 | 主轨道片段增删后，相邻片段无黑帧间隙 |
| P-08 | pps 缩放锚点 | 捏合缩放时，播放头位置在屏幕上保持不动 |
| P-09 | undo 后播放头 | undo 后播放头跳回操作前时间点 |
| P-10 | 分辨率降级 | scrub 中预览分辨率降到 540p，停止后 0.5s 内恢复 |
