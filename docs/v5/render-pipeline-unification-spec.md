# 渲染管线统一与 AVAssetWriter 改造规范（v5）

> 版本：v5.0
> 状态：规范定稿，待实现
> 优先级：**P1**（M3 SDR 全档位 / M4 HDR 增量）
> 对标产品：剪映 iOS（`AVAssetWriter + 自配 H.264/HEVC`）/ CapCut（自研编码引擎 + 系统硬编码）/ LumaFusion（`AVAssetWriter + VideoToolbox`）
> 依赖：v1 [rendering-architecture-spec.md](../v1/rendering-architecture-spec.md)（烘焙路径基础）；v5 [fullscreen-preview-spec.md](fullscreen-preview-spec.md)（M1 已建立的同源调用链复用）；v5 [export-config-panel-spec.md](export-config-panel-spec.md)（消费 ExportConfig）；[docs/v2/export-pipeline-spec.md](../v2/export-pipeline-spec.md) 附录 A（档位与编码格式权威表）

---

## 一、问题陈述

### 1.1 AVAssetExportSession 架构限制

[VideoExporter.swift:74-120](../../Sources/TimelineKit/Export/VideoExporter.swift) 现状用 `AVAssetExportSession` + 三选一预设：

```swift
let preset: String = {
    let all = AVAssetExportSession.allExportPresets()
    if all.contains(AVAssetExportPreset1920x1080) { return AVAssetExportPreset1920x1080 }
    if all.contains(AVAssetExportPreset1280x720)  { return AVAssetExportPreset1280x720 }
    return AVAssetExportPresetMediumQuality
}()
let session = AVAssetExportSession(asset: result.composition, presetName: preset)
session.videoComposition = result.videoComposition
session.audioMix         = result.audioMix
session.outputFileType   = .mp4
```

`AVAssetExportSession` 架构上**无法**：

- 独立控制码率（预设绑定 分辨率+质量）
- 独立控制色彩空间（Rec.709 vs BT.2020 PQ）
- 选择 HEVC Main 10（10-bit pixel format）

要支持 V5 §1.4 三档码率 + §1.5 HDR 开关，**没有第二条路**，必须改造为 `AVAssetWriter`。

### 1.2 既有先例

[StaticImageRenderer.swift:107-180](../../Sources/TimelineKit/Rendering/StaticImageRenderer.swift) 已用 `AVAssetWriter + AVAssetWriterInput + AVAssetWriterInputPixelBufferAdaptor` 实现静帧渲染：

```swift
guard let writer = try? AVAssetWriter(outputURL: outURL, fileType: .mp4) else { throw ... }
let videoSettings: [String: Any] = [
    AVVideoCodecKey:  AVVideoCodecType.h264,
    AVVideoWidthKey:  Int(renderSize.width),
    AVVideoHeightKey: Int(renderSize.height)
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
// ...
guard writer.startWriting() else { throw ... }
```

V5 在 `VideoExporter.exportToFile` 复用同一模式，扩展到完整视频导出（含 audioMix + videoComposition 帧序列）。

### 1.3 同源化与编码统一的耦合

V5 P0 [fullscreen-preview-spec.md](fullscreen-preview-spec.md) M1 已建立"`build(renderSubtitles: true)` + 独立 AVPlayer"的烘焙预览路径。V5 P1 M3 在此基础上做编码改造：

- 同样调用 `build(renderSubtitles: true, renderSize:, fps:)` 拿到 `CompositionResult`
- 用 `AVAssetReader` 从 composition 读出帧序列
- 用 `AVAssetWriter` 按 ExportConfig 配置的码率/色彩空间/编码器写出 mp4

预览（全屏 AVPlayer）与导出（AVAssetWriter）共用 `build` 上游 → **绝对同源**；下游只是"显示 vs 编码"的输出端差异，与渲染像素无关。

---

## 二、规则定义

### 2.1 改造范围

