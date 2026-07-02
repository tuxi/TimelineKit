# TimelineKit 文档索引

## 版本目录

| 版本 | 状态 | 适用阶段 | 说明 |
|---|---|---|---|
| [v1/](v1/) | ✅ 已锁基线 | P0 / P1 | 6 份架构+交互规范，渲染管线与交互底座 |
| [v2/](v2/) | 📝 规范在写 | 渲染特性层 | 转场 / 调色 / 导出三件 spec（V4 P2 沿用执行）|
| [v3/](v3/) | ✅ 已上线 | 剪辑能力补齐层 | 多轨架构 / 文本入口 / 音频功能 / 本地 TTS |
| [v4/](v4/) | 📝 规范定稿 | 体验升级层 | 样式保真 / 批量样式 / 多轨滚动 / 文本排版 / 音频与轨道控制 |
| [v5/](v5/) | 📝 规范定稿 | 同源预览 + 导出参数 | 同源全屏真实预览（P0）/ 导出参数配置面板（P1）/ AVAssetWriter 改造（P1，M3 SDR / M4 HDR） |
| [v6/](v6/) | 📝 规范定稿 | 底层渲染架构重塑 | 废除图片预转 MP4，原生图片图层实时渲染 + 关键帧动画底座；8 份文档（立项 + 竞品 + 5 份核心 spec） |
| [v7/](v7/) | 📝 规范定稿 | 转场系统 + Animation Runtime | 转场注册表 / TransitionComposer / 动画 Runtime / 素材入口路由 |
| [v8/](v8/) | 🔎 探索定稿 | Core/UI 拆包 + Agent/MCP 入口 | 本地可编辑 timeline + iOS/macOS UI + CLI/MCP/Agent 双入口 |

> **规则**：基线大版本迭代（架构重构 / 能力补齐 / 体验升级）才新建版本目录；
> 小修订直接更新对应版本内文档的版本号。
> v4 是 v1（渲染底座）+ v3（剪辑补齐）之上的体验升级层，不重写 v1/v2/v3；P2 沿用 v2 三件 spec。
> v5 是 v4 之后的"两件刚需补齐"层（预览/成片同源 + 导出参数化），不引入新剪辑维度；v2 `export-pipeline-spec.md` 内追加「附录 A：v5 修订条目」承载档位与编码格式权威表。
> v6 是底层渲染架构重塑大版本：废除 StaticImageRenderer 预合成 MP4，图片以 CIImage 原生图层挂载时间轴，实时关键帧驱动动画；相册图与 AI 动效图统一渲染链路。P2 上层业务复用 v5 三份 spec，不重写。
> v8 是产品架构升级探索：把 TimelineKit 拆成 Core / Render / UI / CLI / MCP 多入口体系，让 iOS/macOS App 与 Claude Code / Codex / 端侧 code-agent 共享同一套本地可编辑 timeline 内核。

---

## v1 文档清单

### 渲染架构（P0 已落地）

| 文档 | 内容摘要 |
|---|---|
| [rendering-competitive-analysis.md](v1/rendering-competitive-analysis.md) | 剪映/FCP/LumaFusion 渲染引擎调研对比 |
| [avfoundation-rendering-architecture.md](v1/avfoundation-rendering-architecture.md) | TimelineKit + AVFoundation 五组件架构设计 |
| [rendering-performance-spec.md](v1/rendering-performance-spec.md) | 内存预算、分辨率降级、防抖节流性能规范 |

### 交互规范（P1 开发依据）

| 文档 | 内容摘要 |
|---|---|
| [subtitle-rendering-spec.md](v1/subtitle-rendering-spec.md) | 字幕图层层级、预览/导出双轨、样式映射、7 条验收标准 |
| [audio-track-interaction-spec.md](v1/audio-track-interaction-spec.md) | 四类音频轨道、磁吸规则、手柄约束、8 条验收标准 |
| [timeline-scrub-playback-spec.md](v1/timeline-scrub-playback-spec.md) | 播放头状态机、Scrub 节流、吸附触觉、10 条验收标准 |
