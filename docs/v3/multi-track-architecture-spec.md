# 多轨架构规范（v3）

> 版本：v3.0
> 状态：规范定稿，待实现
> 对标产品：剪映 iOS（主要）+ Final Cut Pro + LumaFusion
> 依赖：v1 [EditorTrack](../../Sources/TimelineKit/Models/EditorTrack.swift) / [EditorTimeline](../../Sources/TimelineKit/Models/EditorTimeline.swift) / [TrackCanvasView](../../Sources/TimelineKit/Views/TrackCanvasView.swift) 基线；本文档为 [audio-feature-spec.md](audio-feature-spec.md) / [text-entry-spec.md](text-entry-spec.md) / [tts-spec.md](tts-spec.md) 的前置

---

## 一、竞品分析

### 1.1 剪映 iOS —— 对标主体

| 维度 | 数据 |
|---|---|
| 主视频轨 | 唯一一条（命名「主轨道」） |
| 画中画 / 叠加层 | 无限新增（每个素材一条） |
| 字幕轨 | 自动字幕、手动字幕、识别歌词，均可叠加多条 |
| 文本轨 | 每条文字片段独占一行，自动按时间分行 |
| 音频轨 | 配乐、音效、提取音频各自独立轨道，可叠加 |
| 新增策略 | 「无时间重叠则复用最近一条，重叠则自动新建一条」 |
| 删除策略 | 轨道清空后自动回收（除非主轨） |
| 显示顺序 | 主轨 → 画中画 → 文本 → 字幕 → 音频，自顶向下 |

剪映核心模型：**主轨唯一 + 其他类型按需自动分轨**，用户不需要手动「新建空轨道」，直接拖素材就触发分轨。

### 1.2 Final Cut Pro —— 专业参考

| 维度 | 数据 |
|---|---|
| Primary Storyline | 唯一 |
| Connected Clips | 无限，按 attach 位置自动分行 |
| Compound Clips | 嵌套时间轴（不在 v3 范围） |
| 字幕（Caption）| 多轨（Roles 区分语言） |

FCP 的 Connected Clips 模型与剪映的「自动分轨」理念一致，区别是 FCP 允许显式 attach 到任意基准点。v3 取剪映的隐式分轨，更适合移动端。

### 1.3 LumaFusion —— iPad 参考

| 维度 | 数据 |
|---|---|
| 视频轨 | 最多 6 条（含主轨） |
| 音频轨 | 最多 6 条 |
| 字幕 | 与文本合并，单一类型多轨 |

LumaFusion 设了上限，体验更接近桌面 NLE。v3 不设上限（与剪映对齐），但在工程文件层面建议每类不超过 8 条以保证性能。

### 1.4 竞品对比汇总

| 维度 | 剪映 | FCP | LumaFusion | **本规范定案** |
|---|---|---|---|---|
| 主视频轨 | 唯一 | 唯一（Primary） | 唯一 | **唯一**（沿用 `isMainTrack`） |
| `.subtitle` 轨上限 | ∞ | ∞ | N/A（合并）| **∞**（软上限 8） |
| `.text` 轨上限 | ∞ | ∞ | N/A | **∞**（软上限 8） |
| `.audio` 轨上限 | ∞ | ∞ | 6 | **∞**（软上限 8） |
| 新增片段分轨策略 | 重叠 → 新建，否则复用 | attach 显式 | 用户指定 | **重叠 → 自动新建，否则复用最近一条** |
| 空轨道自动回收 | 是 | 否 | 否 | **是**（除主轨） |

> **定案依据**：v3 是移动端短视频工具，剪映模型对用户最友好（零认知成本）。`EditorTimeline.tracks` 现状已是数组无唯一性约束（[EditorTimeline.swift:14](../../Sources/TimelineKit/Models/EditorTimeline.swift)），数据层无任何阻碍。软上限 8 仅是性能建议，不在数据层强制，由 UI 提示。

---

## 二、规则定义

### 2.1 轨道唯一性

