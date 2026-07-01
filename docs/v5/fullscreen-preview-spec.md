# 同源全屏真实预览规范（v5）

> 版本：v5.0
> 状态：规范定稿，待实现
> 优先级：**P0**（V5 最大体验缺口；M1 独立可上线）
> 对标产品：剪映 iOS（移动端主对标） / CapCut Desktop / FCP for iPad / LumaFusion（全部产品均提供"全屏预览=成片"同源能力，V4 唯一缺失）
> 依赖：v1 [rendering-architecture-spec.md](../v1/rendering-architecture-spec.md)（烘焙路径与 CompositionBuilder 主结构）；v4 [text-style-fidelity-spec.md](../v4/text-style-fidelity-spec.md)（12 字段预览端补齐为本期同源化的"字段消费完整"前提）；[competitive-benchmarks-v5.md](competitive-benchmarks-v5.md) §2

---

## 一、问题陈述

V4 上线后用户最大反馈：**"调到看着满意，导出却差一点"**。

实锤现状（[CompositionBuilder.swift:46-100](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) 函数注释明示）：

```swift
/// - Parameter renderSubtitles: When `true`, subtitle and text segments are baked
///   into the video composition (used for export).  When `false` (default, used for
///   live preview), the subtitle/text tracks are omitted so the SwiftUI overlay
///   views (`TextOverlayView`, `SubtitleStackView`) remain the sole source of truth
///   and stay interactive / editable.
func build(from timeline: EditorTimeline, renderSubtitles: Bool = false) async throws -> CompositionResult
```

- **预览路径**：`build(renderSubtitles: false)` → AVPlayer 播放无字幕的 composition → SwiftUI `TextOverlayView` / `SubtitleStackView` 叠加层显示字幕（保持可点选 / 可拖拽 / 可调样式）
- **导出路径**：`build(renderSubtitles: true)` → `SubtitleFrameBuilder.renderText` / `UnifiedCompositor` 把字幕烘焙进 video → AVAssetExportSession 输出

V4 [text-style-fidelity-spec.md](../v4/text-style-fidelity-spec.md) 已对齐 12 个字段的**字段消费**，但**绘制库**仍是两套：

| 样式类 | 预览端（SwiftUI 叠加层） | 导出端（CIImage / CALayer 烘焙） | 像素差来源 |
|---|---|---|---|
| 描边 | SwiftUI `.stroke(lineWidth:)` | CoreText 双 draw（先 stroke 再 fill）| 亚像素抗锯齿算法不同 |
| 阴影 | SwiftUI `.shadow(color:radius:x:y:)` | `CGContext.setShadow(offset:blur:color:)` | 模糊半径单位不同（SwiftUI radius 单位 ≈ CG blur / 3）|
| 背景 + 圆角 + padding | SwiftUI `ZStack { RoundedRectangle().fill(...) }` | `CGContext.fill(roundedRect:cornerRadius:)` | 角点平滑度算法不同 |
| 层级 z-order | SwiftUI `ZStack` 排序（隐式按字段顺序）| CALayer `zPosition` + composition track 顺序 | 多段同时间重叠时排序差异 |
| 字幕基础渲染 | CoreText `CTLineDraw`（透传到 Metal） | `NSAttributedString.draw(in:)`（CGContext bitmap）| 字距 / 字形抗锯齿差异 |

只要预览与导出是两条**独立绘制路径**，**像素差永远消不掉**。

### 解决方案：新增"全屏预览"入口，全屏复用导出路径

- 编辑画布常态保持现状（SwiftUI 叠加层 + 字幕交互完全不动）
- 新增全屏入口：触发 `build(renderSubtitles: true)`，独立 AVPlayer 播放该 composition
- 与导出 `VideoExporter.exportToFile` 走**同一函数同一参数**，绝对同源
- 全屏即沉浸式只读上下文，符合主流剪辑器（剪映 / CapCut / FCP / LumaFusion）一致行为，详见 [competitive-benchmarks-v5.md](competitive-benchmarks-v5.md) §2.3

---

## 二、规则定义

### 2.1 同源化机制（路线 1：烘焙 composition + 独立 AVPlayer）

