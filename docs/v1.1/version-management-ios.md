# V1.1 iOS 版本管理探索

> 状态：探索稿，未实现
>
> 范围：Dreamlog iOS 本地项目内的手动版本管理
>
> 结论：V1 首发不做；V1.1 作为第一个增强功能，先做手动版本，不做自动历史和版本比较。

## 1. 结论与范围

版本管理适合 Dreamlog，而且完全可以在本地闭环内完成，不需要服务端。但它不是 V1 上线的必要条件。建议：

- **V1**：先保证项目、剪辑、模板、导出稳定上线，不做版本管理。
- **V1.1**：做手动版本：添加、切换、重命名、删除；存储放在 `.tlkbundle/Versions/`。
- **V1.1.x / 后续**：Agent apply 前自动创建一个“应用前”版本；仍不做自动历史、分支/合并、跨设备同步。
- 如果首发前时间允许，只做“手动添加/切换/删除”的窄版本，不做缩略图、比较和自动清理。

明确不做：

- 版本分支/合并；
- 跨设备版本同步；
- 版本级 Agent 计划和版本 diff UI；
- 版本级导出视频副本；
- 自动历史保留策略（V1.1 只做手动快照）。

## 2. 职责边界

| 端 | 负责 | 不负责 |
|---|---|---|
| TimelineKit | `EditorTimeline` 的 Codable 快照；`timelineVersion` revision；切换时用 `applyExternalTimeline` 整条应用；undo/history 边界 | 项目、`.tlkbundle`、版本名称、版本列表、业务元数据 |
| Dreamlog App | 版本模型、manifest、`.tlkbundle/Versions/` 存储、版本列表 UI、添加/切换/重命名/删除、活动版本与 `.tlkproj` 的关系 | 重新定义时间线命令；把版本放到服务端 |
| DreamAI | 不参与 | 版本列表、版本名称、本地版本事务 |

版本是本地项目状态，不进入 DreamAI 协议。Agent 只关心当前时间线的 revision，不关心用户有几个版本。

## 3. 推荐交互

参考截图中的交互：

- 编辑器菜单出现“管理版本”；
- 版本页有“添加版本”；
- 版本行显示“原版”“版本”；
- 行操作有“编辑版本名称”“删除这个版本”；
- 当前版本有明确的选中/勾选状态。

### 3.1 入口

在编辑器右上角更多菜单中加入：

```text
模板设置
管理版本
为工具重新排序
```

点击“管理版本”打开版本 sheet，不新开全屏页面，不要求 Dreamlog 再包一层 NavigationStack。

### 3.2 版本列表

建议使用 iOS 原生 `.sheet`：

- 标题：`版本`
- 第一行：`+ 添加版本`
- 下面按创建时间或用户排序列出：
  - 缩略图（可选；没有则占位）
  - 名称
  - 创建时间/相对时间
  - 当前版本勾选标记
- 行右侧更多菜单：
  - `编辑版本名称`
  - `删除这个版本`
- 点击非当前版本行：切换版本。
- 点击当前版本行：无操作或轻微反馈。

建议 sheet detents：`[.medium, .large]`，不覆盖整个编辑器。

### 3.3 添加版本

- 捕获当前活动时间线，创建新快照。
- 默认名称：`原版`（第一个版本）或 `版本 N`。
- 新版本默认成为当前版本。
- 版本快照写入 `Versions/<versionID>.json`。
- 不复制媒体；只复制 `EditorTimeline` JSON。
- 如果当前时间线与当前版本快照完全一致，仍允许创建（用户可能想复制一个版本）。
- 添加成功后：
  - 新版本行出现在列表；
  - `.tlkproj` 保持当前时间线；
  - `manifest.activeVersionID` 指向新版本；
  - 可显示 toast：`已添加版本`.

### 3.4 切换版本

点击目标版本行：

1. 保存当前活动版本：
   - 把当前 `EditorStore.timeline` 写回活动版本快照；
   - 保存当前 `.tlkproj`。
2. 读取目标版本快照并校验：
   - schema 版本；
   - `projectID` 匹配；
   - `EditorTimeline` 可解码；
   - 快照 `timelineVersion` 与内容一致（用于发现损坏）。
3. 用 `editorStore.document.applyExternalTimeline(target.timeline, label: "切换版本")` 应用整条时间线。
4. 保存目标 `.tlkproj`。
5. 更新 `manifest.activeVersionID`。
6. 推荐清空 undo/redo 历史（见 §6）。
7. 显示 toast：`已切换到 <版本名>`。

失败时不要改变 `activeVersionID`，并保留原活动版本。

### 3.5 重命名

- 弹出 alert 或行内编辑。
- 名称 trim 后不能为空。
- 建议最大 40 个字符。
- 建议同一项目内唯一；重复时提示或自动加后缀。
- 只更新 `manifest.json`，不改快照和 `.tlkproj`。

### 3.6 删除