```
.video        → 主轨道唯一（isMainTrack == true 的轨道仅一条）
.subtitle     → 无上限（软上限 8）
.text         → 无上限（软上限 8）
.audio        → 无上限（软上限 8）
.overlay      → 无上限（软上限 8）
.adjustment   → v3 不涉及，沿用 v1 单条
```

唯一性由 `EditorTimeline.normalizeMainTrack()`（已存在）保证；其他类型在 `addTrack` 入口不强制唯一。

### 2.2 同类多轨自动分配策略（核心规则）

新增片段时的轨道选择伪代码：

```swift
func chooseOrCreateTrack(
    for kind: EditorTrack.Kind,
    newSegmentRange: TimeRange,
    in timeline: EditorTimeline
) -> EditorTrack {
    // 1. 候选：所有同类轨道（按 zPosition 升序、id 升序稳定排序）
    let candidates = timeline.tracks(ofKind: kind)
        .sorted { ($0.zPosition, $0.id.uuidString) < ($1.zPosition, $1.id.uuidString) }

    // 2. 找第一条「与新片段无时间重叠」的轨道
    if let track = candidates.first(where: { track in
        !track.segments.contains { $0.targetRange.overlaps(newSegmentRange) }
    }) {
        return track  // 复用
    }

    // 3. 全部重叠 → 新建一条
    return addTrack(kind: kind, zPosition: nextZPosition(for: kind, in: timeline))
}
```

**规则要点**：

1. **复用优先**：能复用就复用，避免无意义分轨。
2. **重叠定义**：`a.overlaps(b)` 当且仅当 `a.end > b.start && b.end > a.start`（半开区间约定，与 v1 一致）。
3. **稳定排序**：保证幂等。同一组操作多次执行结果一致。
4. **首条特例**：若该类型一条轨道都没有，直接新建一条。
5. **zPosition 自增**：新建时取同类轨道最大 `zPosition + 1`；首条用默认值（`.subtitle`=5、`.text`=10、`.audio`=2、`.overlay`=1，与 v1 一致）。

### 2.3 显示顺序

沿用 [TrackCanvasView](../../Sources/TimelineKit/Views/TrackCanvasView.swift) 现有固定顺序：

```
video → overlay → text → subtitle → audio → adjustment
```

同类多条按 `(zPosition desc, id asc)` 排序。zPosition 高者画面上居上、列表中靠近主轨。

### 2.4 空轨道回收

- **触发**：`removeSegment` 后该轨道 `segments.isEmpty == true` 且 `isMainTrack == false`。
- **行为**：在同一 mutate 闭包中调用 `removeTrackIfEmpty(id:)`，与片段删除合并为单步 undo。
- **例外**：用户通过「+ 新建轨道」UI 显式建立的空轨道**不立即回收**（等待用户拖素材进来），通过一个临时标记 `pendingUserCreated: Bool` 区分；30 秒内若仍为空则自动回收。

### 2.5 `compositionVersion` 触发规则

| 操作 | 是否递增 `compositionVersion` |
|---|---|
| 新增 / 删除 `.audio` 轨道 | ✅ 递增（rebuild） |
| 新增 / 删除 `.video` / `.overlay` 轨道 | ✅ 递增 |
| 新增 / 删除 `.text` / `.subtitle` 轨道 | ❌ 不递增（与 v1 S-04 一致） |
| 新增 / 删除 `.adjustment` 轨道 | ✅ 递增 |
| 向已存在轨道追加片段 | 按片段 kind 决定（沿用 v1 规则） |

### 2.6 v3 暂不做（写入「明确不做」清单）

- 多层混合特效（多文本层透明度混音、字幕花字叠加效果）
- 跨轨道排版合并（剪映「文字模板」多文本组合）
- 文本边框 / 阴影 / 描边 / 花字样式编辑
- 轨道之间的 Compound / Group 嵌套

---

## 三、数据模型

### 3.1 现有模型（v1，无改动）

```swift
public struct EditorTrack: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var kind: Kind
    public var label: String
    public var isMuted: Bool
    public var isLocked: Bool
    public var isHidden: Bool
    public var zPosition: Int
    public var segments: [EditorSegment]
    public var isMainTrack: Bool
}

public enum Kind: String { case video, overlay, text, subtitle, audio, adjustment }
```

