# 音频轨道交互规范 v1.0
> 对标产品：剪映 iOS（轨道交互）+ Final Cut Pro（多轨管理架构）
> 适用范围：TimelineKit P1 音频轨道编辑实现

---

## 1. 音频轨道层级定义

```
轨道类型        EditorTrack.kind    zPosition   磁吸行为    用户可见名称
──────────────────────────────────────────────────────────────────────
主视频原生音频  .video（内嵌）       0          随主轨道     [隐含，由 isMuted 控制]
人声配音        .audio (voiceOver)   1          ❌ 自由       配音
背景音乐        .audio (bgm)         2          ❌ 自由       音乐
音效            .audio (sfx, P2)     3          ❌ 自由       音效
──────────────────────────────────────────────────────────────────────
```

**轨道互斥规则**（剪映范式）：
- 同一时刻允许多条音频轨道同时播放；
- 各轨道音量独立；
- 主视频原生音频通过 `VideoContent.isMuted` 开关，不在音频轨道列表中单独显示。

---

## 2. 多轨道音量混合规则

### 2.1 默认音量（对标剪映初始值）

| 轨道类型 | 默认音量 | 最大音量 | 最小音量 |
|---|---|---|---|
| 主视频原生音频 | 1.0（100%）| 2.0（200%）| 0.0 |
| 人声配音 | 1.0 | 2.0 | 0.0 |
| 背景音乐 | 0.3（30%）| 1.0 | 0.0 |
| 音效 | 0.8 | 2.0 | 0.0 |

> 背景音乐默认 30% 的依据：剪映实测，BGM 不压过人声。

### 2.2 AVMutableAudioMix 映射

每条音频轨道对应一个 `AVMutableAudioMixInputParameters`：
```swift
let p = AVMutableAudioMixInputParameters(track: compAudioTrack)
p.setVolume(Float(trackVolume), at: .zero)
// 淡入淡出（P2）：p.setVolumeRamp(fromStartVolume:toEndVolume:timeRange:)
```

### 2.3 音量包络（P2 预留）
P1 只支持固定音量；P2 加入音量包络（关键帧曲线）：
- 存储：`AudioContent.volumeKeyframes: [TimeRange: Double]`
- 渲染：`setVolumeRamp` 每段分别设置
- 淡入/淡出：片段首尾各 0.3s 默认淡出（可关闭）

---

## 3. 音频片段拖拽交互规范

### 3.1 磁吸规则（对标剪映/FCP）

```
主视频轨道（isMainTrack）：
  - 片段间无间隙，自动磁吸（magnetic timeline）
  - 删除片段 → 后续片段自动前移

音频轨道（非主轨道）：
  - 片段自由拖拽，无磁吸
  - 允许片段之间有间隙（静音区间）
  - 允许多个片段时间重叠（叠加播放）
  - 拖拽时显示时间浮窗（格式：00:00.0，精确到 0.1s）
```

### 3.2 拖拽吸附触发条件

距离 < 8pt（约 0.1s @80pps）时触发吸附：
- 吸附到：片段首尾边缘、主轨道片段边缘、播放头位置、工程开头/结尾

吸附后有轻触觉反馈（`UIImpactFeedbackGenerator.style = .light`）。

### 3.3 拖拽时 AVComposition 行为

```
拖拽中（onChanged）：
  → store.moveSegment(id:to:) 实时更新 timeline（不进 undo 栈）
  → 300ms 防抖触发 CompositionBuilder rebuild
  → 预览跟随更新

松手（onEnded）：
  → store.mutate("移动音频") 写入 undo 栈
  → 立即触发 rebuild（immediate: true）
```

---

## 4. 音频片段手柄拉伸规范

### 4.1 左手柄（裁入点）

```
边界约束：
  leftEdge >= 0
  leftEdge <= rightEdge - minDuration（最小时长 0.3s）
  sourceStart = newLeftEdge - originalLeftEdge（相对偏移，不能超过素材起点）

拉伸逻辑（非磁吸轨道，不影响相邻片段）：
  targetRange.start += delta
  targetRange.duration -= delta
  sourceRange.start   += delta
```

### 4.2 右手柄（裁出点）