| 项 | 编辑画布常态预览 | 全屏预览（V5 新增） |
|---|---|---|
| 调用 | `build(timeline, renderSubtitles: false)` | `build(timeline, renderSubtitles: true)` |
| 字幕来源 | SwiftUI `TextOverlayView` / `SubtitleStackView` 叠加层 | 烘焙进 composition 的 CIImage / CALayer 帧 |
| 字幕可交互 | ✅ 可拖拽 / 可点选 / 可调样式 | ❌ 只读（沉浸式预览语义） |
| Player 实例 | [CompositionCoordinator.swift:22](../../Sources/TimelineKit/Rendering/CompositionCoordinator.swift) `player` | **独立 AVPlayer**（见 §2.3） |
| 重建触发 | debounce 300ms + `scheduleRebuild` | **首次进入全屏时构建一次，全屏期间不重建** |
| 与导出同源 | ❌ | ✅ 同函数同参数 |

未采纳的路线 2（编辑画布 SwiftUI 叠加层升级为 CIImage 出帧）：改动量极大（`TextOverlayView` / `SubtitleStackView` 整套交互需基于 CIImage 重写），远超 V5 容量；留作 V6/V7 议题。详见 [V5-initiation.md](V5-initiation.md) §1。

### 2.2 不复用 CompositionCoordinator 的理由

[CompositionCoordinator.swift:13-22](../../Sources/TimelineKit/Rendering/CompositionCoordinator.swift)：

```swift
@MainActor @Observable
public final class CompositionCoordinator {
    let player = AVPlayer()
    // debounce 300 ms，rebuild 后 swap PlayerItem
}
```

- 该 player **绑定编辑用 AVPlayerItem**（无字幕），全屏预览需要的是**有字幕**的 composition
- debounce 300ms 是为编辑场景设计（避免高频 mutate 触发频繁重建），与全屏预览"打开瞬间即最终态"的语义不符
- 共用会污染编辑画布的播放状态（播放头、缓冲位置）

→ **新建 `FullScreenPreviewController`**，独立持有 `AVPlayer + CompositionResult`，全屏期间与编辑画布完全隔离。

### 2.3 独立 player 生命周期

```
进入全屏：
  1. ClipEditorView 触发 fullScreenCover binding
  2. FullScreenPreviewView 创建 FullScreenPreviewController(timeline:)
  3. controller.build() → builder.build(renderSubtitles: true)
  4. 构建 AVPlayerItem(composition) → AVPlayer.replaceCurrentItem
  5. 取首帧（AVAssetImageGenerator）显示为 loading 占位
  6. 首帧 ready → player.play()

全屏期间：
  - 不监听 EditorTimeline 变化
  - 不重建 composition（即使用户在退出后做了编辑，需重新进入全屏才看到最新）
  - player.seek 帧级精度

退出全屏：
  1. controller 记录 player.currentTime → exitPlayheadTime
  2. player.pause + replaceCurrentItem(nil) 释放
  3. FullScreenPreviewView dismiss
  4. ClipEditorView 接收 exitPlayheadTime → 调 EditorStore 写回 selection.playheadTime
  5. 编辑画布 CompositionCoordinator 接收 store 变化 → seek 编辑用 player 到该时刻
```

### 2.4 进度拖拽精度（帧级）

```swift
// FullScreenPreviewController.seek(to:)
player.seek(
    to: CMTime(seconds: targetSeconds, preferredTimescale: 600),
    toleranceBefore: .zero,
    toleranceAfter:  .zero
)
```

`toleranceBefore/After: .zero` 强制帧级精确 seek（与 [competitive-benchmarks-v5.md](competitive-benchmarks-v5.md) §2.4 剪映/CapCut/FCP/LumaFusion 行为一致）。

代价：高频拖拽时 seek 可能有少量丢帧（AVPlayer 帧级 seek 需要 IDR 帧定位）；可接受，与编辑画布 seek 体感一致。

### 2.5 退出后状态保持

退出全屏时：

- `controller.exitPlayheadTime = player.currentTime`（最后停留时刻）
- `FullScreenPreviewView.onDismiss` 回调 `ClipEditorView`
- `EditorStore.selection.playheadTime = exitPlayheadTime`
- 编辑画布的 `CompositionCoordinator.player.seek(to: exitPlayheadTime)`

用户感知：从全屏退出后，编辑画布播放头跳到全屏最后停留位置，上下文连续。

---

## 三、实现

### 3.1 新增文件

#### 3.1.1 `Rendering/FullScreenPreviewController.swift`