`EditorTimeline.tracks: [EditorTrack]` 数组结构无须改动。

### 3.2 EditorTrack 新增字段（可选，v3）

```swift
extension EditorTrack {
    /// 用户在 UI 上显式新建的空轨道标记，避免立即被空轨回收逻辑清理。
    /// 30 秒后由 EditorStore 计时器清零；用户拖入片段后立即清零。
    public var pendingUserCreated: Bool = false
}
```

`pendingUserCreated` 是 v3 唯一新增字段，可选默认 `false`，向后兼容 v1 草稿。

### 3.3 EditorStore 新增 API

```swift
extension EditorStore {
    /// 显式新建一条空轨道。仅用于 UI 「+ 新建轨道」按钮。
    /// - Returns: 新轨道 ID
    @discardableResult
    public func addTrack(
        kind: EditorTrack.Kind,
        label: String = "",
        zPosition: Int? = nil,
        pendingUserCreated: Bool = false
    ) -> UUID

    /// 向指定轨道追加片段。调用方负责确认 segment.targetRange 与该轨道现有片段无重叠。
    public func addSegment(toTrack trackID: UUID, segment: EditorSegment)

    /// 自动选择或新建一条同类轨道并追加片段。复合 chooseOrCreateTrack + addSegment。
    /// 这是音频导入 / 文本新建 / TTS 入轨的统一入口。
    public func addSegmentAutoTrack(kind: EditorTrack.Kind, segment: EditorSegment) -> UUID

    /// 移除片段后若所在轨道为空且非主轨且非 pendingUserCreated，则回收该轨道。
    /// 与 removeSegment 合并为单步 undo。
    public func removeSegment(id: UUID)  // v1 已有，v3 内部行为扩展

    /// 主动回收空轨道（外部触发或定时器触发）
    public func removeTrackIfEmpty(id: UUID)
}
```

### 3.4 EditorTimeline 辅助方法（已存在或新增）

```swift
extension EditorTimeline {
    /// 已存在 (v1)
    public func tracks(ofKind kind: EditorTrack.Kind) -> [EditorTrack]
    public var mainTrack: EditorTrack? { get }

    /// v3 新增：返回该 kind 的轨道总数（含 pendingUserCreated 的空轨）
    public func trackCount(ofKind kind: EditorTrack.Kind) -> Int
}
```

---

## 四、UI 实现方案

### 4.1 TrackCanvasView 改造

[TrackCanvasView.swift](../../Sources/TimelineKit/Views/TrackCanvasView.swift) 现有 `sortedTracks()` 按 kind index + UUID 排序，已能正确渲染多条同类轨。v3 仅追加：

1. **轨道头 `+` 按钮**：在每类轨道行的最后一条右侧（或左侧标签区下方）显示一个 `+`，点击调用 `EditorStore.addTrack(kind:pendingUserCreated:true)`。
2. **空轨道空状态入口**：`segments.isEmpty && pendingUserCreated` 时显示类型化入口，而不是不可点击的「点击拖入素材」文案。V7.5 已正式修订该规则：空轨道表达目标轨道，点击必须携带 `trackID + kind`，按 [V7.5 素材入口路由规则](../v7/material-entry-routing-spec.md) 落到对应的 overlay / audio / text / subtitle 创建入口。
3. **轨道头 label**：v3 阶段使用规则 `"{kind显示名} \(index+1)"`，如「字幕 1」「字幕 2」「音频 1」「音频 2」。

### 4.2 二级面板「+ 新建轨道」入口

- `.audio` 二级面板：「提取音频 / 本地音乐 / 音效」三个 stub 之外，**不**额外加「新建空音频轨」按钮——剪映模型是「自动分轨」，不暴露空轨道概念。
- `.text` 二级面板：同上，不暴露空轨道概念。
- TrackCanvasView 的 `+` 按钮是唯一空轨道入口，且仅在用户已有 ≥1 条该类轨道时显示（首条由自动分轨创建）。

