# TimelineKit V7.5 素材入口路由规则

> 版本：v7.5
> 状态：规则定稿，已落地
> 对标：剪映 / CapCut / iMovie / Premiere / LumaFusion 的主轨、叠加轨、音频轨素材入口心智

---

## 一、问题背景

v3 多轨文档把用户显式创建的空轨道定义为显示「点击拖入素材」提示，但实现只创建了一个 `UILabel`。这在产品语义上是缺陷：空轨道看起来像入口，实际没有任何添加能力；同时它也暴露出更深层的需求缺口——“任意空轨道应该如何添加素材”没有被正式定义。

V7.5 将其从 bug 修复升级为交互规则：**空轨道不是通用素材库入口，而是某一类素材的目标轨道**。

---

## 二、竞品结论

主流剪辑产品普遍把「添加素材」和「目标轨道」拆开：

- 主轨素材通过主入口添加，形成时间线 backbone。
- 叠加素材通过 overlay / 画中画入口添加，落到叠加层轨道。
- 文字、字幕、音频都有各自类型入口。
- 空轨道或轨道选择只表达目标位置，不承担“万能素材入口”语义。

因此 TimelineKit 不采用“点任意空轨道统一打开相册并猜测素材类型”的设计。

---

## 三、定稿规则

### 3.1 主轨右侧加号

主轨右侧固定 `+` 的语义保持不变：

- 打开照片/视频选择器。
- 添加视频或图片到主轨。
- 插入位置为主轨末尾。
- 不携带目标轨道上下文。

这是“添加主轨素材”，不是“添加到当前选中轨道”。

### 3.2 左侧轨道加号

轨道头的 `+` 只负责显式新建同类型空轨道：

- 调用 `EditorStore.addTrack(kind:pendingUserCreated:true)`。
- 不打开相册。
- 不自动创建素材。
- 新建空轨 30 秒内仍为空则按 v3 规则回收。

### 3.3 空轨道空状态

`segments.isEmpty && pendingUserCreated == true` 的轨道显示类型化入口：

| Track kind | 空状态文案 | 点击行为 |
|---|---|---|
| `.overlay` | 添加画中画 | 打开照片/视频选择器，素材落到这条 overlay 轨道的当前播放头位置 |
| `.audio` | 添加音频 | 打开音频面板；提取音频/本地音乐完成后优先落到这条 audio 轨道 |
| `.text` | 添加文字 | 直接在这条 text 轨道创建文本片段 |
| `.subtitle` | 添加字幕 | 直接在这条 subtitle 轨道创建字幕片段 |

空轨道入口必须携带 `trackID + kind`，不能只携带 kind。否则 auto-track 复用规则可能把片段落到另一条无重叠轨道，违反“点哪条空轨就添加到哪条轨”的交互承诺。

### 3.4 不支持的语义

- 空 `.video` 轨道不作为入口：主轨唯一，不能通过空轨道复制主轨。
- 空 `.adjustment` 轨道 v7.5 不提供素材添加入口，后续若做全局调节层，应单独定义 adjustment segment 的创建规则。
- 不把空轨道点击定义为“打开通用素材库”：通用素材库会混淆主轨/叠加/音频/文字的类型边界。

---

## 四、实现路由

### 4.1 UI 事件链

```
TrackRowView empty affordance
  -> TrackCanvasView.onEmptyTrackAdd(trackID, kind)
  -> ClipEditorViewController.onEmptyTrackAdd(trackID, kind)
  -> TrackEditorRepresentable
  -> ClipEditorView.handleEmptyTrackAdd(trackID, kind)
```

UIKit 层只负责轨道命中和轻量按钮展示；SwiftUI 层负责打开 PhotosPicker、音频面板和文字/字幕创建入口。

### 4.2 Store API

新增/扩展路由型 API：

```swift
public func addVisualSegment(
    localURL: URL,
    nativeDuration: Double?,
    targetTrackID: UUID? = nil
) -> UUID?
```

规则：

- `targetTrackID == nil`：等价于原主轨添加，插入主轨末尾。
- `targetTrackID != nil`：只接受 `.overlay` 非主轨，插入当前播放头位置。

扩展既有 API：

```swift
public func addAudioSegment(..., targetTrackID: UUID? = nil, ...)
public func createNewTextSegment(..., targetTrackID: UUID? = nil)
public func createNewSubtitleSegment(..., targetTrackID: UUID? = nil)
```

规则：

- 有合法目标轨道时调用 `addSegment(toTrack:)` 定向插入。
- 无目标轨道或目标类型不匹配时回退既有 `addSegmentAutoTrack`。
- 这样底部工具栏入口保持原来的自动分轨行为，空轨道入口获得定向落轨行为。

---

## 五、后续约束

后续新增素材入口必须先回答两个问题：

1. 这是“主轨添加”、还是“某类轨道的目标添加”？
2. 是否携带明确 `trackID`？如果没有，只能走 auto-track 或主轨追加，不能假装落到某条空轨道。

除非有新的产品需求正式打破本规则，否则 TimelineKit 未来版本都应遵守这一入口定义。