```swift
import AVFoundation
import UIKit

@MainActor @Observable
final class FullScreenPreviewController {

    // MARK: - Public state

    private(set) var isReady = false
    private(set) var firstFrameImage: UIImage?    // loading 占位首帧
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false

    let player = AVPlayer()

    // MARK: - Internal

    private let builder = CompositionBuilder()
    private var compositionResult: CompositionResult?
    private var timeObserver: Any?
    private(set) var exitPlayheadTime: CMTime = .zero

    // MARK: - Lifecycle

    init() {
        player.actionAtItemEnd = .pause
    }

    deinit {
        if let obs = timeObserver { player.removeTimeObserver(obs) }
    }

    // MARK: - Build

    /// 构建烘焙 composition（renderSubtitles: true）；与 VideoExporter 同源
    func build(timeline: EditorTimeline) async {
        do {
            let result = try await builder.build(from: timeline, renderSubtitles: true)
            self.compositionResult = result
            self.duration = result.composition.duration.seconds

            // 取首帧作为 loading 占位
            firstFrameImage = await generateFirstFrame(result: result)

            let item = AVPlayerItem(asset: result.composition)
            item.videoComposition = result.videoComposition
            item.audioMix         = result.audioMix
            player.replaceCurrentItem(with: item)

            setupTimeObserver()
            isReady = true
        } catch {
            // 失败显示错误态；用户退出后无副作用
            isReady = false
        }
    }

    // MARK: - Control

    func play()  { player.play();  isPlaying = true  }
    func pause() { player.pause(); isPlaying = false }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func recordExitPlayhead() {
        exitPlayheadTime = player.currentTime()
    }

    // MARK: - Private

    private func generateFirstFrame(result: CompositionResult) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: result.composition)
        generator.videoComposition = result.videoComposition
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        return await Task.detached {
            (try? generator.copyCGImage(at: time, actualTime: nil)).map(UIImage.init(cgImage:))
        }.value
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)  // 50ms 进度更新
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = time.seconds
        }
    }
}
```

#### 3.1.2 `Views/FullScreenPreviewView.swift`

```swift
import SwiftUI
import AVKit

struct FullScreenPreviewView: View {
    let timeline: EditorTimeline
    let onDismiss: (CMTime) -> Void   // 回传退出时的 playhead

    @State private var controller = FullScreenPreviewController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if controller.isReady {
                PlayerLayerView(player: controller.player)
                    .ignoresSafeArea()

                VStack {
                    Spacer()
                    controlBar
                }
            } else {
                // Loading 态：显示首帧占位 + spinner
                if let img = controller.firstFrameImage {
                    Image(uiImage: img).resizable().scaledToFit()
                }
                ProgressView().tint(.white)
            }
        }
        .task {
            await controller.build(timeline: timeline)
            controller.play()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private var controlBar: some View {
        HStack(spacing: 24) {
            Button(action: { controller.isPlaying ? controller.pause() : controller.play() }) {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
            }

            Slider(
                value: Binding(
                    get: { controller.currentTime },
                    set: { controller.seek(to: $0) }
                ),
                in: 0...max(controller.duration, 0.1)
            )
            .accentColor(.white)

            Text(formatTime(controller.currentTime) + " / " + formatTime(controller.duration))
                .font(.caption.monospacedDigit())
                .foregroundColor(.white)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.2))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
    }

    private func dismiss() {
        controller.pause()
        controller.recordExitPlayhead()
        onDismiss(controller.exitPlayheadTime)
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let v = PlayerContainerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
```

### 3.2 ClipEditorView 接线

[ClipEditorView.swift:8-34](../../Sources/TimelineKit/Views/EditorControlBar.swift) 之外的接入点（顶层 ClipEditorView 自身）：

```swift
struct ClipEditorView: View {
    @State private var store: EditorStore
    @State private var showFullScreenPreview = false  // v5 新增

    var body: some View {
        // ...
        .fullScreenCover(isPresented: $showFullScreenPreview) {
            FullScreenPreviewView(timeline: store.timeline) { exitTime in
                showFullScreenPreview = false
                // 回写编辑画布播放头
                store.selection.playheadTime = exitTime
                // 通知 CompositionCoordinator 同步 seek（沿用 v4 已有 selection 监听链）
            }
        }
    }
}
```

### 3.3 EditorControlBar 新增按钮

[EditorControlBar.swift:8-34](../../Sources/TimelineKit/Views/EditorControlBar.swift) 当前 HStack 含 backward / play / forward 三按钮；右侧追加：

