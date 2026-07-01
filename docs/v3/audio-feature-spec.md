# 音频功能规范（v3）

> 版本：v3.0
> 状态：规范定稿，待实现
> 对标产品：剪映 iOS（主要）+ Final Cut Pro + LumaFusion
> 依赖：[multi-track-architecture-spec.md](multi-track-architecture-spec.md)（轨道分配）；v1 [audio-track-interaction-spec.md](../v1/audio-track-interaction-spec.md)（音频交互基线）；v1 [WaveformProvider](../../Sources/TimelineKit/Rendering/WaveformProvider.swift)（已生产可用）

---

## 一、竞品分析

### 1.1 剪映 iOS —— 对标主体

底部「音频」一级入口的二级面板分类：

| 入口 | 行为 |
|---|---|
| **音乐** | 内置音乐库（云端）+ 我的本地导入 |
| **音效** | 内置音效库（云端） |
| **提取音乐** | 选择相册视频 → 一键分离音频 |
| **录音** | 录制旁白配音 |
| **抖音收藏** | 关联抖音收藏的音乐 |

剪映核心模型：**提取音频与本地导入并列为音乐子入口，音效独立分类，云端素材库为主**。

### 1.2 Final Cut Pro —— 专业参考

- **Music and Sound Browser**：访问 macOS 资源库 / iTunes / Logic Sound Library
- **Voiceover Tool**：直接在 viewer 录配音
- **音频附着模式**：Connected Clip 锚定到 Primary Storyline 任意时间点
- 无「提取音频」单独入口，依靠 Detach Audio 命令完成

FCP 模型偏专业，无对标价值；但「Detach Audio」对应剪映「提取音频」，技术实现思路一致。

### 1.3 LumaFusion —— iPad 参考

- 音频导入：iTunes Library / Files App / Audio Recorder
- 多音轨：最多 6 条
- 波形：必显，可关
- 音量曲线：关键帧

LumaFusion 的「Files App」即 `UIDocumentPickerViewController`，是 iOS 上唯一可用的本地音频选择路径（PHPicker 不支持 audio 媒体类型）。

### 1.4 竞品对比汇总

| 维度 | 剪映 | FCP | LumaFusion | **本规范定案** |
|---|---|---|---|---|
| 提取音频 | ✅ 一级菜单 | Detach Audio 命令 | ❌ | **✅ 一级菜单** |
| 本地音乐导入 | ✅（沙盒文件 + iTunes） | iTunes / Music.app | DocumentPicker | **DocumentPicker (UTType.audio)** |
| 内置音乐库 | ✅ 云端 | 系统资源库 | iTunes | **❌ v3 不做（预留入口）** |
| 内置音效库 | ✅ 云端 | 系统资源库 | Files App | **❌ v3 不做（预留入口灰显）** |
| 录音 | ✅ | ✅ | ✅ | **❌ v3 不做** |
| 波形 | ✅ 默认开 | ✅ | ✅ | **✅ 默认开（v1 已落 [WaveformProvider](../../Sources/TimelineKit/Rendering/WaveformProvider.swift)）** |
| 磁吸对齐音效 | ✅ 触觉 + 视觉 | ✅ 触觉 | ✅ | **✅ 触觉反馈（沿用 v1 规范）** |
| 音量曲线（关键帧）| ✅ | ✅ | ✅ | **❌ v3 不做（全局滑块即可）** |
| 淡入淡出 | ✅ | ✅ | ✅ | **❌ v3 不做（字段已存在，不接 UI）** |

> **定案依据**：v3 是首次落地音频能力的版本，先做「拿一段视频就能加 BGM」最大刚需，其余高级能力延后。提取音频、本地导入、波形、磁吸四件齐活就达到「零门槛配 BGM」目标。

---

## 二、规则定义

### 2.1 二级面板入口（`.audio` 分类）

[EditorBottomToolbar](../../Sources/TimelineKit/Views/EditorBottomToolbar.swift) 的 `EditorSecondaryToolPanel` 在 `case .audio:` 分支填入三个 `toolButton`：

| 顺序 | 标题 | 图标 | enabled | 触发动作 |
|---|---|---|---|---|
| 1 | 提取音频 | `waveform.path.badge.minus` | ✅ | 调用 `AudioExtractor.flowController.start()` |
| 2 | 本地音乐 | `music.note.list` | ✅ | 调用 `AudioImporter.flowController.start()` |
| 3 | 音效 | `speaker.wave.2.bubble` | ❌（灰显）| 不触发，仅占位 |