```
边界约束：
  rightEdge >= leftEdge + minDuration
  rightEdge <= leftEdge + (sourceDuration - sourceStart)  // 不能超出素材总时长
  可以超出工程当前总时长 → 自动撑长工程（timelineDuration 更新）

拉伸逻辑：
  targetRange.duration += delta
  sourceRange.duration  += delta（如果 sourceRange 不为 nil）
```

### 4.3 最小/最大时长

| 轨道类型 | 最小时长 | 最大时长 |
|---|---|---|
| 音频 | 0.3s | 素材总时长 |
| 视频（主轨道）| 0.5s | 素材总时长 |
| 字幕 | 0.5s | 无限制 |

---

## 5. 音频波纹可视化规范（对标剪映）

### 5.1 波形数据来源

```swift
// 使用 AVAssetReader + AVAssetReaderTrackOutput 提取 PCM 数据
// 采样降采样到每 4pt 宽度一个采样点（80pps 下约每 0.05s 一个点）
// 缓存在 WaveformCache（keyed by materialID）
```

### 5.2 渲染规格

| 参数 | 值 | 说明 |
|---|---|---|
| 波形颜色 | `#4CAF50` (绿色) | 剪映配音绿；BGM 用 `#2196F3` 蓝 |
| 波形高度 | 轨道高度 × 0.7 | 留边距 |
| 背景色 | 轨道底色 × 0.3 alpha | 区分视频轨道 |
| 最小幅度 | 2pt | 完全静音时显示细线，不消失 |
| 渲染方式 | `CAShapeLayer` + `UIBezierPath` | 不用 `Core Graphics` 直绘，利于动画 |

### 5.3 性能约束

- 波形提取在后台队列执行，不阻塞 UI；
- 时间轴缩放时（pps 变化）异步重新采样；
- 缓存有效期：素材文件不变则永不过期；
- 内存上限：单素材波形数据 ≤ 2MB。

---

## 6. 静音、独奏、锁定（预留规范）

P1 只实现 `isMuted`；P2 实现完整三态：

| 功能 | 触发 | 存储字段 | AVMix 行为 |
|---|---|---|---|
| 静音（Mute）| 点击 M 图标 | `AudioContent.isMuted` | `setVolume(0, at: .zero)` |
| 独奏（Solo）| 长按轨道 | `EditorTrack.isSolo`（P2）| 其他轨道 volume → 0 |
| 锁定（Lock）| 双击轨道 | `EditorTrack.isLocked`（P2）| 手势事件忽略 |

静音切换：**不重建 AVComposition**，直接修改 `AVMutableAudioMixInputParameters.volume`（通过替换 `audioMix` 实现，不替换 `composition`）。

---

## 7. 音频导入流程规范（P1 实现范围）

```
用户选择音频文件（系统 DocumentPicker）
  → 复制到 app 沙盒 caches/audio/
  → EditorAsset(type: .audio, localURL: sandboxURL)
  → MaterialsPool.add(asset)
  → EditorSegment(materialID: asset.id, targetRange: ..., content: .audio(...))
  → store.mutate("添加音频")
  → CompositionBuilder 自动 rebuild（300ms debounce）
```

BGM 自动循环（isLooping == true）：
```swift
// 在 buildAudio 阶段：重复插入直到填满 timeline.duration
while insertedEnd < totalDuration.seconds {
    try? compAudioTrack.insertTimeRange(srcRange, of: srcTrack, at: targetAt)
    insertedEnd += sourceDuration
    targetAt = CMTime(seconds: insertedEnd, preferredTimescale: 600)
}
```

---

## 8. 验收标准

| # | 验收项 | 标准 |
|---|---|---|
| A-01 | 多轨混音 | 视频原声 + BGM + 配音同时播放，无爆音，音量符合默认值 |
| A-02 | BGM 自动循环 | isLooping=true 的 BGM 片段无缝循环到工程结尾 |
| A-03 | 静音切换 | isMuted 切换不触发 AVComposition 重建，响应 < 100ms |
| A-04 | 自由拖拽 | 音频片段拖拽不磁吸，可在任意时间点落位 |
| A-05 | 手柄约束 | 右手柄拉伸不超出素材总时长，左手柄不低于 0 |
| A-06 | 吸附反馈 | 距吸附点 8pt 内触发轻触觉 + 视觉对齐线 |
| A-07 | undo/redo | 移动/拉伸/删除音频均可撤销 |
| A-08 | 波形渲染（P1 可选）| 波形在轨道区域正确显示，宽度随 pps 缩放同步 |
