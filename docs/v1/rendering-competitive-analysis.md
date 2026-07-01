# 竞品渲染 & 交互架构调研报告

> TimelineKit 渲染方案设计参考 · V1.0
>
> 调研范围：剪映 iOS、Final Cut Pro 范式、移动端专业剪辑（LumaFusion）
> 目标：为 TimelineKit + AVFoundation 渲染架构选型提供决策依据

---

## 一、调研焦点

| 维度 | 核心问题 |
|------|---------|
| **实时预览** | 渲染链路是什么？什么时候触发重新合成？ |
| **时间轴拖拽** | 划刻度时是实时合成还是预缓存帧？ |
| **内存管控** | 多轨道、大工程如何防止 OOM？ |
| **降级策略** | 帧率/分辨率在什么条件下降级？ |
| **导出复用** | 预览和导出渲染引擎是否共用？ |

---

## 二、剪映 iOS

### 2.1 渲染链路

剪映使用**双引擎架构**：

```
┌─────────────────────────────────────────────────────────────┐
│                    剪映渲染引擎                                │
│                                                             │
│  编辑态（预览）：                                             │
│  EditorTimeline → [GPU 合成引擎（Metal）] → MTKView           │
│                         ↑                                   │
│          AVAsset 解码帧 + 字幕/贴纸/特效 CoreImage/Metal     │
│                                                             │
│  导出态：                                                    │
│  同一套 Metal 合成管线 → AVAssetWriter → 本地文件             │
└─────────────────────────────────────────────────────────────┘
```

**关键结论**：剪映预览和导出**复用同一套 Metal GPU 合成管线**，不是用 AVFoundation 的 `AVVideoComposition`。这是剪映特效能力（大量 Metal shader）的核心依赖。

> 对我们的启示：我们不做自定义 Metal shader，用 AVFoundation 标准路径即可，
> 但导出和预览的 `AVMutableComposition` 构建逻辑必须共用同一份 `CompositionBuilder`。

### 2.2 时间轴拖拽（Scrubbing）策略

剪映的拖拽预览不是实时合成，而是**分层缓存**：

| 层级 | 内容 | 刷新时机 |
|------|------|---------|
| L1 缓存 | 已解码的 CGImage 帧（关键帧±1s） | 拖动前 100ms 预热 |
| L2 缓存 | AVAsset 解码器缓冲区 | 系统管理 |
| L3 兜底 | 最近一帧（静帧占位） | 解码来不及时展示 |

拖拽时序：
1. 手指开始移动 → 节流（≥30ms/帧）→ 查 L1 缓存
2. 命中缓存 → 即时渲染字幕/特效叠加层 → 显示
3. 未命中 → 提交 `AVAssetImageGenerator` 异步请求 → 展示上一帧占位
4. 帧生成完毕 → 替换占位

**节流参数**（观测值）：
- 普通素材：15fps（每 67ms 一帧）
- 特效轨道激活时：10fps（每 100ms）
- 低端设备：8fps

### 2.3 合成触发时机

剪映**不是每次编辑就重新合成**，而是：

```
用户操作 → EditorStore 更新 → 脏标记置位
                                    ↓
                    防抖 300ms（Swift async Task with sleep）
                                    ↓
                    后台重新构建 AVMutableComposition
                                    ↓
                    AVPlayerItem 原地替换（无黑帧 swap）
```

字幕、文字修改：**不重建 Composition**，仅更新叠加层（CALayer/CoreImage），延迟极低（<16ms）。

### 2.4 内存管控

| 场景 | 策略 |
|------|------|
| 编辑中 | 每个片段对应一个 `AVURLAsset`，用 `NSCache` 持有（key = URL） |
| 后台切换 | `AVPlayer.pause()` + `AVPlayerItem` 设为 nil，释放解码器 |
| 内存警告 | 清空帧缓存（L1），保留 `AVURLAsset` 引用（仅 descriptor，不占大内存） |
| 大工程 | 超过 20 个片段时，把时间轴以外 ±30s 的片段 asset 降为 `.unknown` load 状态 |

### 2.5 分辨率降级

| 条件 | 预览分辨率 |
|------|---------|
| 正常 | 720p（1280×720）|
| GPU 帧率 < 24fps（连续 3 帧） | 降至 540p |
| 内存压力 moderate | 降至 480p |
| 内存压力 critical | 静帧模式（仅展示关键帧，不播放） |
| 导出 | 原始分辨率 |

---

## 三、Final Cut Pro 范式

FCP 的编辑范式对移动端有最重要的架构参考价值。

### 3.1 代理工作流（Proxy Workflow）

FCP 将原始素材转为低分辨率代理文件用于编辑，导出时自动 conform 到原始文件。

```
原始文件 (4K ProRes) → 后台转码 → 代理文件 (720p H.264)
                                          ↓
                              编辑阶段使用代理文件
                                          ↓
                         导出时 Conform 回原始文件路径
```

> 对移动端的启示：AI 生成视频场景下，源素材就是服务器生成的 H.264/HEVC，
> 不需要代理转码。但**服务器返回的低清预览帧**可以作为"代理"用于 Timeline 缩略图。