### 2.2 提取音频流程

```
用户点击「提取音频」
  → PHPickerViewController(filter: .videos, selectionLimit: 1)
  → 用户选定一个视频
  → AudioExtractor.extract(from: PHPickerResult) -> URL
       ├─ AVAssetReader 解码源视频音频轨
       ├─ AVAssetWriter 写入 m4a（AAC, 256 kbps, mono → stereo 透传）
       └─ 落地至 AssetDownloadManager.sharedAssetURL(extension: "m4a")
  → 创建 EditorAsset(type:.audio, localURL: extractedURL)
  → 创建 EditorSegment(content:.audio(AudioContent(volume:1.0)), targetRange: 当前播放头 + 实际音频时长)
  → store.addSegmentAutoTrack(kind:.audio, segment: newSegment)
```

提取耗时：30 秒 720p 视频在 iPhone 14 上 ≤ 2.5s（验收 KPI）。

### 2.3 本地音乐流程

```
用户点击「本地音乐」
  → UIDocumentPickerViewController(forOpeningContentTypes:[.audio, .mp3, .mpeg4Audio, .wav])
  → 用户选定一个本地音频文件
  → AudioImporter.import(at: pickedURL) -> URL
       ├─ 启动 startAccessingSecurityScopedResource
       ├─ 复制到 AssetDownloadManager.sharedAssetURL（避免临时 URL 失效）
       └─ 探测音频时长（AVAsset.load(.duration)）
  → 同提取音频后段：创建 asset / segment / addSegmentAutoTrack
```

**为什么不用 PHPicker**：iOS 17 的 PHPicker `PHPickerFilter` 不支持 audio 媒体类型；DocumentPicker 是当前唯一的本地音频选择路径。

### 2.4 落点策略

新音频片段的 `targetRange.start` 取值优先级：

```
1. 当前播放头时间 playheadTime
2. 若 playheadTime + audioDuration 超出当前 timeline 总时长 → 自动延长 timeline
3. 若新 segment 与 .audio 轨现有片段冲突 → 触发 multi-track 自动分轨（[multi-track-architecture-spec.md §2.2](multi-track-architecture-spec.md)）
```

### 2.5 基础编辑（沿用 v1）

| 操作 | 实现 |
|---|---|
| 裁剪（左右手柄） | 复用 [SegmentBlockView](../../Sources/TimelineKit/Views/TrackCanvasView.swift) Trim 路径，约束见 v1 [audio-track-interaction-spec §4](../v1/audio-track-interaction-spec.md) |
| 分割 | `EditorStore.splitSegment(id:at:)`（v1 已有） |
| 删除 | `EditorStore.deleteSegment(id:)`（v1 已有） |
| 拖动 | 自由拖拽（v1 规则），不磁吸到主轨片段；磁吸到时间刻度网格 |
| 全局音量 | 顶部工具栏 / 设置面板的 master volume 滑块（v1 已存在），不在二级面板内 |
| 单段静音 | `AudioContent.isMuted` 切换；不重建 composition（v1 已落） |
| 单段音量 | v3 暂不开放单段音量 UI，沿用默认 `volume = 1.0` |

### 2.6 磁吸对齐音效反馈

v1 [audio-track-interaction-spec §3.2](../v1/audio-track-interaction-spec.md) 已规定 8pt 内触发吸附 + `UIImpactFeedbackGenerator(.light)`。v3 在此基础上补一条：**对齐主轨片段边缘 / 播放头时额外播放 12 kHz 短促 system sound（300ms 内 ≤ 1 次）**。

```swift
private let snapSoundID: SystemSoundID = {
    var sid: SystemSoundID = 0
    if let url = Bundle.module.url(forResource: "snap_tick", withExtension: "caf") {
        AudioServicesCreateSystemSoundID(url as CFURL, &sid)
    }
    return sid
}()

func playSnapFeedback() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    AudioServicesPlaySystemSound(snapSoundID)  // 受 throttle 控制
}
```

`snap_tick.caf` 资源由 v3 新增（约 80 ms 时长，存放于 TimelineKit Bundle Resources）。