### 4.3 导入 / 导出适配

| 文件 | 改造 |
|---|---|
| [TimelineImporter.swift:221-226](../../Sources/TimelineKit/Conversion/TimelineImporter.swift) | 现按 `schema.audio?.subtitle?.items` 创建**单条**字幕轨。v3 暂保持现状，多字幕轨为本地编辑产物；后续服务端 schema 支持多轨后再扩展 |
| [TimelineExporter.swift:209-231](../../Sources/TimelineKit/Conversion/TimelineExporter.swift) | 现 `filter { $0.kind == .subtitle }` 已能收集所有字幕轨。v3 按时间顺序 flatMap 所有 `.subtitle` 轨片段输出 `SSubtitleItem`，**轨道分层信息在导出时丢失**（标注「跨端待对齐」）。本地草稿保留完整分层 |

---

## 五、边界情况

| 情况 | 处理 |
|---|---|
| 用户连续点 `+` 创建 10 条同类空轨 | 不限制创建，UI 提示「已创建 N 条 {kind}，建议合并」（≥8 时） |
| 删除最后一段后是 `pendingUserCreated` 空轨 | 不立即回收，等 30 秒计时器 |
| `EditorStore.addSegmentAutoTrack` 调用时该 kind 一条轨都没有 | 自动新建首条，复用默认 zPosition |
| `addSegment(toTrack:)` 指定轨道不存在 | 抛出 `EditorStore.Error.trackNotFound`，调用方负责降级 |
| 主轨道（isMainTrack）调用 `removeTrackIfEmpty` | 静默忽略，永不回收 |
| 导入旧草稿（v1 / v2）无 `pendingUserCreated` 字段 | 反序列化为默认 `false`，零迁移 |
| 多字幕轨导出到服务端 | flatMap 所有 `.subtitle` 段，按 `targetRange.start` 排序输出；标注「跨端待对齐」 |
| 同类轨道有 N 条均无重叠时 | 复用 zPosition 最小那一条（候选排序首条） |

---

## 六、验收标准

| # | 项目 | 标准 |
|---|---|---|
| MT-01 | 自动分轨复用 | 新增片段时间无重叠 → 复用现有轨，不新建 |
| MT-02 | 自动分轨新建 | 新增片段与同类轨全部重叠 → 自动新建一条 |
| MT-03 | 手动新建空轨 | TrackCanvasView `+` 按钮触发 `addTrack(pendingUserCreated:true)`，空轨可见 30 秒 |
| MT-04 | 主轨唯一性 | 多次调用 `addTrack(kind:.video)` 不破坏 `mainTrack` 唯一性 |
| MT-05 | 空轨回收 | 删除最后一段非主轨非 pendingUserCreated 轨道，单步 undo 同时回收轨道 |
| MT-06 | 显示顺序稳定 | 多条同类轨道按 `(zPosition desc, id asc)` 顺序渲染，刷新无抖动 |
| MT-07 | compositionVersion 边界 | 新增 `.subtitle` / `.text` 轨道不触发 rebuild（耗时 ≤ 50ms 完成 UI 更新）；新增 `.audio` 轨道触发 rebuild |
| MT-08 | 草稿往返 | 多轨草稿写入 → 重读 → 轨道数量 / 顺序 / pendingUserCreated 字段 100% 一致 |
| MT-09 | 服务端导入兼容 | v1 服务端 `audio.subtitle` 导入后仍创建单条 `.subtitle` 轨，无回归 |
| MT-10 | 导出兼容 | 多 `.subtitle` 轨按时间顺序 flatMap 导出，服务端可正常解析（按当前 schema） |

---

## 七、与 v1 / v2 接口约束

- **不修改** `EditorTrack` / `EditorTimeline` 现有字段语义
- **不修改** `mutateSubtitle` 不重建规则（v1 S-04）
- **不修改** v2 转场 / 调色 / 导出三件 spec 的任何接口
- v3 新增 `pendingUserCreated` 字段为可选默认 `false`，旧草稿零迁移
