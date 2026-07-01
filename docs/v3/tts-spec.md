# 本地系统 TTS 规范（v3）

> 版本：v3.0
> 状态：规范定稿，待实现
> 对标产品：剪映 iOS「文字朗读」（主要）+ Apple `AVSpeechSynthesizer`（实现层）
> 依赖：[multi-track-architecture-spec.md](multi-track-architecture-spec.md)（TTS 配音入轨）；[audio-feature-spec.md](audio-feature-spec.md)（配音段同音频段交互）；[text-entry-spec.md](text-entry-spec.md)（朗读按钮挂载点）

---

## 一、立项背景

项目当前存在两条不兼容的 TTS 路径：

1. **存量服务端逻辑**：服务端把整篇字幕**整段合成一条完整 MP3** 下发客户端，作为音频段挂载。改任意一句台词都要服务端重生整段 MP3 再下发。
2. **缺失客户端能力**：整库无 `AVSpeechSynthesizer` / `AVSpeechUtterance` 调用；用户在客户端编辑文案后无任何「重新生成对应一句配音」的入口。

v3 目标：**在客户端引入逐条独立 TTS 合成能力**，并通过 `ttsSource` 单向引用模型实现「改文案 → 提示重生」交互。旧服务端整段 MP3 路径**不下线**，作为带 `ttsSource = nil` 的普通音频段保留。

---

## 二、竞品分析

### 2.1 剪映 iOS「文字朗读」

| 维度 | 数据 |
|---|---|
| 触发位置 | 文字编辑面板 + 选中字幕段右键菜单 |
| 合成粒度 | **逐条独立**（每条文本 / 字幕单独生成 1 个音频段） |
| 声线 | 男 / 女 / 童音 / 方言 / 明星音色（云端付费） |
| 语速 | 0.5x - 2.0x 滑块 |
| 默认入轨 | 自动新建一条「文字朗读」音轨，时长 = 合成结果实际时长 |
| 改文案后行为 | UI 顶部 Toast 提示「文案已修改，是否重新生成配音」 |
| 单条 / 批量 / 全选 | 三种重生入口均有 |
| 网络依赖 | 大多数音色需联网，「基础男声 / 基础女声」可离线 |

### 2.2 Final Cut Pro

- 无内置 TTS，需要外部录制或第三方插件
- 不提供对标参考

### 2.3 Apple `AVSpeechSynthesizer`（实现参考）

| 维度 | 数据 |
|---|---|
| 离线渲染 API | `write(_:toBufferCallback:)` (iOS 13+) |
| 内置声线 | `AVSpeechSynthesisVoice` 系统注册，按 BCP-47 区分（zh-CN / zh-HK / en-US 等） |
| 自定义参数 | rate（0.0-1.0，默认 0.5 ≈ 1.0x）、pitchMultiplier (0.5-2.0)、volume |
| 性能 | 中文 30 字合成 ≤ 1.0s（iPhone 14） |
| 文件输出 | `AVAudioBuffer` → `AVAudioFile.write(from:)` 生成 .caf / .m4a |

### 2.4 定案

| 维度 | 剪映 | **本规范定案** |
|---|---|---|
| 合成粒度 | 逐条独立 | **逐条独立** |
| 触发位置 | 文字面板 + 字幕右键 | **TextEditPanel 顶部 + SubtitleEditPanel 顶部 + 多选批量 + 全篇一键** |
| 声线 | 男 / 女 / 童 / 明星 | **男 / 女**（基础两种，离线）；预留 voice 字段支持未来扩展 |
| 语速 | 0.5x - 2.0x | **0.5x - 2.0x** |
| 默认入轨 | 新建专属音轨 | **`addSegmentAutoTrack(kind:.audio)` 自动分轨**（沿用 multi-track 规则） |
| 改文案提示 | Toast | **非阻塞 Toast + 「重生」action 按钮**（点 dismiss 则保留旧配音） |
| 单条 / 批量 / 全选 | ✅ 三种 | **✅ 三种 EditorStore 入口** |
| 网络 | 部分需联网 | **完全离线**（AVSpeechSynthesizer 系统语音） |

> **定案依据**：v3 目标是「跑通本地流程，流程稳定后再对接服务端」（用户原始需求 §四 ❌ 暂不做）。Apple 离线 TTS 性能足够、零网络依赖、零成本，是最优起点。明星音色 / 情感语调留待后续接入云端。

---

## 三、规则定义

### 3.1 TTS 配音段的数据归属