```swift
// v5 新增：全屏预览入口
Button(action: { showFullScreenPreview = true }) {
    Image(systemName: "arrow.up.left.and.arrow.down.right")
        .font(.system(size: 18, weight: .medium))
        .foregroundColor(.white)
        .frame(width: 36, height: 36)
}
.accessibilityLabel("全屏预览")
```

`showFullScreenPreview` 通过 EnvironmentObject 或 binding 传递到上层 `ClipEditorView`。

### 3.4 入口位置与图标

| 位置 | 详情 |
|---|---|
| 文件 | [EditorControlBar.swift:8-34](../../Sources/TimelineKit/Views/EditorControlBar.swift) |
| HStack 位置 | backward / play / forward 三按钮右侧追加 |
| 图标 | `arrow.up.left.and.arrow.down.right`（SF Symbols 标准"展开全屏"图标，与 iOS 视频播放器原生一致） |
| 尺寸 | 18pt，36×36 触达区 |
| 颜色 | white（与同栏其他按钮一致） |
| 可见性 | 始终可见；timeline 为空时禁用（disabled when `store.timeline.tracks.allSegments.isEmpty`） |

---

## 四、数据模型变更

**无任何字段新增**。本规范是纯视图层 + 渲染调用方式改动，不动 EditorTimeline / EditorMetadata / EditorSegment / EditorTrack 等模型。

---

## 五、UI 草图

### 5.1 编辑器底部 Controls 栏（V4 现状 vs V5）

```
V4 现状：
┌──────────────────────────────────────────┐
│         ⏮      ▶      ⏭                  │
│       backward play  forward             │
└──────────────────────────────────────────┘

V5（新增右侧全屏按钮）：
┌──────────────────────────────────────────┐
│      ⏮      ▶      ⏭         ⤢          │
│   backward play forward    fullscreen    │
└──────────────────────────────────────────┘
```

### 5.2 全屏预览界面

```
┌─────────────────────────────────────────────────────┐
│                                                       │
│                                                       │
│                                                       │
│         [ 烘焙 composition 视频帧 ]                    │
│         字幕已烘焙进画面，与导出完全一致               │
│                                                       │
│                                                       │
│                                                       │
│  ▶  ━━━━━●━━━━━━━━━━━━━━  0:12 / 0:45    ✕         │
│  播放 进度条                时间显示       退出       │
└─────────────────────────────────────────────────────┘
状态栏隐藏，沉浸式全屏；底部控制栏在 16:9 视频上下黑边内显示
```

---

## 六、性能预算

| 操作 | 预算 | 备注 |
|---|---|---|
| 全屏入口点击 → 显示首帧 loading | ≤ 50ms | 仅 UI 状态切换 |
| 首帧 loading → 首帧可播放（isReady=true） | ≤ 500ms | 包含 `builder.build(renderSubtitles: true)` + `generateFirstFrame` |
| 拖拽进度 → 新位置首帧 | ≤ 200ms | `player.seek` 帧级精度，与编辑画布 seek 等价 |
| 播放/暂停响应 | ≤ 16ms | 同步操作 |
| 退出全屏 → 编辑画布 seek 完成 | ≤ 200ms | controller 释放 + 编辑 player seek |

首帧延迟 500ms 是关键预算。来源拆解：

- `builder.build(renderSubtitles: true)`：通常 200-400ms（取决于 timeline 长度 + 字幕数量）
- `AVAssetImageGenerator.copyCGImage`：50-150ms
- AVPlayer.replaceCurrentItem + 首帧 decode：50-100ms

若实测超出，可启动时先显示导出 cover image（[VideoExporter.swift:54-70](../../Sources/TimelineKit/Export/VideoExporter.swift) 已有 `generateCover` 复用逻辑）作为 placeholder。

---

## 七、关键文件与改动量

| 文件 | 类型 | 改动 |
|---|---|---|
| `Rendering/FullScreenPreviewController.swift` | **新增** | 完整文件（≈ 120 行） |
| `Views/FullScreenPreviewView.swift` | **新增** | 完整文件（≈ 150 行） |
| [Views/EditorControlBar.swift:8-34](../../Sources/TimelineKit/Views/EditorControlBar.swift) | 修改 | HStack 追加全屏按钮（≈ 10 行） |
| [Views/ClipEditorView.swift](../../Sources/TimelineKit/Views/ClipEditorView.swift) | 修改 | 新增 `@State showFullScreenPreview`；`.fullScreenCover` 修饰器（≈ 12 行） |

**不改动**：

