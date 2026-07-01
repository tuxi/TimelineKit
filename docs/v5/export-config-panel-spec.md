# 导出参数配置面板规范（v5）

> 版本：v5.0
> 状态：规范定稿，待实现
> 优先级：**P1**（M2 数据模型+UI / M3 编码端到端 / M4 HDR 增量）
> 对标产品：剪映 iOS（移动端主对标，规格按钮 + 半屏 Sheet 模型）+ CapCut Desktop + FCP for iPad + LumaFusion
> 依赖：v4 [V4-initiation.md](../v4/V4-initiation.md) §3.1 加法式数据模型变更模式；v3 mutate API 模式；[competitive-benchmarks-v5.md](competitive-benchmarks-v5.md) §1；[render-pipeline-unification-spec.md](render-pipeline-unification-spec.md)（实际编码生效靠该 spec 的 AVAssetWriter 改造）；[docs/v2/export-pipeline-spec.md](../v2/export-pipeline-spec.md) 附录 A（档位与编码格式权威表）

---

## 一、问题陈述

V4 当前导出参数三选一硬编码（[VideoExporter.swift:74-80](../../Sources/TimelineKit/Export/VideoExporter.swift)），用户无任何调节能力：

- 没有 4K / 2K / 480P 档位
- 没有帧率档位（24 / 25 / 30 / 50 / 60 / 120）
- 没有码率档位（较低 / 推荐 / 较高）
- 没有 HDR 开关

数据模型层面，[EditorMetadata](../../Sources/TimelineKit/Models/EditorTimeline.swift)（[EditorTimeline.swift:226-246](../../Sources/TimelineKit/Models/EditorTimeline.swift)）仅含 5 字段（sourceTaskID / sourceWorkflow / productName / createdAt / renderType），**无导出配置挂载点**——无法做到"同一工程再次打开保留上次导出配置"。

UI 层面，[ClipEditorView.swift:197-199](../../Sources/TimelineKit/Views/ClipEditorView.swift) toolbar `topBarTrailing` 仅 `exportButton`（文本"导出"），左侧无规格快捷按钮。

本规范覆盖：**数据模型 ExportConfig + Store mutate API + 规格按钮 + 配置 Sheet + 持久化**。

实际编码生效（`AVAssetWriter` 改造、码率/HDR 透传）见 [render-pipeline-unification-spec.md](render-pipeline-unification-spec.md)。

---

## 二、规则定义

档位与默认值取 [competitive-benchmarks-v5.md](competitive-benchmarks-v5.md) §1.6 规则定档：

| 参数 | 档位 | 出厂默认 |
|---|---|---|
| 分辨率 | 480P / 720P / 1080P / 2K / 4K | **跟随画布**（按 `canvas` 短边匹配最接近档位）|
| 帧率 | 24 / 25 / 30 / 50 / 60 / 120 | **跟随画布**（按 `canvas.fps` 匹配最接近档位）|
| 码率 | 较低 / 推荐 / 较高 | **推荐** |
| 智能 HDR | 开 / 关 | **开** |

> **设计要点**：分辨率与帧率出厂默认**不固定**，而是按 `EditorTimeline.canvas` 派生。当前 [EditorCanvas.Preset](../../Sources/TimelineKit/Models/EditorCanvas.swift) 4 种预设（9:16 / 16:9 / 1:1 / 3:4）短边均为 720 → 新工程默认导出 720P；导入素材若按其原始 canvas 创建（如 1080P 素材），默认导出也跟到 1080P，避免"720P 工程默认 480P 导出"的反直觉。码率与 HDR 与画布无关，取行业经验默认。

规则细节：

- **规格按钮常态文案**：仅显示当前分辨率（"480P" / "720P" / "1080P" / "2K" / "4K"），不显示帧率/码率/HDR
- **持久化粒度**：整份 `ExportConfig` 写入 `EditorMetadata.exportConfig`；任一字段变更立即落盘
- **旧草稿/新工程兼容**：`exportConfig == nil` 时按当前 `canvas` 派生默认（不写回 metadata，避免污染未编辑过的工程）
- **画布变化后的行为**：若 `exportConfig` 已被用户主动修改（非 nil），后续改 canvas 不影响导出配置（用户已选过，尊重选择）；若仍为 nil，每次读取按当前 canvas 重新派生
- **HDR Toggle 启用条件**：M3 阶段暂禁用并显示"即将上线"小字；M4 解禁后实际可点
- **HDR 设备能力**：用户开启 HDR + 设备/系统不支持 → UI Toggle 禁用并显示"当前设备不支持"，导出时静默降级 SDR