TTS 合成产物是一段 m4a 音频，本质上是一个 `.audio` 段，与音频功能 spec 的导入音频在数据模型上**完全同构**——唯一区别是它**额外携带一个 `ttsSource` 引用，指向源 `.text` 或 `.subtitle` 片段**。

```
普通音频段：AudioContent(volume, fade, ..., ttsSource: nil)
TTS 配音段：AudioContent(volume, fade, ..., ttsSource: TTSSource(sourceSegmentID, textHash, voice, rate))
```

### 3.2 触发入口（共 4 处）

| 入口 | 触发动作 | 作用对象 |
|---|---|---|
| `TextEditPanel` 顶部「朗读」按钮 | 单条重生 | 当前选中的 `.text` 片段 |
| `SubtitleEditPanel` 顶部「朗读」按钮 | 单条重生 | 当前选中的 `.subtitle` 片段 |
| 二级面板「文字朗读」stub（多选时启用）| 批量重生 | 当前多选的所有 `.text` / `.subtitle` 片段 |
| `.text` 二级面板「全篇朗读」（未来扩展）| 全篇重生 | 全部 `.text` + `.subtitle` 片段（v3 预留入口，UI 已在 [text-entry-spec.md](text-entry-spec.md) 列出） |

### 3.3 单条 TTS 完整流程

```
用户在 TextEditPanel 点击「朗读」按钮
  ↓
弹出 TTSConfigSheet（声线 / 语速 / 试听）
  ├─ 声线：男（com.apple.voice.compact.zh-CN.Tingting / Sin-ji） / 女（com.apple.ttsbundle.Tingting-compact 或同等）
  ├─ 语速：0.5x - 2.0x，默认 1.0x（映射到 AVSpeechUtterance.rate = 0.5）
  └─ 试听按钮：实时播放（不写文件）
  ↓
用户点「应用」
  ↓
TTSService.synthesize(text, voice, rate) → URL
  ├─ 1. cache key = sha1(text + voice + rate)
  ├─ 2. 若已存在 ApplicationSupport/TimelineKit/Assets/_shared/tts/{key}.m4a → 直接返回
  ├─ 3. 否则：
  │     - AVSpeechSynthesizer.write(utterance, toBufferCallback:)
  │     - AVAudioBuffer 收集 → AVAudioFile.write(format:.m4a)
  │     - 落地至上述路径
  └─ 返回 (url, duration)
  ↓
（若该源片段已有引用的 TTS 配音段）→ 先删除旧配音段
  ↓
创建 EditorSegment(
    content: .audio(AudioContent(
        volume: 1.0,
        ttsSource: TTSSource(
            sourceSegmentID: sourceTextOrSubtitleID,
            textHash: sha1(sourceText),
            voice: voiceID,
            rate: rateValue
        )
    )),
    targetRange: TimeRange(start: sourceSegment.targetRange.start, duration: ttsAudioDuration)
)
  ↓
EditorStore.addSegmentAutoTrack(kind: .audio, segment: ttsSegment)
```

**关键约束**：

1. **targetRange.start 与源文本对齐**：TTS 配音段开始时间 = 源 `.text` / `.subtitle` 段开始时间，方便配音随文本出现而播放。
2. **targetRange.duration 取实际合成时长**：不裁切、不延长，由 `AVAudioFile.duration` 决定。
3. **一对一引用**：同一个源片段最多关联 1 个 TTS 配音段；重生时先删除旧的再创建新的（单步 undo）。

### 3.4 改文案提示重生流程

```
用户修改 .text / .subtitle 片段的 text 字段
  ↓
EditorStore.mutateTextContent / mutateSubtitleContent 在 mutate 闭包末尾调用：
  ↓
findTTSAudioSegments(referencing: sourceSegmentID) → [EditorSegment]
  ↓
对每个匹配段：
  ├─ 比对 ttsSource.textHash vs sha1(newText)
  ├─ 不匹配 → 标记为 `staleTTSSegmentIDs`
  ↓
若 staleTTSSegmentIDs 非空：
  → 触发非阻塞 Toast：「配音文案已更新，是否重新生成？[重新生成] [忽略]」
  → 用户点「重新生成」：调用 regenerateTTS(forSourceSegments:) 批量重生
  → 用户点「忽略」：保留旧配音，textHash 不更新（保持 stale 状态，下次编辑面板打开继续提示）
```

### 3.5 服务端整段 MP3 字幕配音兼容