| 模块 | M3 | M4 |
|---|---|---|
| `VideoExporter.exportToFile` | AVAssetExportSession → AVAssetWriter | 同 M3，扩展 HDR 编码分支 |
| `CompositionBuilder.build` | 新增可选 `renderSize: CGSize?` / `fps: Double?` 参数 | 不动 |
| `ExportConfig → 编码参数映射表` | 5 档分辨率 × 6 档帧率 × 3 档码率（SDR）| 增加 HDR 编码参数 |
| HDR 设备能力检测 | 检测但不启用（M3 阶段 UI Toggle 始终 disabled）| 解禁 Toggle；HDR 编码生效 |
| 失败降级 | AVAssetWriter 失败时报错（不回退 ExportSession）| HDR 不支持时静默降级 SDR |

### 2.2 公共 API 锁定

- `VideoExporter.export(timeline:) async` 签名 **完全不变**（对 ExportResultView / ClipEditorView 等调用方零修改）
- `CompositionBuilder.build` 新增参数 **必须为可选**，nil 时行为与 V4 完全一致（旧调用点零修改）
- 失败错误类型沿用 V4：`NSError(domain: "VideoExporter", code: -1...-6, userInfo:)`

### 2.3 输出格式

| 项 | 值 |
|---|---|
| 容器 | mp4（V4 已固定，沿用） |
| 视频编码（SDR 480/720/1080）| H.264 |
| 视频编码（SDR 2K/4K）| HEVC（H.265） |
| 视频编码（HDR 全档位）| HEVC Main 10 |
| 像素格式（SDR）| `kCVPixelFormatType_32BGRA` |
| 像素格式（HDR）| `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`（10-bit YUV）|
| 色彩空间（SDR）| Rec.709（`kCVImageBufferYCbCrMatrix_ITU_R_709_2` + `kCVImageBufferColorPrimaries_ITU_R_709_2` + `kCVImageBufferTransferFunction_ITU_R_709_2`） |
| 色彩空间（HDR）| BT.2020 PQ（`kCVImageBufferYCbCrMatrix_ITU_R_2020` + `kCVImageBufferColorPrimaries_ITU_R_2020` + `kCVImageBufferTransferFunction_ITU_R_2100_PQ`） |
| 音频编码 | AAC LC，128 kbps，44.1 kHz，立体声（V4 现状一致） |
| 文件落盘 | `FileManager.default.temporaryDirectory.appendingPathComponent("TimelineExport_<uuid>.mp4")`（V4 现状一致） |

---

## 三、CompositionBuilder.build 签名扩展

### 3.1 新签名

[CompositionBuilder.swift:51](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) 现有：

```swift
func build(from timeline: EditorTimeline, renderSubtitles: Bool = false) async throws -> CompositionResult
```

V5 扩展：

```swift
func build(
    from timeline: EditorTimeline,
    renderSubtitles: Bool = false,
    renderSize: CGSize? = nil,           // v5 新增：nil 时取 timeline.canvas
    fps:        Double? = nil            // v5 新增：nil 时取 timeline.canvas.fps
) async throws -> CompositionResult
```

### 3.2 内部行为

[CompositionBuilder.swift:53-67](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) 原逻辑：

```swift
let renderSize  = CGSize(
    width:  CGFloat(timeline.canvas.width),
    height: CGFloat(timeline.canvas.height)
)
let fps = Double(timeline.canvas.fps > 0 ? timeline.canvas.fps : 30)
```

V5 改造为：

```swift
let actualRenderSize = renderSize ?? CGSize(
    width:  CGFloat(timeline.canvas.width),
    height: CGFloat(timeline.canvas.height)
)
let actualFPS = fps ?? Double(timeline.canvas.fps > 0 ? timeline.canvas.fps : 30)

// ... 后续逻辑使用 actualRenderSize / actualFPS 替代原变量
videoComposition.renderSize    = actualRenderSize
videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(actualFPS))
```

### 3.3 向后兼容

| 调用点 | 行为 |
|---|---|
| 编辑画布常态预览（CompositionCoordinator）| 不传新参数 → 与 V4 完全一致 |
| 全屏同源预览（M1 已实现）| 不传新参数 → 与 V4 完全一致（全屏预览不需要参数化） |
| V5 导出（M3 改造后）| 传 `renderSize = cfg.resolution.size`、`fps = cfg.fps.value` |