---

## 三、数据模型

### 3.1 新增 `Models/ExportConfig.swift`

```swift
import Foundation
import CoreGraphics

/// V5 导出参数配置。挂在 EditorMetadata.exportConfig，nil 时按 canvas 派生默认（见 default(for:)）。
public struct ExportConfig: Codable, Sendable, Hashable {

    // MARK: - Resolution

    public enum Resolution: String, Codable, Sendable, CaseIterable, Hashable {
        case p480, p720, p1080, k2, k4

        public var label: String {
            switch self {
            case .p480:  "480P"
            case .p720:  "720P"
            case .p1080: "1080P"
            case .k2:    "2K"
            case .k4:    "4K"
            }
        }

        /// 16:9 像素尺寸（视频导出主流比例）
        public var size: CGSize {
            switch self {
            case .p480:  CGSize(width:  854, height:  480)
            case .p720:  CGSize(width: 1280, height:  720)
            case .p1080: CGSize(width: 1920, height: 1080)
            case .k2:    CGSize(width: 2560, height: 1440)
            case .k4:    CGSize(width: 3840, height: 2160)
            }
        }
    }

    // MARK: - FrameRate

    public enum FrameRate: Int, Codable, Sendable, CaseIterable, Hashable {
        case fps24 = 24, fps25 = 25, fps30 = 30, fps50 = 50, fps60 = 60, fps120 = 120

        public var label: String { "\(rawValue)" }
        public var value: Double { Double(rawValue) }
    }

    // MARK: - BitrateTier

    public enum BitrateTier: String, Codable, Sendable, CaseIterable, Hashable {
        case low, recommended, high

        public var label: String {
            switch self {
            case .low:         "较低"
            case .recommended: "推荐"
            case .high:        "较高"
            }
        }
    }

    // MARK: - Fields

    public var resolution: Resolution
    public var fps:        FrameRate
    public var bitrateTier: BitrateTier
    public var hdrEnabled: Bool

    public init(
        resolution: Resolution = .p1080,
        fps:        FrameRate  = .fps30,
        bitrateTier: BitrateTier = .recommended,
        hdrEnabled: Bool       = true
    ) {
        self.resolution  = resolution
        self.fps         = fps
        self.bitrateTier = bitrateTier
        self.hdrEnabled  = hdrEnabled
    }

    /// 按画布派生默认配置（V5 推荐方式）：
    /// 分辨率按 canvas 短边匹配最接近档位；帧率按 canvas.fps 匹配最接近档位；
    /// 码率取「推荐」；HDR 默认开。
    public static func `default`(for canvas: EditorCanvas) -> ExportConfig {
        ExportConfig(
            resolution:  Resolution.matching(canvasShortSide: min(canvas.width, canvas.height)),
            fps:         FrameRate.matching(canvasFPS: canvas.fps),
            bitrateTier: .recommended,
            hdrEnabled:  true
        )
    }

    /// 无 canvas 上下文时的兜底常量（仅用于单元测试 / 异常 fallback；
    /// 主流程一律走 `EditorTimeline.effectiveExportConfig` → `default(for: canvas)`）。
    public static let factoryDefault = ExportConfig(
        resolution:  .p1080,
        fps:         .fps30,
        bitrateTier: .recommended,
        hdrEnabled:  true
    )
}

// MARK: - Matching helpers

extension ExportConfig.Resolution {
    /// 按画布短边匹配最接近档位（平局取更高分辨率，优先保画质）
    public static func matching(canvasShortSide shortSide: Int) -> Self {
        let candidates: [(Self, Int)] = [
            (.p480, 480), (.p720, 720), (.p1080, 1080), (.k2, 1440), (.k4, 2160)
        ]
        return candidates.min { a, b in
            let da = abs(a.1 - shortSide)
            let db = abs(b.1 - shortSide)
            if da != db { return da < db }
            return a.1 > b.1   // 平局优先取更高分辨率
        }!.0
    }
}

extension ExportConfig.FrameRate {
    /// 按 canvas.fps 匹配最接近档位（平局取更高帧率）
    public static func matching(canvasFPS fps: Int) -> Self {
        Self.allCases.min { a, b in
            let da = abs(a.rawValue - fps)
            let db = abs(b.rawValue - fps)
            if da != db { return da < db }
            return a.rawValue > b.rawValue
        }!
    }
}
```

#### 派生函数行为示例