- 现有 [TimelineImporter](../../Sources/TimelineKit/Conversion/TimelineImporter.swift) 解析服务端 schema 中的整段 MP3 字幕配音 → 创建 1 个普通 `.audio` 段，`ttsSource = nil`
- v3 客户端新生成的所有 TTS 配音段 → 必带 `ttsSource`
- 同一草稿可同时存在两种配音段，互不影响
- v3 **不主动迁移**旧资产（不把整段 MP3 拆成逐条），由用户主动删除整段配音并触发逐条重生

### 3.6 EditorStore 三种重生入口

```swift
extension EditorStore {
    /// 单条重生：根据源片段 ID 重生其关联 TTS 配音段。
    public func regenerateTTS(forSourceSegment id: UUID, voice: String, rate: Double) async throws

    /// 多条批量重生：用相同 voice / rate 重生多个源片段的配音。
    public func regenerateTTS(forSourceSegments ids: [UUID], voice: String, rate: Double) async throws

    /// 全篇重生：所有 .text + .subtitle 片段一次性重生。
    public func regenerateAllTTS(voice: String, rate: Double) async throws
}
```

三个入口最终都收敛到单条 `regenerateTTS(forSourceSegment:)`，批量入口循环调用并合并为单步 undo。

### 3.7 v3 暂不做

- 音色特效（明星 / 情感 / 童音 / 方言）
- 情感语调 / 重音控制（SSML）
- 云端 TTS 接入
- 整段打包合成（继续保留服务端老路径，但不在客户端实现）
- 配音段的局部裁剪（裁剪会让 `ttsSource.textHash` 失去语义；用户要改先改文案再重生）

---

## 四、数据模型

### 4.1 `SegmentContent.AudioContent` 扩展

```swift
extension SegmentContent {
    public struct AudioContent: Sendable, Hashable, Codable {
        public var volume: Double
        public var fadeInDuration: Double
        public var fadeOutDuration: Double
        public var isLooping: Bool
        public var isMuted: Bool

        /// v3 新增：标记此音频段为 TTS 合成产物，并保留与源文本片段的关联。
        /// nil 表示普通音频（导入 / 提取 / 服务端 MP3）。
        public var ttsSource: TTSSource?

        public init(
            volume: Double = 1.0,
            fadeInDuration: Double = 0,
            fadeOutDuration: Double = 0,
            isLooping: Bool = false,
            isMuted: Bool = false,
            ttsSource: TTSSource? = nil
        ) {
            self.volume = volume
            self.fadeInDuration = fadeInDuration
            self.fadeOutDuration = fadeOutDuration
            self.isLooping = isLooping
            self.isMuted = isMuted
            self.ttsSource = ttsSource
        }
    }

    public struct TTSSource: Sendable, Hashable, Codable {
        /// 指向源 .text 或 .subtitle 片段的 ID。
        public var sourceSegmentID: UUID

        /// sha1(源文本内容)，用于检测文本是否被修改。
        public var textHash: String

        /// AVSpeechSynthesisVoice.identifier（如 "com.apple.voice.compact.zh-CN.Tingting"）
        public var voice: String

        /// AVSpeechUtterance.rate 的用户视角值 0.5...2.0（1.0 = 自然语速）
        public var rate: Double

        public init(sourceSegmentID: UUID, textHash: String, voice: String, rate: Double) {
            self.sourceSegmentID = sourceSegmentID
            self.textHash = textHash
            self.voice = voice
            self.rate = rate
        }
    }
}
```

**Codable 兼容性**：`ttsSource` 是 `Optional`，旧草稿无此字段 → 反序列化为 `nil`。

### 4.2 文本哈希算法

```swift
func textHash(_ text: String) -> String {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return Insecure.SHA1.hash(data: Data(normalized.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}
```

- 使用 SHA-1：碰撞概率忽略不计，速度比 SHA-256 快 2 倍
- 文案归一化：trim 前后空白，避免肉眼无变化但 hash 不匹配
- **不归一化大小写 / 标点**：用户主动改标点也应触发提示

### 4.3 EditorAsset 路径约定

```
ApplicationSupport/TimelineKit/Assets/_shared/tts/{sha1(text+voice+rate)}.m4a
```

放在 `_shared` 共享池：同样 text + voice + rate 的合成结果可跨 timeline 复用。

---

## 五、实现方案

### 5.1 TTSService

```swift
public actor TTSService {
    public static let shared = TTSService()

    public enum Error: Swift.Error {
        case voiceNotAvailable
        case synthesisFailed(underlying: Swift.Error)
        case cancelled
    }

    /// 离线合成：text + voice + rate → m4a URL + 实际时长
    public func synthesize(
        text: String,
        voice: String,
        rate: Double  // 0.5 - 2.0
    ) async throws -> (url: URL, duration: Double)

    /// 试听：实时播放，不写文件。返回当前 utterance 句柄供取消。
    public func preview(text: String, voice: String, rate: Double) -> AnyCancellable
}
```