- [Rendering/CompositionBuilder.swift](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift) `build` 函数（本期复用既有签名；V5 P1 阶段会新增 renderSize/fps 可选参数，但 P0 不需要——全屏预览用 timeline.canvas 原值即可）
- [Rendering/CompositionCoordinator.swift](../../Sources/TimelineKit/Rendering/CompositionCoordinator.swift)（编辑画布预览路径完全保持原样）
- [Export/VideoExporter.swift](../../Sources/TimelineKit/Export/VideoExporter.swift)（导出路径在 P1 阶段重写；P0 不动）
- [Views/EditorPreviewView.swift](../../Sources/TimelineKit/Views/EditorPreviewView.swift) / TextOverlayView / SubtitleStackView（编辑画布 SwiftUI 叠加层与字幕交互完全保持原样）
- EditorTimeline / EditorMetadata / EditorSegment / EditorTrack 等模型

---

## 八、风险与边界

### 8.1 与编辑画布 player 状态隔离

`FullScreenPreviewController.player` 与 `CompositionCoordinator.player` 是**两个独立 AVPlayer 实例**。

- 全屏期间编辑画布 player 保持暂停（用户进入全屏前的最后状态）；不与全屏 player 竞争解码资源
- 退出全屏时通过 `exitPlayheadTime` 回写 store，编辑画布 player 接收 store 变化 seek 到该时刻
- 不存在"两个 player 同时播放音频"风险

### 8.2 全屏期间编辑变化不反映

设计明示：**全屏期间用户即使通过其他途径修改了 timeline（如系统返回手势触发的 undo），全屏内不感知**。

- 用户需退出全屏，编辑完成，再次进入全屏才能看到最新效果
- 与剪映 / CapCut / FCP 行为一致（全屏即"快照预览"，不是"实时编辑预览"）

### 8.3 大工程构建耗时

`builder.build(renderSubtitles: true)` 在长 timeline（> 60s）+ 多字幕（> 50 条）场景下可能超出 500ms 预算。

- 缓解 1：首帧 loading 阶段先显示导出 cover image（若 [VideoExporter.coverImage](../../Sources/TimelineKit/Export/VideoExporter.swift) 可复用）
- 缓解 2：M5 真机测试记录大工程实测耗时，超出预算的话考虑预构建（编辑画布常态预览 `scheduleRebuild` 时也偷偷构建一份烘焙 composition 作为 cache）
- 缓解 3：实测超出的话在 §6 性能预算表中调整阈值并记录

### 8.4 内存压力

烘焙 composition 含 CIImage 字幕帧；多字幕场景内存占用可能高于编辑画布预览。

- 退出全屏时 `controller.player.replaceCurrentItem(nil)` + `compositionResult = nil` 主动释放
- M5 真机测试记录内存峰值

### 8.5 横竖屏

iPhone 默认竖屏；全屏内若视频是 9:16 → 适配良好；若是 16:9 → 上下黑边 + 控件浮在黑边内（参考 §5.2 草图）。

V5 不强制旋转（保持 SwiftUI 默认行为）；用户可手动旋转设备，AVPlayer 会自然响应 contentMode。

### 8.6 退出手势冲突

iOS 系统返回手势（从屏幕左边缘右滑）在 `fullScreenCover` 内默认不触发 dismiss；用户必须点 ✕ 按钮退出。

- 与剪映行为一致（剪映全屏内也只能点 ✕ 退出）
- 避免误触退出（沉浸式预览语义）

### 8.7 双端实现差异

Android 端需独立实现等价能力（同源烘焙 + 独立播放器 + 全屏容器）。**语义保持一致**：

- 全屏入口位于底部播放控制栏
- 全屏即沉浸式只读
- 退出后编辑画布播放头跳到全屏最后位置

具体实现细节由 Android 端单独实现，不在本 spec 范围。

---

## 九、验收

### 9.1 功能（5 类样式对照矩阵）

构造 5 个最小工程，每个突出一类样式：