| canvas 尺寸 | shortSide | 匹配分辨率 | canvas.fps | 匹配帧率 |
|---|---|---|---|---|
| 720×1280（9:16 默认预设） | 720 | **720P** | 30 | 30 |
| 1280×720（16:9 默认预设） | 720 | **720P** | 30 | 30 |
| 720×720（1:1 默认预设） | 720 | **720P** | 30 | 30 |
| 720×960（3:4 默认预设） | 720 | **720P** | 30 | 30 |
| 1080×1920（自定义竖屏） | 1080 | **1080P** | 60 | 60 |
| 1920×1080（自定义横屏） | 1080 | **1080P** | 30 | 30 |
| 540×960（非标准小尺寸） | 540 | **480P**（\|540-480\|=60 < \|540-720\|=180） | 30 | 30 |
| 600×1066（边界平局） | 600 | **720P**（\|600-480\|=120 = \|600-720\|=120 → 平局取更高）| 30 | 30 |
| 2160×3840（4K 竖屏） | 2160 | **4K** | 60 | 60 |
| — | — | — | 27 | 25（\|27-25\|=2 < \|27-30\|=3）|
| — | — | — | 100 | 120（\|100-120\|=20 < \|100-60\|=40）|

**说明**：候选档位短边 [480, 720, 1080, 1440, 2160]；候选帧率 [24, 25, 30, 50, 60, 120]。最接近优先，距离相等时优先更高档位（保画质）。

### 3.2 修改 `Models/EditorTimeline.swift`

[EditorTimeline.swift:226-246](../../Sources/TimelineKit/Models/EditorTimeline.swift) `EditorMetadata` 新增可选字段：

```swift
public struct EditorMetadata: Sendable, Hashable, Codable {
    public var sourceTaskID: Int?
    public var sourceWorkflow: String?
    public var productName: String?
    public var createdAt: Date
    public var renderType: String?
    public var exportConfig: ExportConfig?     // v5 新增

    public init(
        sourceTaskID: Int? = nil,
        sourceWorkflow: String? = nil,
        productName: String? = nil,
        createdAt: Date = Date(),
        renderType: String? = nil,
        exportConfig: ExportConfig? = nil       // v5 新增
    ) {
        self.sourceTaskID    = sourceTaskID
        self.sourceWorkflow  = sourceWorkflow
        self.productName     = productName
        self.createdAt       = createdAt
        self.renderType      = renderType
        self.exportConfig    = exportConfig
    }
}
```

**Codable 兼容**：

- `EditorMetadata` 是默认合成 Codable，新增可选字段自动 `decodeIfPresent` 容错
- 旧草稿 JSON 不含 `exportConfig` 键 → 反序列化为 `nil` → 加载后 `metadata.exportConfig == nil` → 渲染端按 `canvas` 派生默认（见 §3.3）
- 无字段删除、无重命名、无类型变更 → 100% 向下兼容

### 3.3 工具计算属性

由于派生默认需要 `canvas` 上下文，`effectiveExportConfig` 挂在 `EditorTimeline` 上（不是 `EditorMetadata` 上）：

```swift
extension EditorTimeline {
    /// V5：读取生效的导出配置。
    /// - 若 metadata.exportConfig 已被用户主动设置 → 返回该值
    /// - 否则按当前 canvas 派生默认（分辨率/帧率跟随画布；码率推荐；HDR 开）
    public var effectiveExportConfig: ExportConfig {
        metadata.exportConfig ?? .default(for: canvas)
    }
}
```

**为什么不挂在 EditorMetadata 上**：派生默认必须读 `canvas`，而 `EditorMetadata` 上不持有 `canvas` 引用。如果硬要把 `effectiveExportConfig` 放在 metadata 上，要么强行 fallback 到 `factoryDefault`（1080P），要么把 canvas 作为参数传入 —— 前者偏离"跟随画布"语义，后者使签名变丑。挂在 `EditorTimeline` 上最自然。

调用方约定：

- **UI 读取**：用 `store.timeline.effectiveExportConfig`（永远非 nil）
- **持久化写入**：写到 `timeline.metadata.exportConfig`（非 effective）；首次用户调整时由 nil → 派生值 → 应用用户修改
- **渲染端读取**：`VideoExporter.export(timeline:)` 内 `let cfg = timeline.effectiveExportConfig`

`EditorMetadata` 上不提供 `effectiveExportConfig`（避免与 `EditorTimeline` 同名重复，避免被误用走 `factoryDefault` 兜底路径）。

---

## 四、Store API

### 4.1 新增 `EditorStore.mutateExportConfig`

[Store/EditorStore.swift:11](../../Sources/TimelineKit/Store/EditorStore.swift) 新增方法（复用 v4 已落地的 mutate 模式）：