实现要点：

1. **AVSpeechSynthesizer 离线渲染**：
   ```swift
   let synth = AVSpeechSynthesizer()
   let utterance = AVSpeechUtterance(string: text)
   utterance.voice = AVSpeechSynthesisVoice(identifier: voice)
   utterance.rate = Float(rate / 2.0)  // 用户 1.0x → 系统 0.5
   var audioFile: AVAudioFile?
   synth.write(utterance) { buffer in
       guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
       if audioFile == nil {
           let settings = pcm.format.settings  // m4a 设置由 AVAudioFile init 转换
           audioFile = try? AVAudioFile(forWriting: outputURL, settings: m4aSettings)
       }
       try? audioFile?.write(from: pcm)
   }
   ```
2. **m4a 编码**：使用 `AVAudioFile` + AAC 设置，与 AudioExtractor 输出格式对齐（256 kbps / stereo / 44.1 kHz）。
3. **缓存**：sha1(text+voice+rate) 命中直接返回缓存路径，不重复合成。
4. **取消**：`Task.cancel()` 中断合成；已写入的部分文件清理。
5. **试听**：用 `synth.speak(utterance)` 直接播放，不调用 `write(_:toBufferCallback:)`。

### 5.2 EditorStore 改造

```swift
extension EditorStore {
    /// 在 mutate 闭包末尾调用，检测 stale TTS 引用。
    private func collectStaleTTSReferences(for sourceID: UUID, newText: String) -> [UUID] {
        let newHash = textHash(newText)
        return timeline.tracks
            .flatMap(\.segments)
            .compactMap { seg -> UUID? in
                guard case let .audio(audio) = seg.content,
                      let src = audio.ttsSource,
                      src.sourceSegmentID == sourceID,
                      src.textHash != newHash
                else { return nil }
                return seg.id
            }
    }

    /// 在 mutateTextContent / mutateSubtitleContent 内部触发。
    public func mutateTextContent(segmentID: UUID, label: String, modify: (inout TextContent) -> Void) {
        var staleIDs: [UUID] = []
        mutate(label) { timeline in
            // ... existing logic ...
            modify(&txt)
            staleIDs = collectStaleTTSReferences(for: segmentID, newText: txt.text)
        }
        if !staleIDs.isEmpty {
            postStaleTTSNotification(staleIDs: staleIDs, sourceID: segmentID)
        }
    }
}
```

Toast 通知由上层 UI 监听 `staleTTSNotification` 显示，不在 store 层做 UI 调用。

### 5.3 TextEditPanel / SubtitleEditPanel 顶部按钮

```swift
// TextEditPanel + SubtitleEditPanel 顶部 HStack 末尾
Button {
    showTTSConfigSheet = true
} label: {
    Image(systemName: "speaker.wave.2")
    Text("朗读")
}
.disabled(currentText.isEmpty)
.sheet(isPresented: $showTTSConfigSheet) {
    TTSConfigSheet(
        defaultVoice: lastUsedVoice,
        defaultRate: lastUsedRate,
        onApply: { voice, rate in
            Task { try? await store.regenerateTTS(forSourceSegment: segmentID, voice: voice, rate: rate) }
        }
    )
}
```

`TTSConfigSheet` 是新增 SwiftUI Sheet 视图，含声线分段控件、语速滑块、试听按钮。`lastUsedVoice` / `lastUsedRate` 存 `UserDefaults`，记忆上次选择。

### 5.4 Stale Toast 显示

[ClipEditorView](../../Sources/TimelineKit/Views/ClipEditorView.swift) 监听 `staleTTSNotification`：

```swift
.onReceive(notificationCenter.publisher(for: .staleTTSNotification)) { note in
    guard let info = note.userInfo as? [String: Any],
          let staleIDs = info["staleIDs"] as? [UUID],
          let sourceID = info["sourceID"] as? UUID
    else { return }
    toastManager.show(.staleTTS(sourceID: sourceID, staleIDs: staleIDs))
}
```

Toast 容器（已存在于 v1 编辑器骨架）增加 `.staleTTS` 样式，含「重新生成」action 按钮触发 `regenerateTTS`。

---

## 六、边界情况