### 3.4 字幕烘焙的尺寸适配

[CompositionBuilder.swift:88-100](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) 已有 `SubtitleFrameBuilder.build(segments:renderSize:totalDuration:)` 调用，传入 `renderSize` 作为渲染尺寸：

```swift
let frames = await MainActor.run {
    SubtitleFrameBuilder.build(
        segments:      overlaySegs,
        renderSize:    renderSize,       // V5 改为 actualRenderSize
        totalDuration: totalDuration.seconds
    )
}
```

字幕位置、字号、padding 等均按 `actualRenderSize` 重新计算 → 4K 导出时字幕分辨率匹配；480P 导出时字幕降级清晰。

无需新增字段映射；`SubtitleFrameBuilder` 已经按 renderSize 参数化。

---

## 四、VideoExporter 改造

### 4.1 整体结构

```swift
extension VideoExporter {

    private func exportToFile(_ result: CompositionResult, config: ExportConfig) async throws -> URL {
        let outURL = makeOutputURL()

        // 1. 设备能力检测 + 降级
        let effectiveConfig = downgradeIfNeeded(config)

        // 2. 创建 AVAssetWriter
        guard let writer = try? AVAssetWriter(outputURL: outURL, fileType: .mp4) else {
            throw NSError(domain: "VideoExporter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 AVAssetWriter"])
        }

        // 3. Video Input（按 config 配置编码器/码率/色彩空间）
        let videoInput = makeVideoInput(config: effectiveConfig)
        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "VideoExporter", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter 不支持当前视频参数"])
        }
        writer.add(videoInput)

        // 4. Audio Input（AAC 128k 固定）
        let audioInput = makeAudioInput()
        writer.add(audioInput)

        // 5. 用 AVAssetReader 从 composition 读帧 / 读音频
        let reader = try AVAssetReader(asset: result.composition)
        let videoOutput = makeVideoReaderOutput(composition: result.composition, videoComposition: result.videoComposition)
        let audioOutput = makeAudioReaderOutput(composition: result.composition, audioMix: result.audioMix)
        reader.add(videoOutput)
        reader.add(audioOutput)

        // 6. 启动 writer + reader
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        reader.startReading()

        // 7. 双 task 并发 copy frames → writer inputs
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await copyVideoSamples(from: videoOutput, to: videoInput, progress: { ... }) }
            group.addTask { try await copyAudioSamples(from: audioOutput, to: audioInput) }
            try await group.waitForAll()
        }

        // 8. Finish
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        await writer.finishWriting()

        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "VideoExporter", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "导出未成功"])
        }
        return outURL
    }
}
```

### 4.2 makeVideoInput（关键函数）

```swift
private func makeVideoInput(config: ExportConfig) -> AVAssetWriterInput {

    let size = config.resolution.size
    let bitrate = bitrateValue(for: config)   // Mbps → bits/sec

    var compressionProperties: [String: Any] = [
        AVVideoAverageBitRateKey:     bitrate,
        AVVideoExpectedSourceFrameRateKey: Int(config.fps.value),
        AVVideoMaxKeyFrameIntervalKey: Int(config.fps.value * 2)  // GOP = 2s
    ]

    let codec: AVVideoCodecType
    if config.hdrEnabled {
        // HEVC Main 10
        codec = .hevc
        compressionProperties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
        compressionProperties[AVVideoColorPrimariesKey]    = AVVideoColorPrimaries_ITU_R_2020
        compressionProperties[AVVideoTransferFunctionKey]  = AVVideoTransferFunction_SMPTE_ST_2084_PQ
        compressionProperties[AVVideoYCbCrMatrixKey]       = AVVideoYCbCrMatrix_ITU_R_2020
    } else {
        // SDR：1080P 及以下用 H.264，2K/4K 用 HEVC
        codec = (size.width >= 2560) ? .hevc : .h264
        compressionProperties[AVVideoColorPrimariesKey]    = AVVideoColorPrimaries_ITU_R_709_2
        compressionProperties[AVVideoTransferFunctionKey]  = AVVideoTransferFunction_ITU_R_709_2
        compressionProperties[AVVideoYCbCrMatrixKey]       = AVVideoYCbCrMatrix_ITU_R_709_2
    }

    var videoSettings: [String: Any] = [
        AVVideoCodecKey:  codec,
        AVVideoWidthKey:  Int(size.width),
        AVVideoHeightKey: Int(size.height),
        AVVideoCompressionPropertiesKey: compressionProperties
    ]

    if config.hdrEnabled {
        videoSettings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey:   AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
            AVVideoYCbCrMatrixKey:      AVVideoYCbCrMatrix_ITU_R_2020
        ]
    }

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    input.expectsMediaDataInRealTime = false
    return input
}
```

