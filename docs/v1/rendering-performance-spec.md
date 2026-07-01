# 渲染性能约束 & 内存管控规范

> TimelineKit 渲染开发铁律 · V1.0
>
> 本文档所有规则为强制约束（MUST），开发时不得绕过。
> 违反任何一条均视为阻塞性 bug，不得上线。

---

## 一、总体性能目标

| 指标 | 目标值 | 降级下限 |
|------|-------|---------|
| 预览播放帧率 | ≥ 30fps | ≥ 24fps（低端设备） |
| Scrubbing 帧响应延迟 | ≤ 100ms（含缓存命中） | ≤ 300ms（缓存未命中） |
| Composition rebuild 耗时 | ≤ 500ms（10 个片段以内） | ≤ 2s（50 个片段） |
| 导出速度比 | ≥ 1× 实时（即 10s 视频 ≤ 10s 导出） | — |
| 预览内存峰值 | ≤ 180MB（主进程） | ≤ 250MB（含系统缓冲） |
| OOM 发生率 | 0（任何测试场景） | — |

---

## 二、分辨率 & 帧率动态降级策略

### 2.1 降级触发条件

```
检测频率：每 3 秒采样一次 GPU 帧率（用 CADisplayLink 累计帧数计算）

条件 A: GPU framerate < 24fps（连续采样 2 次）
    → 预览分辨率降至下一档

条件 B: os_proc_available_memory() < 100MB
    → 同条件 A，额外暂停后台 Rebuild 任务

条件 C: 收到 UIApplication.didReceiveMemoryWarningNotification
    → 立刻降至最低档，清空帧缓存，暂停预渲染
```

### 2.2 分辨率档位

| 档位 | 分辨率（16:9） | 触发条件 |
|------|-------------|---------|
| H（高） | 1280×720 | 默认 |
| M（中） | 960×540  | 条件 A |
| L（低） | 640×360  | 条件 A × 2 或条件 B |
| Min（静帧） | 最近关键帧 × 0.5 | 条件 C |

静帧模式：暂停播放，仅显示当前关键帧；用户手动点击播放后尝试恢复到 L 档。

### 2.3 升档恢复

降级后每 10 秒尝试升回上一档：
- 连续 5 秒帧率 ≥ 30fps → 升档
- 升档后若 3 秒内再次跌到触发条件 → 永久锁在当前档，不再尝试升档（防抖动）

### 2.4 视频合成降级的实现

```swift
// 在 CompositionCoordinator 中（伪代码）
func renderSize(for tier: ResolutionTier, originalSize: CGSize) -> CGSize {
    let scale: CGFloat
    switch tier {
    case .high:   scale = 1.0
    case .medium: scale = 0.75
    case .low:    scale = 0.5
    case .min:    scale = 0.25
    }
    return CGSize(
        width:  floor(originalSize.width  * scale / 2) * 2,  // 保持偶数
        height: floor(originalSize.height * scale / 2) * 2
    )
}
// 设置到 AVMutableVideoComposition.renderSize
```

---

## 三、内存管控规则

### 3.1 内存分层预算

```
总预算 = 180MB（主进程可用峰值）

分配：
  AVFoundation 解码器缓冲区：≤ 80MB
  ThumbnailCache（帧缓存）：  ≤ 50MB（LRU，超出自动淘汰）
  AssetCache（URLAsset）：    ≤ 20MB（无帧数据，仅元信息）
  UI / SwiftUI：              ≤ 30MB
```

### 3.2 AssetCache 规则

```
规则 1：每个 AVURLAsset 必须从 AssetCache.shared 获取，禁止在 CompositionBuilder 外直接 `AVURLAsset(url:)`。

规则 2：App 进入后台 → 调用 AssetCache.shared.purgeDecodedCache()
        App 收到内存警告 → 调用 AssetCache.shared.purgeAll()

规则 3：AssetCache 使用 NSCache，maxCostLimit = 20 * 1024 * 1024（20MB）
        cost = asset 已加载的 track 数 × 10_000（粗估）

规则 4：URLAsset 创建时必须指定 options:
        [AVURLAssetPreferPreciseDurationAndTimingKey: false]  // 禁止预扫全文件
```

### 3.3 ThumbnailCache 规则

```
规则 1：ThumbnailCache 使用 NSCache，maxCostLimit = 50 * 1024 * 1024（50MB）
        cost = CGImage.width × CGImage.height × 4（RGBA bytes）

规则 2：每次 Scrubbing 请求必须经节流器，最小间隔 ≥ 30ms：
        guard Date().timeIntervalSince(lastThumbRequest) >= 0.03 else { return nil }

规则 3：App 收到内存警告 → ThumbnailCache.shared.purge()（全清）

规则 4：帧生成分辨率固定 320pt 宽（等比），禁止按屏幕分辨率生成全尺寸帧用于缩略图
```

### 3.4 CompositionBuilder 规则

```
规则 1：CompositionBuilder.build() 必须在 Swift actor（后台线程）上运行，禁止 MainActor。

规则 2：每次调用前取消上一次未完成的 Task（防止多次 rebuild 并发积压）：
        pendingRebuildTask?.cancel()
        pendingRebuildTask = Task { ... }

规则 3：AVMutableComposition 禁止复用/增量修改 — 每次 rebuild 创建全新实例。
        （增量修改难以保证线程安全，且 Composition 本身不大）

规则 4：build() 完成后立即在 MainActor 上调用 player.replaceComposition()，
        旧 AVPlayerItem 会被 ARC 释放，释放其持有的解码器资源。
```