```swift
extension EditorStore {

    /// V5 导出参数 mutate。任意字段变更立即触发 timeline dirty + 自动落盘。
    /// 第一次 mutate 时把 nil → `default(for: canvas)` 派生值 → 应用 body 修改。
    public func mutateExportConfig(_ body: (inout ExportConfig) -> Void) {
        var cfg = timeline.effectiveExportConfig     // 取派生默认或已持久化值
        body(&cfg)
        timeline.metadata.exportConfig = cfg
        markDirty()                                   // 沿用 v3/v4 DraftStore 自动落盘机制
        // 不需要 compositionVersion bump：导出参数变更不影响实时预览
    }

    /// 一键恢复默认（清回 nil，下次读取按当前 canvas 重新派生）
    public func resetExportConfigToDefault() {
        timeline.metadata.exportConfig = nil
        markDirty()
    }
}
```

**关键约束**（沿用 V1 S-04）：

- `mutateExportConfig` **不重建 compositionVersion**：导出参数仅在导出时消费，不影响实时预览管线，无需触发 [CompositionCoordinator.scheduleRebuild](../../Sources/TimelineKit/Rendering/CompositionCoordinator.swift) 重建
- `mutateExportConfig` **不触发 audioMix 重建**：与导出码率/分辨率/HDR 无关

### 4.2 调用方一览

| 调用点 | 何时调 |
|---|---|
| `ExportConfigSheet` 分辨率 segmented 切换 | `store.mutateExportConfig { $0.resolution = .p1080 }` |
| `ExportConfigSheet` 帧率 segmented 切换 | `store.mutateExportConfig { $0.fps = .fps60 }` |
| `ExportConfigSheet` 码率 segmented 切换 | `store.mutateExportConfig { $0.bitrateTier = .high }` |
| `ExportConfigSheet` HDR Toggle 切换 | `store.mutateExportConfig { $0.hdrEnabled = true }` |
| `ExportConfigSheet` "恢复默认"按钮 | `store.resetExportConfigToDefault()` |
| `VideoExporter.export(timeline:)` 读取 | `let cfg = timeline.effectiveExportConfig` → 透传给 AVAssetWriter |

---

## 五、UI

### 5.1 规格按钮（顶部 toolbar，导出按钮左侧）

修改 [Views/ClipEditorView.swift:197-199, 326-332](../../Sources/TimelineKit/Views/ClipEditorView.swift)：

```swift
// 原 V4
ToolbarItem(placement: .topBarTrailing) {
    exportButton
}

// V5 改造为
ToolbarItem(placement: .topBarTrailing) {
    HStack(spacing: 12) {
        specButton    // v5 新增：规格按钮（左）
        exportButton  // 原导出按钮（右）
    }
}
```

```swift
// v5 新增
private var specButton: some View {
    Button {
        showExportConfig = true
    } label: {
        Text(store.timeline.effectiveExportConfig.resolution.label)   // "480P" / "1080P" / "4K"，新工程跟随画布
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.15))
            .cornerRadius(6)
    }
    .accessibilityLabel("导出规格：\(store.timeline.effectiveExportConfig.resolution.label)")
}

@State private var showExportConfig = false
```

### 5.2 配置 Sheet（沿用 TTSConfigSheet 风格）

新增 `Views/ExportConfigSheet.swift`，参考 [TTSConfigSheet.swift:8-99](../../Sources/TimelineKit/Views/TTSConfigSheet.swift)：