### 4.3 makeAudioInput（固定）

```swift
private func makeAudioInput() -> AVAssetWriterInput {
    let audioSettings: [String: Any] = [
        AVFormatIDKey:            kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey:    2,
        AVSampleRateKey:          44100,
        AVEncoderBitRateKey:      128_000      // 128 kbps
    ]
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    input.expectsMediaDataInRealTime = false
    return input
}
```

### 4.4 copyVideoSamples / copyAudioSamples（帧搬运）

```swift
private func copyVideoSamples(
    from output: AVAssetReaderVideoCompositionOutput,
    to input:    AVAssetWriterInput,
    progress:    @escaping (Double) -> Void
) async throws {
    let totalDuration = ...   // 从 composition.duration 算出秒

    while input.isReadyForMoreMediaData {
        guard let sample = output.copyNextSampleBuffer() else {
            // 读完
            return
        }
        if !input.append(sample) {
            throw NSError(domain: "VideoExporter", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "视频帧写入失败"])
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        progress(min(1.0, pts / totalDuration))
    }

    // 若 input 暂时 not ready，等到 ready 再继续（用 await 等待）
    // 实际实现需用 requestMediaDataWhenReady(on:using:) 但 async 适配需要 continuation 桥接
}
```

audioSamples 类似但不需要 progress 上报。

### 4.5 进度上报

V4 现状 [VideoExporter.swift:99-107](../../Sources/TimelineKit/Export/VideoExporter.swift) 用 `Task` 轮询 `session.progress`。V5 改用视频帧 pts 作为进度源：

```swift
group.addTask {
    try await copyVideoSamples(from: videoOutput, to: videoInput) { pts in
        Task { @MainActor in self.progress = pts }
    }
}
```

进度精度：与帧速率一致（30fps → 33ms 更新一次）；体感与 V4 平滑。

---

## 五、设备能力检测与降级

### 5.1 HDR 降级路径

```swift
private func downgradeIfNeeded(_ config: ExportConfig) -> ExportConfig {
    guard config.hdrEnabled else { return config }

    // dry-run：尝试创建一个临时 HDR videoSettings 看 canApply 是否通过
    if !canEncodeHDR() {
        var downgraded = config
        downgraded.hdrEnabled = false
        return downgraded
    }
    return config
}

private func canEncodeHDR() -> Bool {
    // iOS 14+ 才支持 HEVC Main 10；iOS 17+ 推荐
    guard #available(iOS 14.0, *) else { return false }

    // 检测设备 + 系统能力
    let testSettings: [String: Any] = [
        AVVideoCodecKey:  AVVideoCodecType.hevc,
        AVVideoWidthKey:  1920,
        AVVideoHeightKey: 1080,
        AVVideoCompressionPropertiesKey: [
            AVVideoProfileLevelKey:  kVTProfileLevel_HEVC_Main10_AutoLevel,
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020
        ]
    ]
    let tempInput = AVAssetWriterInput(mediaType: .video, outputSettings: testSettings)

    // 创建临时 writer 测试 canAdd
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("hdr_probe_\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    guard let tempWriter = try? AVAssetWriter(outputURL: tempURL, fileType: .mp4) else { return false }
    return tempWriter.canAdd(tempInput)
}
```