### 2.7 波形可视化

[WaveformProvider](../../Sources/TimelineKit/Rendering/WaveformProvider.swift) 已生产可用且接入 [TrackCanvasView](../../Sources/TimelineKit/Views/TrackCanvasView.swift)（v1 P1-T5）。v3 唯一新增工作：

- 提取音频 / 本地导入完成后，确保 `EditorAsset.localURL` 在 `addSegment` 之前已写入；否则 `WaveformProvider` 会拿到空 URL 导致波形显示空白。
- 验证流程：在 `AudioExtractor` / `AudioImporter` 的 actor 内**先**完成文件落地，**再**回主线程触发 `EditorStore.addSegmentAutoTrack`。

---

## 三、数据模型

### 3.1 现有模型（v1，无改动）

```swift
public struct AudioContent: Sendable, Hashable, Codable {
    public var volume: Double
    public var fadeInDuration: Double
    public var fadeOutDuration: Double
    public var isLooping: Bool
    public var isMuted: Bool
}
```

v3 不改动现有字段语义；新字段 `ttsSource` 见 [tts-spec.md §3](tts-spec.md)。

### 3.2 EditorAsset 用法

```swift
let asset = EditorAsset(
    type: .audio,
    localURL: extractedOrImportedURL,
    nativeDuration: audioDurationInSeconds  // 关键：用于右手柄上限 cap
)
```

`nativeDuration` 提供 v1 trim-stretch-spec 的右手柄约束（`rightEdge ≤ leftEdge + (nativeDuration - sourceStart)`）。

---

## 四、实现方案

### 4.1 新增 Services 文件结构

```
Packages/TimelineKit/Sources/TimelineKit/Services/
├── AudioExtractor.swift   ← actor，AVAssetReader + AVAssetWriter
├── AudioImporter.swift    ← actor，DocumentPicker 桥接 + 文件落地
└── (TTSService.swift)     ← 见 [tts-spec.md]
```

### 4.2 AudioExtractor

```swift
public actor AudioExtractor {
    public static let shared = AudioExtractor()

    public enum Error: Swift.Error {
        case noAudioTrack
        case readerSetupFailed
        case writerSetupFailed
        case cancelled
    }

    /// 从视频文件中提取音频并写入 m4a 文件。
    /// - Parameter videoURL: 源视频 file URL（需已 startAccessingSecurityScopedResource 或为可访问路径）
    /// - Returns: 输出 m4a 的 file URL（位于 ApplicationSupport/TimelineKit/Assets/_shared/{sha1}.m4a）
    public func extract(from videoURL: URL, progress: ((Double) -> Void)? = nil) async throws -> (url: URL, duration: Double)
}
```

实现要点：

1. **复用磁盘缓存**：以源视频 URL bookmarkData + 修改时间为 cache key，命中直接返回（提取同一视频多次复用）。
2. **AVAssetReader 配置**：`AVAssetReaderAudioMixOutput`，PCM 输出 44.1 kHz / 16-bit / stereo。
3. **AVAssetWriter 配置**：`AVFileType.m4a`，`AVFormatIDKey = kAudioFormatMPEG4AAC`，`AVEncoderBitRateKey = 256_000`。
4. **进度回调**：按帧 / 时间戳估算 0..1 进度，回主线程节流到 ≥100ms 更新一次。
5. **取消**：支持 `Task.cancel()`，cancel 后清理临时文件。

### 4.3 AudioImporter

```swift
public actor AudioImporter {
    public static let shared = AudioImporter()

    public enum Error: Swift.Error {
        case unsupportedFormat
        case copyFailed
    }

    /// 把用户从 DocumentPicker 选定的音频文件复制到 TimelineKit 受控目录。
    public func `import`(from pickedURL: URL) async throws -> (url: URL, duration: Double)
}
```

实现要点：

1. **格式探测**：`AVAsset(url:).load(.tracks(withMediaType: .audio))`，无音频轨则抛 `unsupportedFormat`。
2. **路径**：复制到 `ApplicationSupport/TimelineKit/Assets/_shared/{sha1(pickedURL.path + mtime)}.{ext}`。
3. **元数据**：通过 `AVAsset.load(.duration)` 拿到真实时长，回写 `EditorAsset.nativeDuration`。

### 4.4 UI 侧改造