```swift
import SwiftUI

struct ExportConfigSheet: View {

    let store: EditorStore
    var onDismiss: () -> Void

    @State private var cfg: ExportConfig = .factoryDefault   // 临时编辑态；onAppear 后会被 timeline.effectiveExportConfig 覆盖
    @State private var showHDRUnsupported = false

    var body: some View {
        NavigationStack {
            Form {
                Section("分辨率") {
                    Picker("分辨率", selection: $cfg.resolution) {
                        ForEach(ExportConfig.Resolution.allCases, id: \.self) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: cfg.resolution) { _, new in
                        store.mutateExportConfig { $0.resolution = new }
                    }
                }

                Section("帧率") {
                    Picker("帧率", selection: $cfg.fps) {
                        ForEach(ExportConfig.FrameRate.allCases, id: \.self) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: cfg.fps) { _, new in
                        store.mutateExportConfig { $0.fps = new }
                    }
                }

                Section("码率") {
                    Picker("码率", selection: $cfg.bitrateTier) {
                        ForEach(ExportConfig.BitrateTier.allCases, id: \.self) { b in
                            Text(b.label).tag(b)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: cfg.bitrateTier) { _, new in
                        store.mutateExportConfig { $0.bitrateTier = new }
                    }
                }

                Section("高级") {
                    Toggle("智能 HDR", isOn: $cfg.hdrEnabled)
                        .disabled(!isHDRAvailable)        // M3 阶段始终禁用
                        .onChange(of: cfg.hdrEnabled) { _, new in
                            store.mutateExportConfig { $0.hdrEnabled = new }
                        }

                    if !isHDRAvailable {
                        Text(hdrDisabledReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("开启后自动依据原素材色彩动态转译生成 HDR 画质视频")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("恢复默认", role: .destructive) {
                        store.resetExportConfigToDefault()
                        cfg = store.timeline.effectiveExportConfig   // 重新按 canvas 派生
                    }
                }

                Section("说明") {
                    Text("默认跟随当前画布尺寸与帧率自动匹配最接近档位；可手动选择更高/更低分辨率。导出配置随工程保存，下次打开继续沿用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("导出规格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onDismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                cfg = store.timeline.effectiveExportConfig    // 按画布派生 or 已持久化值
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - HDR 能力检测（详见 render-pipeline-unification-spec.md §7）

    private var isHDRAvailable: Bool {
        // M3 阶段：始终 false（HDR Toggle 禁用，显示"即将上线"）
        // M4 阶段：检测设备/系统支持 HEVC Main 10 + BT.2020 PQ
        false   // M3 default
    }

    private var hdrDisabledReason: String {
        // M3 阶段："即将上线"
        // M4 阶段不支持时："当前设备不支持 HDR 编码"
        "智能 HDR 即将上线"
    }
}
```

### 5.3 ClipEditorView Sheet 绑定

```swift
.sheet(isPresented: $showExportConfig) {
    ExportConfigSheet(store: store) {
        showExportConfig = false
    }
}
```

### 5.4 文案与本地化

| 文案 | 中文 |
|---|---|
| Sheet 标题 | 导出规格 |
| Section 标题 | 分辨率 / 帧率 / 码率 / 高级 / 说明 |
| HDR Toggle | 智能 HDR |
| 恢复默认按钮 | 恢复默认 |
| 完成按钮 | 完成 |
| HDR 说明（启用时）| 开启后自动依据原素材色彩动态转译生成 HDR 画质视频 |
| HDR 说明（M3 禁用）| 智能 HDR 即将上线 |
| HDR 说明（M4 设备不支持）| 当前设备不支持 HDR 编码 |
| 整体说明 | 默认跟随当前画布尺寸与帧率自动匹配最接近档位；可手动选择更高/更低分辨率。导出配置随工程保存，下次打开继续沿用。 |

国际化：本期仅中文；与 V4 文案体系一致；后续多语言由独立 localization sprint 处理。

---

## 六、UI 草图

### 6.1 顶部 toolbar（V4 vs V5）

```
V4 现状：
┌──────────────────────────────────────────────────┐
│ ✕                  产品名                  导出  │
└──────────────────────────────────────────────────┘

V5（规格按钮文案跟随画布派生：当前 4 种默认预设短边 720 → 显示"720P"）：
┌──────────────────────────────────────────────────┐
│ ✕                  产品名         [720P]  导出  │
└──────────────────────────────────────────────────┘
                                    ↑
                                 规格按钮
                                 （仅显示分辨率；新工程跟画布；已设置过则跟上次选择）
```

### 6.2 配置 Sheet（半屏 medium detent）

```
┌──────────────────────────────────────────┐
│            导出规格              完成    │   ← navigationBar
├──────────────────────────────────────────┤
│                                          │
│ 分辨率                                   │
│ ┌──────┬──────┬──────┬──────┬──────┐   │
│ │ 480P │ 720P │1080P │  2K  │  4K  │   │   ← segmented
│ └──────┴──────┴──────┴──────┴──────┘   │
│                                          │
│ 帧率                                     │
│ ┌────┬────┬────┬────┬────┬─────┐       │
│ │ 24 │ 25 │ 30 │ 50 │ 60 │ 120 │       │
│ └────┴────┴────┴────┴────┴─────┘       │
│                                          │
│ 码率                                     │
│ ┌──────┬──────┬──────┐                  │
│ │ 较低 │ 推荐 │ 较高 │                  │
│ └──────┴──────┴──────┘                  │
│                                          │
│ 高级                                     │
│ 智能 HDR                       (●○)      │   ← M3 禁用态
│ 智能 HDR 即将上线                        │
│                                          │
│ 恢复默认                                 │
│                                          │
│ 默认跟随当前画布尺寸与帧率自动匹配最    │
│ 接近档位；可手动选择更高/更低分辨率。   │
│ 导出配置随工程保存，下次打开继续沿用。  │
└──────────────────────────────────────────┘
```