### 3.5 后台/前台切换规则

```swift
// App 生命周期响应（在 CompositionCoordinator 中注册）

// 进入后台
NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification) {
    player.pause()
    pendingRebuildTask?.cancel()
    ThumbnailCache.shared.purge()
    AssetCache.shared.purgeDecodedCache()
    player.replaceCurrentItem(with: nil)  // 释放解码器
}

// 回到前台
NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification) {
    // 重新构建（用户可能已返回编辑状态）
    scheduleRebuild(for: currentTimeline, delay: .milliseconds(500))
}
```

---

## 四、编辑→渲染解耦规则

### 4.1 UI 线程绝不等待渲染

```
❌ 禁止：
let result = await compositionBuilder.build(from: timeline)  // 在 MainActor 上 await 超过 16ms
player.replaceComposition(result)

✅ 正确：
Task {
    let result = await compositionBuilder.build(from: timeline)  // 后台 actor
    await MainActor.run { player.replaceComposition(result) }    // 仅 swap 在主线程
}
```

### 4.2 Scrubbing 不触发 Rebuild

```
❌ 禁止：
// 时间轴拖拽时调用 rebuild
store.selection.playheadTime = newTime
scheduleRebuild(...)

✅ 正确：
// 时间轴拖拽只做 seek，不 rebuild
store.selection.playheadTime = newTime
player.seek(to: newTime)               // AVPlayer seek（异步，不阻塞 UI）
thumbnailCache.frame(at: newTime, ...)  // 从缓存取当前帧缩略图
```

### 4.3 字幕/文字修改不触发 Rebuild

```
❌ 禁止：
// 修改文字后触发完整 rebuild（AVMutableComposition 重建 500ms+ 卡顿）
store.mutateTextContent(...) → scheduleRebuild(...)

✅ 正确：
// 修改文字后只更新 CALayer（<16ms）
store.mutateTextContent(...) → subtitleLayerCoordinator.updateLayers(from: timeline)
// subtitleLayerCoordinator 只操作 CALayer 树，不碰 AVMutableComposition
```

---

## 五、Scrubbing 节流规范

```
节流目标：每次触发间隔 ≥ 30ms（≈ 33fps 上限）
          GPU 帧率低于 24fps 时自动降至 ≥ 67ms（≈ 15fps）

实现方式：
  var lastScrubTime = Date.distantPast

  func handleScrub(to time: Double) {
      let now = Date()
      guard now.timeIntervalSince(lastScrubTime) >= throttleInterval else { return }
      lastScrubTime = now
      player.seek(to: time)
  }

防抖（松手时精确定位）：
  func handleScrubEnd(to time: Double) {
      // 松手时无节流，精确 seek
      player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
  }
```

---

## 六、Rebuild 防抖规范

```
基础防抖延迟：300ms
  - 覆盖 95% 连续编辑场景（快速裁剪 / undo/redo 连按）

例外情况（立即 rebuild，延迟 = 0ms）：
  - 添加 / 删除轨道
  - 切换时间线（完全不同的 taskID）
  - 从后台回到前台

绝不立即 rebuild 的操作：
  - playheadTime 变化（scrubbing）
  - isSelected 变化（选中状态）
  - 仅文字内容 / 样式变化（走 CALayer 路径）
```

---

## 七、导出性能规范

| 规则 | 说明 |
|------|------|
| 导出禁止阻塞主线程 | 用 `async/await` + progress 回调，UI 可操作 |
| 导出期间禁止同时 rebuild 预览 | 导出时 `pendingRebuildTask?.cancel()` |
| 导出进度更新频率 | 每 500ms 更新一次 UI progress（不必每帧刷新） |
| 导出失败重试 | 最多 1 次自动重试；第 2 次失败提示用户 |
| 导出文件命名 | `export_{taskID}_{timestamp}.mp4`，写入 `Documents/Exports/` |

---

## 八、测试验收标准（性能验收必须通过）

### 8.1 Scrubbing 压力测试
- 操作：快速左右滑动时间轴 10 秒
- 验收：帧率不低于 15fps，内存不超过 250MB，无崩溃

### 8.2 Rebuild 压力测试
- 操作：连续快速 undo/redo 20 次
- 验收：UI 无卡顿（主线程帧率 ≥ 60fps），rebuild 任务不积压（任一时刻最多 1 个 pending）

### 8.3 后台切换测试
- 操作：编辑中按 Home → 等待 5s → 回到 App
- 验收：内存在后台降至 < 100MB，回到前台 2s 内恢复预览

### 8.4 大工程测试
- 场景：主轨道 20 个片段 + 5 条字幕轨 + 1 条音频轨
- 验收：首次 rebuild ≤ 2s，后续 rebuild ≤ 800ms，预览帧率 ≥ 24fps

### 8.5 导出测试
- 场景：10s 720p 视频 + 字幕 + 背景音乐
- 验收：导出时间 ≤ 10s，输出文件可用 AVPlayer 正常播放，无音视频不同步

---

## 九、变更历史

| 日期 | 版本 | 说明 |
|------|------|------|
| 2026-05-13 | V1.0 | 初稿，定义所有性能约束、内存规则、降级策略 |