[EditorBottomToolbar.swift](../../Sources/TimelineKit/Views/EditorBottomToolbar.swift) `EditorSecondaryToolPanel.toolStubs(for:)` 的 `case .audio:` 分支：

```swift
case .audio:
    toolButton("提取音频", icon: "waveform.path.badge.minus", enabled: true) {
        AudioFlowController.shared.startExtract(presenting: store)
    }
    toolButton("本地音乐", icon: "music.note.list", enabled: true) {
        AudioFlowController.shared.startImport(presenting: store)
    }
    toolButton("音效", icon: "speaker.wave.2.bubble", enabled: false) {}
```

`AudioFlowController` 是新增的 UI 协调对象，负责 PHPicker / DocumentPicker 的展示、进度 HUD、错误 Toast。

---

## 五、边界情况

| 情况 | 处理 |
|---|---|
| 用户选的视频无音频轨 | 抛 `AudioExtractor.Error.noAudioTrack`，Toast 提示「该视频无音频」 |
| 用户选的音频格式不支持（如 FLAC 在某些设备）| `AudioImporter.Error.unsupportedFormat`，Toast 提示「不支持的音频格式」 |
| 提取过程中用户切走 app | actor `await` 状态保留；后台允许继续，60 秒后系统挂起则触发取消 |
| 用户连续点提取按钮 10 次 | flow controller 用单 `Task` 串行化，重复点击 UI 灰显 |
| 落地路径已有同 hash 文件 | 直接复用，不重复写入 |
| `addSegmentAutoTrack` 时所有音频轨均与新片段重叠 | 自动新建第二条音频轨（见 [multi-track-architecture-spec §2.2](multi-track-architecture-spec.md)） |
| 草稿存在但磁盘音频文件被外部删除 | 加载时 `EditorAsset.localURL` 不存在 → 标记「待补素材」状态（与 v1 视频缺失策略一致） |
| 单段静音 | `mutateSubtitle` 不适用音频；走 `mutate("静音切换")` + 仅修改 `audioMix` 不重建 composition（v1 A-03 规范） |

---

## 六、验收标准

| # | 项目 | 标准 |
|---|---|---|
| AF-01 | 提取音频成功率 | 10 次连续提取 ≥ 9 次成功（无 audio track 的视频不计入失败） |
| AF-02 | 提取耗时 | 30s 720p 视频 ≤ 2.5s（iPhone 14） |
| AF-03 | 本地导入支持格式 | mp3 / m4a / wav / aac 全部可导入 |
| AF-04 | 波形显示 | 导入完成后 200ms 内出现波形，无空白 |
| AF-05 | 磁吸触觉 | 距吸附点 8pt 内触发 light 触觉 + snap_tick 音效，300ms 内 ≤ 1 次音效 |
| AF-06 | 多音频轨 | 同时加入 3 条音频段（含重叠），自动分到 2 条音频轨，播放无爆音 |
| AF-07 | 二级面板灰显 | 「音效」按钮 enabled = false，点击无反应 |
| AF-08 | 草稿往返 | 提取的音频与导入的音频在草稿重新加载后均正常播放、波形保留 |
| AF-09 | 单段静音 | 切换 isMuted 不触发 rebuild，响应 ≤ 100ms |
| AF-10 | 取消提取 | 提取过程中点击取消按钮 → 任务在 500ms 内停止 + 临时文件清理 |

---

## 七、与 v1 / v2 接口约束

- **不修改** [WaveformProvider](../../Sources/TimelineKit/Rendering/WaveformProvider.swift) 接口
- **不修改** v1 [audio-track-interaction-spec](../v1/audio-track-interaction-spec.md) 磁吸 / 拉伸 / 静音规则
- **不修改** v2 [transition-spec](../v2/transition-spec.md) ——音频轨道不支持转场，与 v2 转场仅作用主视频轨的设定一致
- `AudioContent` 字段保持向后兼容（v3 仅在 [tts-spec.md](tts-spec.md) 增加可选字段 `ttsSource`）

---

## 八、音频独立变速（v3 完善 P0）

### 8.1 立项背景

[tts-spec](tts-spec.md) 落地后，用户反馈一个核心痛点：**TTS 配音合成后无法后期调速**，仅能在生成时指定 `TTSSource.rate`。若字幕显示时长与配音播报时长不匹配，用户只能手动重生（流程长 + 缓存击穿）。本节为「音频段独立变速」提供数据 / 渲染 / UI 闭环。