| Case | 样式焦点 | 工程内容 | 验收 |
|---|---|---|---|
| **C1 描边** | strokeColor=红 / strokeWidth=3 | 1 段字幕 "测试 stroke" | 全屏首帧 vs 同条件导出首帧 CIImage 像素 diff ≤ 2% |
| **C2 阴影** | shadowColor=黑 / shadowRadius=4 / shadowOffsetX=2 / shadowOffsetY=2 | 1 段字幕 "测试 shadow" | 同上 |
| **C3 背景 + padding** | backgroundColor=蓝 / backgroundRadius=8 / paddingH=12 / paddingV=6 | 1 段字幕 "测试背景" | 同上；圆角平滑度对齐 |
| **C4 层级 z-order** | 3 段同时间字幕，userZOrder 分别为 0 / 1 / 2 | 三段水平错开 20pt 重叠 | 全屏与导出层级顺序一致 |
| **C5 字幕基础渲染** | font=PingFangSC-Regular / fontSize=48 / color=白 | 长文本 "字幕基础渲染像素一致性验证" | 字距 / 字形 / 抗锯齿对齐 |

像素 diff 工具：自写 CIImage `CIDifferenceBlendMode` + 直方图统计；或集成 `perceptualdiff` CLI。落地为 XCTest 集成测试，CI 强制门禁。

### 9.2 功能（操作）

| Case | 验收 |
|---|---|
| C6 | 点击底部全屏按钮 → 全屏 sheet 弹出；500ms 内首帧可见 |
| C7 | 全屏内点播放/暂停 → 状态切换 ≤ 16ms |
| C8 | 拖拽进度条 → 新位置首帧 ≤ 200ms |
| C9 | 点 ✕ → 全屏 dismiss → 编辑画布播放头跳到全屏最后位置 |
| C10 | 全屏期间修改 timeline（理论上不可能，因为全屏遮挡编辑界面）→ 全屏内不感知（设计预期） |
| C11 | 空 timeline 进入全屏 → 全屏按钮 disabled，无法点击 |
| C12 | 单段视频 + 无字幕场景 → 全屏与编辑画布完全一致（无字幕路径同源天然成立） |

### 9.3 性能

| 操作 | 标准 |
|---|---|
| 全屏入口点击 → 显示首帧 loading | ≤ 50ms |
| 首帧 loading → 首帧可播放 | ≤ 500ms（含 build + generateFirstFrame） |
| 拖拽进度 → 新位置首帧 | ≤ 200ms |
| 退出全屏 → 编辑画布 seek 完成 | ≤ 200ms |
| 1080P / 30fps / 60s 时长 + 20 条字幕场景 | 首帧 ≤ 500ms；内存峰值 ≤ 300MB（真机记录入 KPI 附录） |

### 9.4 稳定性

| Case | 标准 |
|---|---|
| 连续 10 次进入退出全屏 | 0 崩溃；内存无累积泄漏（Instruments 验证） |
| 全屏期间收到来电中断 | AVPlayer 自动暂停；恢复后用户可手动 play |
| 大工程（120s + 80 字幕）进入全屏 | 首帧 ≤ 2s（超出预算视为告警，但不视为失败）；内存峰值记录 |
| 旧草稿（v1/v2/v3/v4）打开后进入全屏 | 100% 兼容（不依赖任何 V5 新数据字段） |

---

## 十、固定交互约束（V3 已锁 + V4 沿用，本规范全程沿用）

| 约束 | 本规范对应 |
|---|---|
| 轨道点击仅唤起快捷栏，不遮挡编辑区 | 全屏按钮位于底部 Controls 栏，不与轨道点击冲突 |
| 文本字幕共用 `TextEditPanel` | 全屏内不允许编辑，不涉及 TextEditPanel |
| 底部工具栏二态 | 全屏按钮在 EditorControlBar（播放控制栏），不在 EditorBottomToolbar（编辑工具栏），二态规则不受影响 |
| 向下完全兼容 | 本规范无任何数据模型变更；旧草稿 100% 适用 |
| 安卓 / iOS 双端一致 | 全屏入口位置、沉浸式只读、退出后状态保持三大语义双端共享；具体实现由 Android 端单独完成 |
| `mutateSubtitle` 不重建 compositionVersion（S-04） | 本规范不调用 mutate，不涉及 |
| `isMainTrack` 唯一性 | 本规范不修改 track 结构 |

V5 自身约束（写入本规范）：

- **全屏预览即沉浸式只读**：禁止在全屏内提供任何编辑能力（拖拽字幕 / 点选 / 调样式）
- **不复用 CompositionCoordinator.player**：全屏 player 必须独立，避免污染编辑画布播放状态
- **`build(renderSubtitles: true)` 调用方式不变**：本期复用 V4 既有 `build` 签名；V5 P1 在 [render-pipeline-unification-spec.md](render-pipeline-unification-spec.md) 新增 renderSize/fps 可选参数时也不影响本期实现（默认 nil 兼容）