---

## 七、持久化

| 阶段 | 行为 |
|---|---|
| 工程创建 | `EditorMetadata.exportConfig = nil`；UI 读取走 `EditorTimeline.effectiveExportConfig` → `default(for: canvas)` 派生（如 9:16/16:9/1:1/3:4 默认预设 → 720P / 30fps） |
| 用户首次修改任一参数 | `mutateExportConfig` 将 nil → `default(for: canvas)` 派生值 → 应用修改 → 写回 metadata |
| 用户继续修改 | 直接写回 metadata 对应字段 |
| `markDirty` 后 | 复用 v3/v4 DraftStore 自动落盘机制，整份 EditorTimeline 序列化为 JSON 写入草稿文件 |
| 用户修改画布尺寸（`canvas` 变更）| 若 `metadata.exportConfig != nil` → 保持用户已选配置不变（尊重选择）；若仍为 nil → 下次读取按新 canvas 重新派生 |
| 工程关闭再打开 | 反序列化后 `metadata.exportConfig` 含最后一次配置；规格按钮文案与 Sheet 初始值都与上次一致 |
| 用户点"恢复默认" | `resetExportConfigToDefault` 清回 nil；下次读取按当前 canvas 重新派生 |

服务端 TimelineExporter schema **不**导出 `exportConfig` 字段（仅本地草稿层；服务端不消费导出配置）。

---

## 八、与渲染端对接

本规范不涉及编码实现。

调用链：

```
ClipEditorView 导出按钮点击
  → showExport = true
  → ExportResultView 出现
  → VideoExporter.export(timeline: store.timeline)
        ↓
        let cfg = timeline.effectiveExportConfig              ← v5 新增（nil → default(for: canvas)）
        let result = try await builder.build(
            from: timeline,
            renderSubtitles: true,
            renderSize: cfg.resolution.size,                  ← v5 透传
            fps:        cfg.fps.value                          ← v5 透传
        )
        let url = try await exportToFile(result, config: cfg) ← v5 AVAssetWriter
```

`exportToFile` 改造为 AVAssetWriter、码率/HDR 透传具体逻辑见 [render-pipeline-unification-spec.md](render-pipeline-unification-spec.md) §4 + §6。

---

## 九、关键文件与改动量

| 文件 | 类型 | 改动 |
|---|---|---|
| `Models/ExportConfig.swift` | **新增** | 完整文件（≈ 130 行，含 Resolution/FrameRate matching 函数 + factoryDefault + default(for:)）|
| `Views/ExportConfigSheet.swift` | **新增** | 完整文件（≈ 130 行） |
| [Models/EditorTimeline.swift:226-246](../../Sources/TimelineKit/Models/EditorTimeline.swift) | 修改 | `EditorMetadata` 加 `exportConfig` 字段（≈ 5 行）；`EditorTimeline` 加 `effectiveExportConfig` 计算属性（≈ 8 行） |
| [Store/EditorStore.swift:11](../../Sources/TimelineKit/Store/EditorStore.swift) | 修改 | 新增 `mutateExportConfig` + `resetExportConfigToDefault`（≈ 15 行） |
| [Views/ClipEditorView.swift:197-199, 326-332](../../Sources/TimelineKit/Views/ClipEditorView.swift) | 修改 | toolbar HStack 加规格按钮；新增 `@State showExportConfig`；`.sheet` 绑定（≈ 25 行） |

**不改动**：

- [Rendering/CompositionBuilder.swift](../../Sources/TimelineKit/Rendering/CompositionBuilder.swift)（renderSize/fps 参数新增由 [render-pipeline-unification-spec.md](render-pipeline-unification-spec.md) §3 负责）
- [Rendering/CompositionCoordinator.swift](../../Sources/TimelineKit/Rendering/CompositionCoordinator.swift)（编辑画布预览管线不消费导出配置）
- [Export/VideoExporter.swift](../../Sources/TimelineKit/Export/VideoExporter.swift)（AVAssetWriter 改造由 render-pipeline-unification-spec 负责；本期仅约定 export(timeline:) 公共签名不变）
- EditorCanvas / EditorSegment / EditorTrack 等其他模型
- TextOverlayView / SubtitleStackView / TextEditPanel 等编辑 UI

---

## 十、风险与边界