### 8.2 与视频变速的边界

| 维度 | 音频独立变速（本节） | 视频整体变速（v3 不做） |
|---|---|---|
| 字段 | `EditorSegment.speed` | 同字段，未来共用 |
| 适用 segment kind | `.audio` 段（含 TTS 配音段、提取音频、本地音乐） | `.video` 段 |
| 副作用 | 仅改音频播放速度 + 段视觉时长；不影响画面 | （未实现）会同时改画面与原音 |
| UI 入口 | AudioEditPanel 速度滑块（P3 收纳；P0 临时挂 AudioSecondaryPanel） | 无 |

> v1 [CompositionBuilder](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) 顶部注释「Speed < > 1.0 — treated as 1.0 (future)」**仅限视频段**。音频段从 v3 P0 起按 `EditorSegment.speed` 生效。

### 8.3 数据模型

复用既有 `EditorSegment.speed: Double`（默认 1.0）。范围约束在 store 层：

```swift
public extension EditorSegment {
    static let audioSpeedRange: ClosedRange<Double> = 0.3 ... 3.0
}
```

`speed = 1.5` 表示 1.5 倍速播放（更短）。`speed = 0.5` 表示半速（更长）。

### 8.4 速度与时长的耦合关系

```
targetRange.duration  =  sourceDuration / speed
sourceDuration consumed = targetRange.duration * speed
```

设速度时同步更新 `targetRange.duration`，让时间轴上的段长度直接反映播放时长（与剪映一致）。trim 时反向更新 `sourceRange.duration`，speed 保持不变。

### 8.5 渲染规则（CompositionBuilder）

在 [buildAudioTrack](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) 中，对每个 `.audio` 段：

```
let speed   = clamp(seg.speed, 0.3 ... 3.0)
let srcDur  = seg.targetRange.duration * speed
let srcRange = CMTimeRange(start: srcStart, duration: srcDur)
compAudioTrack.insertTimeRange(srcRange, of: srcTrack, at: targetAt)
if abs(speed - 1.0) > 1e-3 {
    let insertedRange = CMTimeRange(start: targetAt, duration: srcDur)
    let scaledDur     = CMTime(seconds: seg.targetRange.duration, …)
    compAudioTrack.scaleTimeRange(insertedRange, toDuration: scaledDur)
}
```

循环段（`isLooping`）按 chunk 单独 scaleTimeRange。视频段的 native audio（主轨原音）**不应用变速**，与「视频整体变速未实现」一致。

### 8.6 EditorStore API

```swift
public extension EditorStore {
    /// Live preview during slider drag (no undo, no rebuild — segments update in place).
    func previewAudioSpeed(segmentID: UUID, speed: Double)

    /// Commit speed change (undo-tracked, triggers full rebuild because timeRange shifts).
    func setAudioSpeed(segmentID: UUID, speed: Double)
}
```

`setAudioSpeed` 内部行为：
1. clamp speed 到 0.3...3.0
2. 计算 sourceDuration = oldTargetDur * oldSpeed（保留素材消耗量）
3. newTargetDur = sourceDuration / newSpeed
4. `mutate("调整音频速度")`：写入 seg.speed + seg.targetRange.duration
5. 不调用 audioMixOnly fast path（变速影响 timeRange，必须走 rebuild）

### 8.7 UI（P0 临时）

AudioSecondaryPanel 选中音频段时显示速度滑块（0.3x - 3.0x，分度 0.1）。拖动调 previewAudioSpeed，松手调 setAudioSpeed。P3 落地 AudioEditPanel 后迁移到 AudioEditPanel 内。

### 8.8 验收（新增 AF-11 / AF-12）

| # | 项目 | 标准 |
|---|---|---|
| AF-11 | 音频变速听感 | TTS 配音段 speed=2.0 → 播放时长 ≈ 原 1/2，听感明显变快 |
| AF-12 | targetDuration 联动 | speed=2.0 后 targetRange.duration 缩到原 1/2；草稿往返保真 |
| AF-13 | 视频原音不变速 | 主轨视频段 speed 字段仍被忽略（与「视频变速未实现」一致） |

---

## 九、音视频分离（v3 完善 P2）

### 9.1 立项背景