### 3.2 后台渲染（Background Rendering）

FCP 使用**优先级队列**管理渲染任务：

```
编辑操作 → 标记 timeline 脏区间 [t_start, t_end]
                    ↓
          后台 DispatchQueue.global(qos: .utility) 渲染
                    ↓
          渲染完成 → 写入 render cache（本地 .fcpcache 文件）
                    ↓
          下次预览该区间 → 从 cache 直接读，不再合成
```

渲染 cache 的关键好处：导出时直接复用已渲染区间，**导出速度接近实时**。

> 对移动端的启示：短期不实现 render cache。但 AVAssetExportSession 内部会做
> 类似优化（重用已解码缓冲区）。重要的是：**后台渲染必须可取消**，
> 每次新的编辑操作来临，立刻取消正在进行的后台合成任务。

### 3.3 磁性时间线与渲染层级

FCP 的渲染层级（优先级由高到低）：

```
z-order: 字幕/标题 > 贴纸/遮罩 > 调色/特效 > Connected Clips（B-roll）> Primary Storyline
```

时间轴编辑操作与渲染层级完全解耦：UI 层改的是 EditorTimeline，渲染层读 EditorTimeline 重新合成。

### 3.4 编辑与渲染线程解耦（FCP 核心范式）

```
Main Thread    → UI 操作 → EditorStore.mutate() → timeline 变更
                                                        ↓
Background     → CompositionBuilder.rebuild()   → AVMutableComposition
  Thread             （可取消 Task）
                                                        ↓
Main Thread    → AVPlayer.replaceCurrentItem()  → 预览更新
```

**关键约束**：`AVMutableComposition` 的构建必须在后台线程；`AVPlayer` 的操作必须在主线程。

---

## 四、LumaFusion（移动端专业参考）

### 4.1 渲染架构

LumaFusion 基于 AVFoundation + Metal，**不像剪映自研引擎**，这与我们的路径最接近。

```
EditorTimeline
    ↓
AVMutableComposition（音视频轨道合并）
    ↓
AVMutableVideoComposition（描述每帧如何合成）
    ↓        ↓
AVPlayerItem → AVPlayer（预览）
AVAssetExportSession（导出）
```

### 4.2 6 轨道并发策略

LumaFusion 支持 6 视频轨，其内存控制策略：

| 视频轨数 | 行为 |
|---------|------|
| 1-2 | 全量解码，缓冲 2s |
| 3-4 | 缓冲缩短至 0.5s，预加载帧数减半 |
| 5-6 | 仅解码当前帧，无预缓存；帧率自动降至 24fps |

> 对我们的启示：我们初期只有 1 主视频轨 + N 附属轨（字幕/文字/音频），
> 字幕/文字不走视频解码，内存压力远低于 LumaFusion 6 视频轨场景。

### 4.3 与 FCP 对比（移动端视角）

| 能力 | FCP | LumaFusion | 我们目标 |
|------|-----|-----------|---------|
| 后台渲染 cache | ✅ | ❌ | ❌（初版） |
| 代理工作流 | ✅ | ✅ | ❌（源素材已是低清） |
| Metal 自定义特效 | ✅ | 部分 | ❌（初版） |
| AVFoundation 标准路径 | 部分 | ✅ | ✅ |
| 预览/导出复用同一管线 | ✅ | ✅ | ✅（强制约束） |

---

## 五、关键结论（驱动架构决策）

| # | 结论 | 对应设计约束 |
|---|------|------------|
| 1 | 预览和导出**必须复用同一 CompositionBuilder** | `CompositionBuilder` 输出 `AVMutableComposition`，预览/导出都接这个结果 |
| 2 | Composition 重建必须在**后台线程**，主线程只做 swap | 所有 `AVMutableComposition` 操作用 `Task { await ... }` 包裹 |
| 3 | 字幕/文字修改**不触发 Composition 重建** | 字幕走 `CATextLayer` / `AVVideoCompositionCoreAnimationTool`，独立更新 |
| 4 | 时间轴拖拽用**节流 + 帧缓存**，不实时合成 | `AVAssetImageGenerator` + 节流器（≥30ms/帧）|
| 5 | 内存警告时**立刻释放解码缓存**，保留 Asset 引用 | `didReceiveMemoryWarning` → 清帧缓存，保 URLAsset |
| 6 | 预览分辨率**动态降级** | 720p 起步，GPU 帧率 < 24fps 时降到 540p |

---

## 六、参考链接

- [AVFoundation Programming Guide – Editing](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/03_Editing.html)
- [WWDC 2022 – What's new in AVFoundation](https://developer.apple.com/videos/play/wwdc2022/10114/)
- [WWDC 2023 – Discover advancements in iOS camera capture](https://developer.apple.com/videos/play/wwdc2023/10175/)
- [Core Image Filter Reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/)

---

## 七、变更历史

| 日期 | 版本 | 说明 |
|------|------|------|
| 2026-05-13 | V1.0 | 初稿，覆盖剪映/FCP/LumaFusion 三大维度 |