### 10.1 规格按钮与现有 toolbar 空间

iPhone SE 等窄屏 toolbar：

- `topBarLeading` = ✕（36×36）
- `topBarTrailing` = `HStack([specButton, exportButton])`（规格 ≈ 50pt + 导出 ≈ 40pt + 间距 12pt = 102pt）
- `title` = productName（自适应居中）

实测 iPhone SE（375pt 宽）：toolbar 可用区 = 375 - 36 - 102 = 237pt，足够 productName 显示 8-12 个汉字，无挤压风险。

### 10.2 跟随画布默认 vs 用户预期

V5 默认跟随画布派生（而非固定 480P/1080P）。与剪映/CapCut 默认固定 1080P 不同。

- **优点**：用户感知最自然——720P 工程默认导出 720P，1080P 工程默认导出 1080P，避免"720P 工程默认 480P 导出"的反直觉
- **缓解**：规格按钮常显当前分辨率，用户随时可见可改；不满意可手动改到任意档位
- **缓解**：持久化后第二次打开同工程显示用户上次选择
- **缓解**：非标准 canvas 尺寸（如 540×960）按距离最近档位匹配（540 → 480P，因为 \|540-480\|=60 < \|540-720\|=180）；边界平局取更高档位（保画质）
- **风险**：若用户改变 canvas 但已持久化 exportConfig，导出分辨率与 canvas 不一致 → 这是设计预期（尊重用户已选）；用户可点"恢复默认"清回 nil 让其重新跟随 canvas

### 10.3 mutateExportConfig 是否触发 compositionVersion

**明确不触发**：导出参数仅在导出时消费，与实时预览无关。沿用 V1 S-04（mutate 不无谓重建）。

### 10.4 旧草稿首次进入 Sheet 后是否回写

用户打开旧草稿（`exportConfig == nil`），进入 Sheet 但**未做任何修改**就关闭：

- Sheet `cfg` 由 onAppear 初始化为 `store.timeline.effectiveExportConfig`（即 `default(for: canvas)` 派生值）；仅用于 UI 显示，不写回 store
- 未调 `mutateExportConfig` → `metadata.exportConfig` 仍为 nil → 草稿不被标 dirty → 不落盘
- 行为正确：不污染未编辑过的旧工程；下次打开仍按 canvas 派生（若期间 canvas 改变，派生值会刷新）

### 10.5 与渲染端 ExportConfig 字段扩展兼容

未来若 V6/V7 在 `ExportConfig` 加字段（如 colorSpace / audioCodec）：

- Codable `decodeIfPresent` 自动容错
- 旧草稿（V5 写入的 4 字段 ExportConfig）反序列化后新字段为 nil/默认值
- 向后扩展无破坏

### 10.6 双端实现差异

Android 端需独立实现等价能力（数据模型 + 规格按钮 + 配置面板）。**语义保持一致**：

- 4 个参数档位完全相同
- 出厂默认跟随画布派生（分辨率/帧率按 canvas 短边与 canvas.fps 匹配最接近档位；码率推荐；HDR 开）
- 规格按钮位置（顶部导出左侧）
- 持久化字段名 `exportConfig`

具体实现细节由 Android 端单独完成，不在本 spec 范围。

---

## 十一、验收

### 11.1 数据模型

| Case | 验收 |
|---|---|
| C1 旧草稿（无 exportConfig 字段）加载，canvas=1280×720 | `metadata.exportConfig == nil`；`timeline.effectiveExportConfig.resolution == .p720`；`.fps == .fps30` |
| C2 旧草稿打开 → 修改任一参数 → 保存 → 重新打开 | 反序列化后 `metadata.exportConfig` 含最后一次配置 |
| C3 旧草稿打开 → 进入 Sheet 但未修改 → 关闭 → 保存 → 重新打开 | `metadata.exportConfig` 仍为 nil（未污染） |
| C4 全新工程（默认 9:16 预设 720×1280）| `exportConfig` 初始化为 nil；规格按钮显示"720P" |
| C5 用户改到 1080P → 保存 → 关闭工程 → 重新打开 | 规格按钮显示"1080P"；Sheet 初始值 1080P |
| C6 ExportConfig Codable round-trip | 4 字段 4 种枚举值全部组合 JSON 编解码后值一致 |
| C7 `resetExportConfigToDefault` | `metadata.exportConfig = nil`；草稿标 dirty；规格按钮重新按 canvas 派生显示 |
| C8 派生匹配规则 | canvas 720 → 720P；540 → 480P；600 → 720P（平局取高）；1080 → 1080P；2160 → 4K；canvas.fps 27 → 25；canvas.fps 100 → 120 |
| C9 用户改 canvas 但已持久化 exportConfig | exportConfig 保持用户选择不变；导出按已选档位执行 |
| C10 用户改 canvas + exportConfig 仍为 nil | 下次读取按新 canvas 重新派生（规格按钮文案刷新）|