用户痛点：拍摄/导入的视频原声常常需要替换（如换 BGM、消除噪音原音保留画面）。当前 v3 已能从相册视频「提取音频」到独立音频轨（§2.2），但**对正在主轨上的视频段没有同等能力**——只能去 SegmentReplacePanel 替换整段素材或全局静音。

本节补：**主轨视频段一键剥离原音 → 独立 .audio 段同步落到音频轨；原视频画面保留但原音自动静音**。对标剪映「分离音视频」、FCP「Detach Audio」。

### 9.2 行为规则（用户已确认）

| 维度 | 行为 |
|---|---|
| 入口 | SegmentReplacePanel（选中主轨视频段时显示的 `.clip` 二级面板）新增「分离音视频」按钮 |
| 原视频原音处理 | **自动静音**（写 `VideoContent.isMuted = true`），防止与剥离出的音频双播 |
| 重复分离防护 | 当源视频段 `VideoContent.isMuted == true` 时按钮**灰显**（disabled），避免重复操作 |
| 逆操作 | **不做「重新合并」按钮**。回滚靠 undo（单步回滚两步变更）或手动「删除分离出的音频段 + 取消视频静音」 |
| 字幕配音 | 不影响。TTS/字幕配音段是独立 `.audio` 段，与本流程无冲突 |
| 失败兜底 | 视频无音频轨 → Toast「该视频无音频」；视频文件不可读 → 错误透传 |

### 9.3 时间对齐

分离出的 `.audio` 段必须与源视频段在时间轴上**完全同步**：

```
audio.targetRange  = video.targetRange                                    // 时间轴位置一致
audio.sourceRange  = TimeRange(
    start:    video.sourceRange?.start ?? 0,                              // 同子区间起点
    duration: video.sourceRange?.duration ?? video.targetRange.duration   // 同子区间长度
)
```

注：AudioExtractor 一次性提取**整段**视频音频到 m4a（不裁子区间）。子区间对齐由 audio segment 的 `sourceRange` 在 CompositionBuilder 层切片完成，与现有路径一致。

### 9.4 EditorStore API

```swift
public extension EditorStore {
    /// 从主轨视频段剥离原音到独立 .audio 段，并把源视频段自动静音。
    /// 全部变更落到同一 `mutate("分离音视频")` 内 → 单步 undo 回滚两步。
    /// - Returns: 新建的 .audio 段 ID；失败抛错（AudioExtractor.Failure 或本枚举）
    /// - Throws: `DetachAudioError.notVideoSegment` / `.assetURLMissing`
    ///          / `AudioExtractor.Failure.noAudioTrack` 等
    @MainActor
    func detachAudio(fromVideoSegmentID id: UUID) async throws -> UUID

    enum DetachAudioError: Swift.Error, LocalizedError {
        case notVideoSegment
        case assetURLMissing
    }
}
```

### 9.5 实现流程

```
1. 在 MainActor 校验源段：必须是 .video + materialID 对应 EditorAsset 存在
2. 解析视频本地 URL（关键步骤，AVAssetReader 不支持远程 URL，会抛
   AVError -11838 "OperationStopped"）：
   - 若 videoAsset.localURL 存在且磁盘有文件 → 直接用
   - 否则若 videoAsset.remoteURL 存在 → await AssetDownloadManager.shared
     .localURL(for:assetID:timelineID:) 下载，下载完调
     EditorStore.updateAssetLocalURL 持久化映射
   - 都没有 → 抛 .assetURLMissing
3. AssetDownloadManager.reserveLocalURL(assetID: 新UUID, ext: "m4a", timelineID)
4. await AudioExtractor.shared.extract(from: videoLocalURL, to: m4aURL)
   → 抛出 AudioExtractor.Failure.noAudioTrack 时上层 Toast 提示
5. 构造 EditorAsset(.audio, localURL: m4aURL, nativeDuration: 提取产物时长)
   构造 EditorSegment(.audio, materialID, sourceRange/targetRange 按 §9.3 拷贝)
6. mutate("分离音视频") { tl in
     tl.materials.add(audioAsset)
     // 内联 audio 轨自动分配（与 addSegmentAutoTrack 同规则，避免嵌套 mutate）
     reuseOrCreateAudioTrack(in: &tl, segment: audioSegment)
     // 把源视频段静音
     tl.updateSegment(id: id) { v in
         guard case .video(var c) = v.content else { return }
         c.isMuted = true
         v.content = .video(c)
     }
   }
7. 返回新 audio segment ID
```

