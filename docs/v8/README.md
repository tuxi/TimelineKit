# TimelineKit v8 文档基线

## 版本定位

V8 是在 V7（转场系统 + Animation Runtime）之后的**产品架构升级大版本**：把 TimelineKit 从单一 iOS 编辑器包升级为「本地可编辑 timeline + Apple 平台 UI + Agent/MCP 工具入口」三位一体的剪辑内核。

V8 的核心判断：

1. iOS UI 已经基本可用，但 TimelineKit 现在仍是单 target，Core / Render / UI 边界不清，导致 macOS build 与未来 macOS UI 都受阻。
2. TimelineKit 最有价值的资产不是某个 UI 面板，而是可编辑的 `EditorTimeline`、可往返的导入导出、同源预览/导出渲染链路。
3. Claude Code / Codex / 端侧 code-agent 需要的是稳定、可编排、可回放的本地剪辑工具，而不是直接操作 UI。
4. 现有开源 FFmpeg MCP 多数是命令包装，缺少「结构化 timeline 草稿 + UI 可继续编辑 + agent 可继续修改」这一层。

因此 V8 不做新剪辑特效，而是重构边界：

```text
TimelineKitCore
  -> TimelineKitRender
      -> TimelineKitUIiOS
      -> TimelineKitUIMac
      -> timelinekit CLI
      -> timelinekit-mcp
```

## 文档列表

| 文件 | 内容 | 优先级 | 状态 |
|---|---|---|---|
| [V8-initiation.md](V8-initiation.md) | 立项探索：Core/UI 拆包、CLI/MCP/Agent 入口、竞品调研、里程碑、风险 | — | 探索定稿 |

## 与 v1-v7 的关系

V8 是架构层改造，不改变既有剪辑语义：

- **不改** `EditorTimeline` 的核心时间模型：所有时间仍为绝对秒。
- **不改** MaterialsPool / Track / Segment / Transition 的基本关系。
- **不重写** V6/V7 渲染与动画体系，只把它们从 UI target 中分离出来。
- **不要求** macOS UI 与 iOS UI 同期完成；V8 首要目标是让 Core/Render 可以被 macOS app、CLI 和 MCP 复用。

## 开发节奏

```text
M1：拆包边界设计与 Package.swift target graph
  -> M2：TimelineKitCore 可独立 build/test
  -> M3：TimelineKitRender 独立导出能力
  -> M4：iOS UI 迁移到 TimelineKitUIiOS，保持 demo 可运行
  -> M5：timelinekit CLI MVP
  -> M6：timelinekit-mcp MVP
  -> M7：macOS UI 壳与跨端草稿验证
```