### 11.2 UI

| Case | 验收 |
|---|---|
| C11 规格按钮位于导出按钮左侧 | 顶部 toolbar topBarTrailing 内，HStack 第一位 |
| C12 规格按钮文案 | 与 `timeline.effectiveExportConfig.resolution.label` 1:1 |
| C13 规格按钮点击 | Sheet 弹出 ≤ 100ms |
| C14 分辨率 segmented 5 档可选 | 480P / 720P / 1080P / 2K / 4K 显示 |
| C15 帧率 segmented 6 档可选 | 24 / 25 / 30 / 50 / 60 / 120 显示 |
| C16 码率 segmented 3 档可选 | 较低 / 推荐 / 较高 显示 |
| C17 任一档位切换 → 规格按钮刷新 | 同一 frame 内同步 |
| C18 M3 阶段 HDR Toggle | disabled；下方显示"智能 HDR 即将上线" |
| C19 M4 解禁后 HDR Toggle 在支持设备上 | enabled；下方显示"开启后自动依据原素材色彩动态转译生成 HDR 画质视频" |
| C20 M4 不支持设备 HDR Toggle | disabled；下方显示"当前设备不支持 HDR 编码" |
| C21 恢复默认按钮（canvas=1280×720）| 调用 `resetExportConfigToDefault`；Sheet `cfg` 重置为 720P/30；规格按钮显示"720P" |
| C22 完成按钮 | dismiss Sheet；不二次落盘（mutate 已实时落盘） |
| C23 Sheet 半屏 medium detent | 上拉可全屏（large detent 支持）|

### 11.3 持久化

| Case | 标准 |
|---|---|
| 任一字段 mutate | 50ms 内草稿落盘（沿用 v3/v4 DraftStore 节奏） |
| 1000 次连续 mutate | 0 崩溃；草稿文件最终态正确（debounce 合并落盘） |
| markDirty 后是否触发 compositionVersion | **否**（导出参数不影响实时预览） |

### 11.4 集成（与渲染端联调，M3 验收）

由 [render-pipeline-unification-spec.md](render-pipeline-unification-spec.md) §8 主导；本规范关心：

- `VideoExporter.export(timeline:)` 读取 `timeline.effectiveExportConfig` 后透传到 AVAssetWriter
- 导出文件参数与 Sheet 配置 100% 一致（ffprobe 校验）

---

## 十二、固定交互约束（V3 已锁 + V4 沿用，本规范全程沿用）

| 约束 | 本规范对应 |
|---|---|
| 轨道点击仅唤起快捷栏，不遮挡编辑区 | 规格按钮在顶部 toolbar，不在轨道区，不冲突 |
| 文本字幕共用 `TextEditPanel` | 本规范不涉及编辑面板 |
| 底部工具栏二态 | 本规范不涉及底部工具栏 |
| 向下完全兼容 | `exportConfig` 可选字段，旧草稿 100% 兼容 |
| 安卓 / iOS 双端一致 | 4 个参数档位、出厂默认、规格按钮位置三大语义双端共享 |
| `mutateSubtitle` 不重建 compositionVersion（S-04） | `mutateExportConfig` 同样不重建（导出参数不影响实时预览） |
| `isMainTrack` 唯一性 | 不涉及 |

V5 自身约束（写入本规范）：

- **规格按钮文案锁定为分辨率**：不显示 fps / 码率 / HDR（避免文案过长挤压 toolbar）
- **出厂默认跟随画布派生**：分辨率/帧率按 `canvas` 短边与 `canvas.fps` 匹配最接近档位；码率取「推荐」；HDR 取「开」。不再使用固定常量 480P（避免 720P 工程默认 480P 的反直觉）
- **`effectiveExportConfig` 挂在 `EditorTimeline` 而非 `EditorMetadata`**：派生默认需要 canvas 上下文，metadata 上不提供同名属性，避免误用走 factoryDefault 兜底
- **持久化粒度整份 ExportConfig**：不允许只持久化部分字段
- **`mutateExportConfig` 不触发预览重建**：与 V1 S-04 一致
- **canvas 变更不回溯覆盖 exportConfig**：已持久化的导出配置不受后续 canvas 变更影响；用户可点"恢复默认"清回 nil 重新跟随