> **注**：步骤 2 的下载阶段是分离总耗时的主要部分（远程视频可能数秒到数十秒）。
> UI 应在「分离中…」spinner 中覆盖整个 async 流程，下载失败会通过
> URLSession 错误透传到 alert。

### 9.6 UI（SegmentReplacePanel）

[SegmentReplacePanel](../../Sources/TimelineKit/Views/SegmentReplacePanel.swift) 在「分割 / 删除 / 替换素材」之外新增第四个按钮：

| 标题 | 图标 | enabled 条件 |
|---|---|---|
| 分离音视频 | `waveform.path.badge.minus` | 源段 `VideoContent.isMuted == false`，且不在进行中状态 |

点击 → `Task { try? await store.detachAudio(...) }`，错误用与 AudioSecondaryPanel 同样的 alert 模式呈现。

### 9.7 与已有特性的关系

- **多轨**：分离出的音频段走 `addSegmentAutoTrack(.audio)` 同规则：能复用现有 `.audio` 轨则复用，与音频段时间重叠则新建一条
- **变速 (§8)**：分离出的音频段 `speed = 1.0` 初始；用户后续可独立调速对齐字幕节奏
- **TTS (§tts-spec)**：与 TTS 配音段完全独立。分离出的音频 `ttsSource = nil`
- **导出**：CompositionBuilder 现有音频管道无需改造——分离出的段就是普通 `.audio` 段
- **草稿往返**：使用同样的 EditorAsset 持久化路径，关闭重开 100% 保留

### 9.8 验收（新增 AF-14 / AF-15 / AF-16）

| # | 项目 | 标准 |
|---|---|---|
| AF-14 | 分离链路通跑 | 选中主轨视频 → 点「分离音视频」→ 音频轨新增一段同长度同位置的音频，原视频画面无声 |
| AF-15 | 重复分离防护 | 已分离过（isMuted=true）的视频段按钮灰显，点击无反应 |
| AF-16 | 无音频兜底 | 选无音频轨视频 → Toast「该视频无音频」，无副作用 |
| AF-17 | 单步 undo | 分离后 ⌘Z → 音频段消失 + 视频原音恢复，一次撤销完成 |
| AF-18 | 草稿往返 | 分离后保存 → 重开 → 音频段、视频静音状态完整保留 |

---

## 十、音频编辑面板（v3 完善 P3）

### 10.1 立项背景

`EditorStore` 在 v1 已落地 `setAudioVolume / previewAudioVolume / muteAudioSegment` 等 API（[EditorStore.swift:1111-1153](../../Sources/TimelineKit/Store/EditorStore.swift)），P0 又新增 `setAudioSpeed / previewAudioSpeed`，但**用户没有任何统一的 UI 入口**。P0 阶段把速度滑块临时挂在 `AudioSecondaryPanel` 内做最小可用，本节正式落地专属编辑面板。

### 10.2 AudioEditPanel 设计

新文件 [`Views/AudioEditPanel.swift`](../../Sources/TimelineKit/Views/AudioEditPanel.swift)（与 `TextEditPanel` 同级）。控件清单：

| 控件 | 范围 / 默认 | 对应 Store API |
|---|---|---|
| 音量滑块 | 0% – 200%（0.0–2.0），默认 100% | `previewAudioVolume` / `setAudioVolume` |
| 静音 Toggle | on/off | `muteAudioSegment(id:, isMuted:)` |
| 速度滑块 | 0.3x – 3.0x，分度 0.1x | `previewAudioSpeed` / `setAudioSpeed` |
| 段信息 | 时长 + 文件名（只读） | 读 `EditorAsset.localURL.lastPathComponent` + `targetRange.duration` |

布局：垂直三段（信息 → 音量行 → 速度行 → 静音行），与 `TextEditPanel` 整体观感保持一致（深色背景、白色控件）。

### 10.3 派发改造

[ClipEditorView.swift](../../Sources/TimelineKit/Views/ClipEditorView.swift) 二级面板渲染分支调整：

```
if selection.singleSelectedID is .audio segment → AudioEditPanel(segmentID, store)
elif activeToolCategory == .audio                → AudioSecondaryPanel(store)  // 提取/导入入口
```