### 5.2 降级时的 UI 反馈

`ExportConfigSheet.isHDRAvailable`（[export-config-panel-spec.md](export-config-panel-spec.md) §5.2）查询 `VideoExporter.canEncodeHDR()`（或封装为静态工具方法），返回 false 时 Toggle 禁用并显示"当前设备不支持 HDR 编码"。

降级在导出阶段 **静默**：用户 Sheet 内看到 HDR Toggle 是 disabled 的，不存在"Toggle 是开的但导出却是 SDR"的矛盾态。

### 5.3 其他降级

| 失败场景 | 行为 |
|---|---|
| `AVAssetWriter(outputURL:)` 创建失败 | 抛错（code: -1）；ExportResultView 显示错误消息 |
| `writer.canAdd(videoInput)` 返回 false | 抛错（code: -2）；说明编码参数组合不支持 |
| `videoInput.append(sample)` 失败 | 抛错（code: -4）；中断导出 |
| `writer.finishWriting()` status ≠ .completed | 抛错（code: -3）；附 writer.error |
| `AVAssetReader.startReading()` 失败 | 抛错（code: -5）|

错误链沿用 V4 `NSError(domain: "VideoExporter", code: -1...-N)` 模式。

---

## 六、档位 → 编码参数映射表

### 6.1 基线码率（30fps，单位 Mbps）

| 分辨率 | 较低 | 推荐 | 较高 |
|---|---|---|---|
| 480P (854×480) | 1.0 | 2.5 | 4.0 |
| 720P (1280×720) | 2.5 | 5 | 8 |
| 1080P (1920×1080) | 5 | 8 | 12 |
| 2K (2560×1440) | 10 | 16 | 24 |
| 4K (3840×2160) | 20 | 35 | 50 |

依据：

- 推荐档对齐 YouTube / Vimeo 1080P30 ≈ 8 Mbps 行业惯例
- 较低档为推荐档约 60%；较高档为推荐档约 150%
- 4K 推荐档对齐剪映 4K 输出实测 ≈ 35 Mbps

### 6.2 帧率倍率

实际码率 = 基线 × 帧率倍率：

| 帧率 | 倍率 |
|---|---|
| 24 / 25 / 30 | ×1.0 |
| 50 / 60 | ×1.2 |
| 120 | ×1.5 |

### 6.3 编码器选择

| 配置 | 编码器 | 像素格式 | 色彩空间 |
|---|---|---|---|
| SDR 480/720/1080 | H.264 | BGRA 8-bit | Rec.709 |
| SDR 2K/4K | HEVC (Main) | BGRA 8-bit | Rec.709 |
| HDR 全档位 | HEVC Main 10 | 420YpCbCr10 | BT.2020 PQ |

理由：

- 480/720/1080 SDR 用 H.264 保证最广兼容性
- 2K/4K SDR 用 HEVC 控制文件大小（HEVC 同质量约比 H.264 小 35%）
- HDR 必须 HEVC Main 10（10-bit），AVAssetWriter 唯一支持的 HDR 编码

### 6.4 常量表落地

建议在 `Models/ExportConfig.swift` 旁新建 `Rendering/ExportEncodingProfile.swift` 集中维护：

```swift
struct ExportEncodingProfile {
    static func bitrate(for config: ExportConfig) -> Int {
        let base: Double = {
            switch (config.resolution, config.bitrateTier) {
            case (.p480,  .low):         return 1_000_000
            case (.p480,  .recommended): return 2_500_000
            case (.p480,  .high):        return 4_000_000
            case (.p720,  .low):         return 2_500_000
            case (.p720,  .recommended): return 5_000_000
            case (.p720,  .high):        return 8_000_000
            case (.p1080, .low):         return 5_000_000
            case (.p1080, .recommended): return 8_000_000
            case (.p1080, .high):        return 12_000_000
            case (.k2,    .low):         return 10_000_000
            case (.k2,    .recommended): return 16_000_000
            case (.k2,    .high):        return 24_000_000
            case (.k4,    .low):         return 20_000_000
            case (.k4,    .recommended): return 35_000_000
            case (.k4,    .high):        return 50_000_000
            }
        }()
        let fpsMultiplier: Double = {
            switch config.fps {
            case .fps24, .fps25, .fps30: return 1.0
            case .fps50, .fps60:         return 1.2
            case .fps120:                return 1.5
            }
        }()
        return Int(base * fpsMultiplier)
    }

    static func codec(for config: ExportConfig) -> AVVideoCodecType {
        if config.hdrEnabled { return .hevc }   // HEVC Main 10
        return config.resolution.size.width >= 2560 ? .hevc : .h264
    }
}
```