| 情况 | 处理 |
|---|---|
| 用户改文案瞬间已删除关联 TTS 段 | `collectStaleTTSReferences` 返回空，不弹 Toast |
| 同一源片段已有 2 个 TTS 配音段（数据异常）| 重生时全部删除，新建 1 个 |
| AVSpeechSynthesisVoice 找不到对应 identifier（系统语音包未下载）| 抛 `voiceNotAvailable`，Toast 提示「语音包未安装，请到设置 > 辅助功能 下载」 |
| 用户在重生过程中再次修改文案 | 上一次 regen Task 取消，新一次 Task 排队 |
| 重生过程中应用进入后台 | 允许后台继续，60 秒后系统挂起则取消 |
| 文案为空字符串 | 朗读按钮 disabled，无入口触发 |
| 文案纯标点（如 "..."）| 仍可朗读，AVSpeechSynthesizer 生成极短音频（< 0.1s）；产物保留 |
| 草稿迁移：v1/v2 旧草稿无 `ttsSource` 字段 | 反序列化为 `nil`，零迁移 |
| 服务端整段 MP3 字幕配音存在 + 用户手动逐条重生 | 两种段共存，不互相覆盖；用户须自行删除整段 MP3 |
| sha1 碰撞（理论 1/2^80）| 不处理，业务可接受 |
| 同一文本 voice / rate 已缓存 | 直接复用，addSegmentAutoTrack 时长按缓存音频时长取 |

---

## 七、验收标准

| # | 项目 | 标准 |
|---|---|---|
| TTS-01 | 单条合成 | 中文 30 字 ≤ 1.0s 合成完成（iPhone 14） |
| TTS-02 | 自动入轨 | TTS 配音段自动落到 `.audio` 轨，targetRange.start 与源文本对齐 |
| TTS-03 | targetRange.duration | 等于 `AVAudioFile.duration`，误差 ≤ 50ms |
| TTS-04 | 试听 | 试听按钮播放实时音频，不写文件，可中断 |
| TTS-05 | 改文案提示 | 修改源文本 → 500ms 内出现 Toast 提示重生 |
| TTS-06 | 单条重生 | TextEditPanel「朗读」按钮触发后旧配音被替换，单步 undo 可还原 |
| TTS-07 | 批量重生 | 多选 N 个源片段批量重生，单步 undo 还原全部 N 个 |
| TTS-08 | 服务端整段 MP3 共存 | 旧 `ttsSource == nil` 配音段不被 v3 流程影响 |
| TTS-09 | 缓存复用 | 相同 text + voice + rate 二次合成 ≤ 50ms（命中缓存） |
| TTS-10 | 离线运行 | 飞行模式下基础男声 / 女声合成正常完成 |
| TTS-11 | 草稿往返 | `ttsSource` 字段 JSON 序列化 / 反序列化无损 |
| TTS-12 | 取消 | 合成过程中取消，500ms 内停止，临时文件清理 |

---

## 八、与 v1 / v2 接口约束

- **新增**字段 `ttsSource: TTSSource?` 在 `AudioContent`，可选默认 nil，旧草稿零迁移
- **不修改** [WaveformProvider](../../Sources/TimelineKit/Rendering/WaveformProvider.swift)：TTS 配音段作为普通 `.audio` 段，波形按相同规则显示
- **不修改** v1 `mutateText` / `mutateSubtitle` 不重建 composition 规则；TTS 重生触发新增/删除 `.audio` 段会按 [multi-track-architecture-spec §2.5](multi-track-architecture-spec.md) 递增 compositionVersion
- **不修改** 服务端字幕导入流程（整段 MP3 字幕配音继续以 `ttsSource == nil` 形式存在）
- 与 v2 [transition-spec](../v2/transition-spec.md) / [filter-color-spec](../v2/filter-color-spec.md) / [export-pipeline-spec](../v2/export-pipeline-spec.md) 无任何交集

---

## 九、与音频独立变速的联动（v3 P0）

TTS 配音段是 `.audio` 段的一个子类，与普通音频段共用 [audio-feature-spec §8](audio-feature-spec.md) 的独立变速能力：

- 用户对 TTS 段调用 `setAudioSpeed` 仅修改 `EditorSegment.speed` 与 `targetRange.duration`，**不重新合成 m4a**，不影响 `ttsSource.rate`（rate 是合成时参数，speed 是回放时参数）
- 修改 speed 不会触发「文案 stale」Toast（textHash 未变）
- 推荐用法：先按默认 rate 合成，再用 speed 微调字幕节奏对齐，避免反复触发昂贵的合成
- 若用户希望从根本上改变语速（影响合成质量），仍需走 [§3.6 三种重生入口](#36-editorstore-三种重生入口)