- 删除前确认，明确“不会删除媒体，但版本不可恢复”。
- 不允许删除当前活动版本；用户必须先切换到其他版本。
- 不允许删除最后一个版本。
- 建议保护“原版”不被删除（可重命名）；如果产品希望允许删除，需明确二次确认。
- 删除：
  - `Versions/<versionID>.json`
  - `Versions/Thumbnails/<versionID>.jpg`（如有）
  - manifest 中的 entry
- 不删除 `Media/`、`Projects/<projectID>.tlkproj` 或 `Agent/Executions/`。

## 4. 数据模型

### 4.1 版本 manifest

`Versions/manifest.json`：

```json
{
  "schemaVersion": "timeline_versions.v1",
  "projectID": "PROJECT-UUID",
  "activeVersionID": "VERSION-UUID",
  "versions": [
    {
      "id": "VERSION-UUID",
      "name": "原版",
      "createdAt": "2026-10-20T12:00:00Z",
      "sourceVersionID": null,
      "timelineVersion": "fnv-local-revision",
      "thumbnail": "Thumbnails/VERSION-UUID.jpg"
    }
  ]
}
```

字段：

- `projectID`：`LibraryProject.id`，不是 `EditorTimeline.id`。
- `activeVersionID`：必须指向 `versions` 中恰好一个 entry。
- `timelineVersion`：快照生成时的 `AgentEditPlan.timelineVersion(for:)`，用于快速一致性检查。
- `sourceVersionID`：可选，表示从哪个版本创建；V1.1 不做分支语义。
- `thumbnail`：可选，相对 `Versions/` 的路径；没有则为 nil。

### 4.2 版本快照

`Versions/<versionID>.json`：

```json
{
  "schemaVersion": "timeline_version.v1",
  "versionID": "VERSION-UUID",
  "projectID": "PROJECT-UUID",
  "createdAt": "2026-10-20T12:00:00Z",
  "timelineVersion": "fnv-local-revision",
  "timeline": {
    "id": "TIMELINE-UUID",
    "canvas": {},
    "tracks": [],
    "materials": [],
    "transitions": [],
    "metadata": {}
  }
}
```

原则：

- `timeline.id` 在整个项目生命周期内保持不变；切换版本不改变 `EditorTimeline.id`。
- `versionID` 与 `projectID`、`timeline.id` 都是独立身份，不要求相等。
- 快照只存 JSON，不复制媒体。
- 非活动版本快照不可变。
- 活动版本快照是“离开时写回的检查点”；活动期间以 `.tlkproj` 为准。

## 5. 存储布局

```text
<project>.tlkbundle/
├── CurrentVersion.json
├── Media/                         # 所有版本共享
├── Projects/
│   └── <projectID>.tlkproj        # 当前活动版本
├── Versions/
│   ├── manifest.json
│   ├── <versionID>.json
│   └── Thumbnails/
│       └── <versionID>.jpg        # 可选
├── Agent/
│   └── Executions/
└── DreamlogProject.json
```

首次进入版本管理时，如果 `Versions/manifest.json` 不存在：

1. 从当前 `.tlkproj` 创建 `原版` 快照；
2. 设置 `activeVersionID` 为该快照；
3. 不复制媒体，不改变 `.tlkproj` 内容。

这样版本列表从一开始就有可回退的基线，不需要假设“原版”是一个隐式状态。

关键约束：

1. `.tlkproj` 始终是当前活动时间线，不建立“每个版本一个 `.tlkproj`”。
2. `Versions/` 是历史快照，不与 `Projects/` 混淆。
3. 媒体只存在 `Media/`，版本切换不复制媒体。
4. 删除版本只删 `Versions/` 下的 JSON 和缩略图，不删媒体。
5. `Agent/Executions/` 保持在 bundle 内，不随版本复制。

## 6. Undo 与切换语义

这是 V1.1 最需要拍板的交互细节。

- Agent apply：继续使用 `applyExternalTimeline`，一个批次一个 undo 单元。
- 版本切换：建议把它视为“切换工作上下文”，不是普通编辑。
  - 推荐：应用目标时间线后清空 undo/redo，避免 undo 回到上一个版本但 manifest 仍指向新版本。
  - 不推荐：把不同版本的 undo 历史串起来。
- 如果产品坚持“切换版本可 undo”，则必须让 Dreamlog 监听 undo 并把 `activeVersionID` 恢复为原版本；这需要版本感知的 undo 回调，建议延后到 V1.2。

当前 TimelineKit 只有 `applyExternalTimeline` 会把整条时间线作为一个 undo 单元；V1.1 如果采用“切换后清空历史”，需要补一个最小 API（见 §9），但本轮不实现。

## 7. Agent、revision 与版本

版本切换会改变当前时间线 revision：

- 切换后 `AgentEditPlan.timelineVersion(for:)` 变化。
- 旧 Agent plan 的 `baseTimelineVersion` 立即失效，不能应用到新版本。
- Dreamlog 应在切换时：
  - 取消/过期未应用的 Agent 计划；
  - 若 Agent apply 正在进行，禁止切换版本；
  - 记录当前 `activeVersionID`，避免 execution 结果落错版本。