P0 临时挂在 `AudioSecondaryPanel` 内的「选中音频段时显示速度滑块」分支**移除**（其 selectedAudioSegmentID 计算 + speedSliderContent 整段删掉），改由 AudioEditPanel 全面接管。

### 10.4 per-segment 音量渲染改造

CompositionBuilder 的 audioMix 当前用「轨道首段 volume」（[CompositionBuilder.swift:636-647](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift)） — 多段同轨不同音量时只第一段生效。改为按段 keyframe：

```swift
let p = AVMutableAudioMixInputParameters(track: compAudioTrack)
if track.isMuted {
    p.setVolume(0, at: .zero)
} else {
    // Initial silence; each segment's start sets its own volume.
    p.setVolume(0, at: .zero)
    let sorted = track.segments.sorted { $0.targetRange.start < $1.targetRange.start }
    for seg in sorted {
        guard case .audio(let c) = seg.content else { continue }
        let v: Float = c.isMuted ? 0 : Float(c.volume)
        p.setVolume(v, at: CMTime(seconds: seg.targetRange.start, preferredTimescale: 600))
    }
}
```

`buildAudioMixOnly` 同步改造（fast path 必须与 build 路径行为一致，否则音量预览会与导出分歧）。

> `setVolume(_:at:)` 把当前音量保持到下一个时间点的设值。段与段之间若有 gap，gap 期内 composition 无音频数据，volume 值不影响输出。

### 10.5 验收

| # | 项目 | 标准 |
|---|---|---|
| AF-19 | 选中音频段唤起 AudioEditPanel | 单选 `.audio` 段时二级面板自动切换为 AudioEditPanel；取消选择回到 AudioSecondaryPanel |
| AF-20 | 音量滑块 | 拖动 → 实时听到音量变化；松手 → 草稿保存 |
| AF-21 | 静音 Toggle | 切换 → < 100ms 内静默/恢复（audioMixOnly fast path） |
| AF-22 | 速度滑块 | 拖动改 speed；松手提交，时间轴段长度按 §8.4 同步收缩/拉伸 |
| AF-23 | 多段同轨独立音量 | 同一音频轨 A 段 50% / B 段 150% → 播放时 A B 各按自身音量输出，不再被首段覆盖 |

---

## 十一、视频原音控制（v3 完善 P3）

### 11.1 行为

[SegmentReplacePanel](../../Sources/TimelineKit/Views/SegmentReplacePanel.swift) 在「分割 / 删除 / 替换素材 / 分离音视频」后新增「原音」开关（Toggle 风格按钮）：

| 状态 | VideoContent.isMuted | 按钮显示 |
|---|---|---|
| 开 | false | 「原音」白色高亮 |
| 关 | true | 「原音」灰色 |

切换调 `store.setVideoMuted(segmentID:, isMuted:)`（本期新增），走 `mutate("切换原音")` 触发 full rebuild（必须 rebuild：把视频段加回/移出音频 composition）。

### 11.2 与分离音视频的关系

- **分离后**：源视频段 isMuted=true → 「原音」按钮显示为关
- 用户手动切回开 → 视频段重新发声 → 此时与分离出来的独立音频段**双播**（用户责任：通常应手动删除分离出的音频段）
- 「分离音视频」按钮的灰显条件仍是 `VideoContent.isMuted == true`，与本开关共用同一字段

### 11.3 EditorStore API

```swift
public extension EditorStore {
    /// Toggle a video segment's original audio mute (audio-feature-spec §11).
    /// Goes through `mutate` (full rebuild) since the audio composition needs to
    /// add or remove this segment's audio track.
    func setVideoMuted(segmentID: UUID, isMuted: Bool)
}
```

### 11.4 验收

| # | 项目 | 标准 |
|---|---|---|
| AF-24 | 视频原音开关 | 选中主轨视频段，切换「原音」开关 → 视频原声立即在下一帧停/响 |
| AF-25 | 与分离联动 | 分离音视频后「原音」按钮自动显示为关；手动切回开 → 视频恢复发声（音频轨同时仍在 → 双播警告由用户自负） |
| AF-26 | 与「分离」按钮联动 | 「原音」关时「分离音视频」按钮灰显，避免重复分离 |