---

## 七、HDR 增量（M4）

### 7.1 M3 默认行为

- `ExportConfig.hdrEnabled` 默认 true（`default(for: canvas)` 派生 + `factoryDefault` 兜底常量均为 true）
- `ExportConfigSheet` HDR Toggle 永远 disabled，下方显示"智能 HDR 即将上线"
- `VideoExporter.downgradeIfNeeded` 在 M3 总是降级为 SDR（即使 cfg.hdrEnabled=true 也按 SDR 编码）

理由：M3 上线时让 UI 完整呈现但编码暂走 SDR；M4 解禁后用户无感切换。

### 7.2 M4 解禁

- `ExportConfigSheet.isHDRAvailable` 改为查询真实 `canEncodeHDR()`
- `VideoExporter.downgradeIfNeeded` 启用 HDR 编码分支
- ExportEncodingProfile.codec 返回 HEVC（hdrEnabled=true 时）

### 7.3 HDR 帧搬运的额外要求

- `AVAssetReaderVideoCompositionOutput.videoSettings` 需指定 `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`
- composition 上游帧需有 HDR 色彩信息（V5 暂不做 HDR 源素材标注；用 BT.2020 转译规则由系统自动处理 SDR→HDR 提升）
- 输出文件 metadata 需含 `colorPropertiesDictionary` 标记 BT.2020 PQ（VideoToolbox 自动写入）

### 7.4 HDR 验证

ffprobe 校验：

```bash
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,pix_fmt,color_space,color_transfer,color_primaries \
  output.mp4
# 期望：
# codec_name=hevc
# pix_fmt=yuv420p10le
# color_space=bt2020nc
# color_transfer=smpte2084
# color_primaries=bt2020
```

---

## 八、关键文件与改动量

| 文件 | 类型 | 改动 |
|---|---|---|
| [Rendering/CompositionBuilder.swift:51-67](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) | 修改 | `build` 新增可选 renderSize/fps 参数；内部 actualRenderSize/actualFPS 替换（≈ 15 行） |
| [Export/VideoExporter.swift:74-120](../../Sources/TimelineKit/Export/VideoExporter.swift) | **整体改写** | `exportToFile` 由 AVAssetExportSession 重写为 AVAssetWriter；新增 makeVideoInput / makeAudioInput / copyVideoSamples / copyAudioSamples / downgradeIfNeeded / canEncodeHDR / makeOutputURL 等辅助方法（≈ 350 行，参考 [StaticImageRenderer.swift:107-180](../../Sources/TimelineKit/Rendering/StaticImageRenderer.swift) 模式） |
| [Export/VideoExporter.swift:24-50](../../Sources/TimelineKit/Export/VideoExporter.swift) `export(timeline:)` | 修改 | 读取 `timeline.effectiveExportConfig`（nil → 按 canvas 派生默认）；调 `build(renderSubtitles: true, renderSize: cfg.resolution.size, fps: cfg.fps.value)`；调 `exportToFile(result, config: cfg)`（≈ 8 行） |
| `Rendering/ExportEncodingProfile.swift` | **新增** | 档位→编码参数映射常量表 + bitrate/codec 静态方法（≈ 70 行） |

**不改动**：