- `execution_id` 仍是项目级幂等键；同一 execution 在版本切换后重试应返回冲突或需要协调，不能把旧版本结果写进新版本。
- Agent journal 建议记录 `activeVersionID`，与 `baseTimelineVersion`、result revision 一起用于恢复判断。
- 可选增强：Agent apply 前自动创建“应用前”版本，失败或用户不满意时可切回。这是 V1.1.x 的低成本增强，不纳入手动版本 MVP。

## 8. 崩溃与恢复一致性

版本切换涉及三个写点：

1. 当前活动版本快照；
2. `.tlkproj`；
3. `manifest.activeVersionID`。

建议顺序：

```text
保存当前版本快照
→ 保存当前 .tlkproj
→ 写目标 .tlkproj
→ 写 manifest.activeVersionID
```

启动时对账：

- 读取 manifest 和 `.tlkproj`。
- 如果 `.tlkproj` 的 `timelineVersion` 等于 `activeVersionID` 对应快照：
  - manifest 一致，正常打开。
- 如果 `.tlkproj` 等于另一个版本快照：
  - 说明切换中途崩溃，修 manifest 指针到该版本。
- 如果 `.tlkproj` 不匹配任何版本快照：
  - 不要自动覆盖；
  - 标记 `needsReconciliation`，提示用户保存为当前版本或恢复某个版本。
- 如果 manifest 损坏或 `activeVersionID` 不存在：
  - 显式报错，不自动重建版本列表；
  - 保留 `.tlkproj`，允许用户从快照中手动恢复。

V1.1 可以不做完整 switching marker；但必须保证“不静默选错版本、不覆盖用户时间线”。

## 9. TimelineKit 需要的 API 边界

已有能力：

- `EditorTimeline: Codable`：快照序列化/反序列化。
- `AgentEditPlan.timelineVersion(for:)`：revision。
- `TimelineDocument.applyExternalTimeline(_:label:)` / `EditorStore.applyExternalTimeline`：整条时间线应用。
- `EditorPersistenceMode.library`：`.tlkproj` 唯一时间线源。

V1.1 文档阶段建议的最小 API 缺口（本轮不实现）：

```swift
public enum TimelineHistoryPolicy {
    case singleUndo          // Agent apply
    case clearUndoRedo       // version switch
}

public func applyExternalTimeline(
    _ timeline: EditorTimeline,
    label: String,
    history: TimelineHistoryPolicy
)
```

如果产品决定“切换版本可 undo”，则不加 `clearUndoRedo`，而是需要版本感知的 undo 回调；这属于 V1.2。

TimelineKit 不新增版本模型、manifest 类型、缩略图生成或版本 UI。

## 10. 验收标准

### 功能

- [ ] 添加版本：生成快照和 manifest，不复制媒体。
- [ ] 切换版本：保存当前状态，应用目标快照，`.tlkproj` 更新，重开恢复目标版本。
- [ ] 重命名：manifest 更新，快照和 `.tlkproj` 不变。
- [ ] 删除：只删 JSON/缩略图，媒体仍存在；活动版本和最后一个版本不能删。
- [ ] 原版保护策略明确。
- [ ] 版本切换后 Agent plan 失效，旧 `execution_id` 不能写入新版本。
- [ ] 版本切换后媒体仍可播放。
- [ ] 版本列表在 iPhone sheet 中可用，不破坏编辑器布局。

### 一致性

- [ ] 切换中断后，manifest 与 `.tlkproj` 不一致能被检测。
- [ ] 损坏 manifest/快照不会被静默当成空版本列表。
- [ ] `.tlkproj` 是当前活动时间线的唯一实时源。
- [ ] `Media/` 不因版本数量增长而复制。

### Undo

- [ ] Agent apply 是一个 undo 单元。
- [ ] 版本切换的 undo 策略按最终产品决定执行；推荐清空 undo/redo。

## 11. 待确认问题

1. 版本切换是否清空 undo/redo？推荐清空；若保留 undo，必须同步 `activeVersionID`。
2. “原版”是否允许删除？推荐保护，只允许重命名。
3. 添加版本后是否立即切换到新版本？推荐是。
4. 缩略图取当前播放头还是固定首帧？V1.1 建议固定首帧或当前播放头二选一，缺失时占位。
5. 版本名称是否要求唯一？建议唯一，重复时提示。
6. 版本数量是否限制？V1.1 不自动清理，超过阈值只提示。
7. Agent apply 前自动建“应用前”版本放在 V1.1 还是 V1.2？建议 V1.1.x。
8. 切换版本时是否要求用户确认？如果当前版本已自动保存，可不确认；如果保存失败，必须阻止切换。

## 12. 工作量

手动版本（推荐 V1.1）：

- 版本模型、manifest、快照存储；
- 添加、切换、重命名、删除；
- `.tlkproj` 保存与恢复对账；
- 基本测试和边界处理；
- UI：版本 sheet + 菜单。

预计 3–5 个工作日。

自动历史版本（V1.2+）：

- 保存/导出/Agent apply 自动快照；
- 保留策略、去重、清理；
- 缩略图、预览、比较。

预计 1–2 周，复杂度主要在保留策略和用户预期，不在时间线存储。