- `CompositionBuilder.build` 现有内部主逻辑（仅参数 nil 时按原逻辑走）
- `SubtitleFrameBuilder.build`（已按 renderSize 参数化）
- `StaticImageRenderer.swift`（独立路径，本期不动）
- `CompositionCoordinator.swift`（编辑画布预览不消费 ExportConfig）
- `FullScreenPreviewController.swift`（全屏预览用 timeline.canvas 原尺寸，不传 renderSize）
- EditorTimeline / EditorMetadata / EditorSegment / EditorTrack 等模型（[export-config-panel-spec.md](export-config-panel-spec.md) §3 已定义 ExportConfig）
- 公共 API `VideoExporter.export(timeline:)` 签名

---

## 九、性能与边界

### 9.1 性能预算

| 场景 | 标准 |
|---|---|
| 1080P / 30fps / 推荐 / SDR 60s 时长 | 与 V4（AVAssetExportSession）耗时 ±10% 内（基准：iPhone 14 实测）|
| 4K / 60fps / 较高 / SDR 60s | 不超过 1080P/30 推荐档耗时的 3 倍 |
| 4K / 120fps / 较高 / HDR 60s | 记录为重负载组合；不保证耗时上限；不崩即可 |
| 进度上报频率 | 30Hz 同步（与视频帧 pts 同步）|

### 9.2 内存

- AVAssetWriter 单帧驻留 ≈ size × 4 bytes（BGRA）；1080P ≈ 8MB / 帧；4K ≈ 32MB / 帧
- HDR 10-bit YUV ≈ size × 2 bytes；1080P ≈ 4MB / 帧
- 并发 video + audio task 双 buffer → 内存峰值约为 2-3 帧
- M5 真机记录峰值入 KPI 附录

### 9.3 风险

| 风险 | 缓解 |
|---|---|
| AVAssetWriter copyVideoSamples 与 expectsMediaDataInRealTime=false 模式下 isReadyForMoreMediaData 异步等待逻辑 | 用 `requestMediaDataWhenReady(on:using:)` + AsyncStream 桥接到 async/await；或参考 StaticImageRenderer 的 polling 模式 |
| videoComposition 在 AVAssetReader 上的 customVideoCompositorClass（UnifiedCompositor）适配 | M3 验证：UnifiedCompositor 是否可与 AVAssetReader 共存；若不行，改走 single-pass 路径 |
| HDR 在不同设备能力差异（iPhone 12 Pro+ 支持录制；iPhone X 仅支持回放）| canEncodeHDR dry-run 检测 + UI Toggle disabled，避免运行时崩溃 |
| 4K HEVC 编码在低端设备（iPhone XS 以下）耗时过长 | 不强制限制；UI 不提示警告（让用户体感慢但能完成）|
| AAC 音频与原 audioMix 重新编码可能损失质量 | 沿用 V4 AAC 128k 固定参数；与 V4 体验一致 |

---

## 十、验收

### 10.1 build 函数参数透传（M3 验收）

| Case | 验收 |
|---|---|
| C1 调 `build(timeline)` 不传新参数 | renderSize = timeline.canvas size；fps = canvas.fps；与 V4 完全一致 |
| C2 调 `build(timeline, renderSize: 3840×2160, fps: 60)` | videoComposition.renderSize = 3840×2160；frameDuration = 1/60 |
| C3 字幕渲染 | SubtitleFrameBuilder 收到 actualRenderSize；字幕位置按新尺寸缩放 |
| C4 旧调用点（CompositionCoordinator / 全屏预览 / 单元测试）零修改 | 编译通过；运行行为不变 |

### 10.2 AVAssetWriter 改造（M3 验收）

| Case | 验收 |
|---|---|
| C5 H.264 480P 30fps 推荐 SDR 导出 | 文件可播放；ffprobe 校验 codec=h264 / 854×480 / 30fps |
| C6 H.264 1080P 60fps 较高 SDR 导出 | codec=h264 / 1920×1080 / 60fps / bit_rate ≈ 9.6Mbps（8Mbps × 1.2）|
| C7 HEVC 4K 30fps 较高 SDR 导出 | codec=hevc / 3840×2160 / 30fps / bit_rate ≈ 50Mbps |
| C8 选 12 个代表组合连续导出 | 全部完成；ffprobe 各项参数 ±15% 误差内 |
| C9 旧草稿（无 ExportConfig，canvas=1280×720）导出 | 走 `default(for: canvas)` 派生（720P/30/推荐/HDR开）；M3 阶段 HDR 自动降级 SDR；ffprobe 校验 1280×720 / 30fps |
| C10 `VideoExporter.export(timeline:)` 签名 | 与 V4 完全相同；ExportResultView / ClipEditorView 调用方零修改 |
| C11 进度上报 0→1 平滑 | 30Hz 更新；与 V4 体感一致 |

### 10.3 HDR（M4 验收）

| Case | 验收 |
|---|---|
| C12 设备支持 HDR + Toggle 开 + 1080P 推荐 | codec=hevc / pix_fmt=yuv420p10le / color_space=bt2020nc / color_transfer=smpte2084 |
| C13 设备支持 HDR + Toggle 关 | 走 SDR 路径（C5/C6 行为）|
| C14 设备不支持 HDR + Toggle 关（被禁用）+ 导出 | 走 SDR 路径；不崩 |
| C15 M3 阶段 cfg.hdrEnabled=true 但 UI 禁用 | 实际导出走 SDR（downgradeIfNeeded 强制降级）|
| C16 M4 阶段 4K + 120fps + HDR + 高码率 60s | 真机不崩；耗时与内存峰值记录入 KPI 附录（不限硬指标）|

### 10.4 失败路径

| Case | 验收 |
|---|---|
| C17 磁盘空间不足 → writer.append 失败 | 抛错（code: -4）；ExportResultView 显示错误；temp 文件清理 |
| C18 异常中断（应用退后台导致 reader 中断）| 抛错；writer 调 cancelWriting |
| C19 编码参数组合不支持（如未来某档位 + 老设备）| canAdd 检测；抛错（code: -2）|

### 10.5 与 fullscreen-preview-spec 同源验证（M3 集成验收）

- 全屏预览（M1 实现）首帧 与 同条件 SDR 导出文件首帧 像素 diff ≤ 2%
- 验证两条路径上游 `build` 参数完全一致（renderSize / fps / renderSubtitles）

---

## 十一、与 docs/v2 附录 A 的关系

[docs/v2/export-pipeline-spec.md](../v2/export-pipeline-spec.md) 末尾"附录 A：v5 修订条目"承载档位与编码格式权威表（§A.1 / §A.2）；本规范的 §6 档位映射表是 v2 附录 A 的代码侧落地。

任何档位调整（如码率 Mbps 微调、新增编码器档位）应**先改 v2 附录 A**，再同步到本规范 §6 与 `Rendering/ExportEncodingProfile.swift` 常量表；保持 v2 附录 A 为唯一权威来源。

---

## 十二、固定交互约束（V3 已锁 + V4 沿用，本规范全程沿用）

| 约束 | 本规范对应 |
|---|---|
| 轨道点击仅唤起快捷栏 | 本规范不涉及轨道交互 |
| 文本字幕共用 `TextEditPanel` | 本规范不涉及编辑面板 |
| 底部工具栏二态 | 本规范不涉及底部工具栏 |
| 向下完全兼容 | `build` 新参数可选，nil 时行为不变；旧调用点零修改 |
| 安卓 / iOS 双端一致 | 编码档位、码率映射、HDR 行为三大语义双端共享；具体实现由 Android 端单独完成 |
| `mutateSubtitle` 不重建 compositionVersion（S-04） | 本规范不调用 mutate |
| `isMainTrack` 唯一性 | 本规范不修改 track 结构 |

V5 自身约束（写入本规范）：

- **公共 API `VideoExporter.export(timeline:)` 签名锁定**：任何渲染层改造不破坏对外契约
- **`CompositionBuilder.build` 新参数必须为可选**：默认 nil 时行为完全等于 V4
- **HDR 改造不阻塞 SDR 主功能**：M3 SDR 全档位先上线，M4 增量加 HDR
- **档位映射表权威在 v2 附录 A**：本规范 §6 与代码常量表必须与 v2 附录 A 同步
