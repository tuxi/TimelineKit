# TimelineKit v3 文档基线

## 版本定位

v3 是 v1 剪辑底座之上的**剪辑能力补齐层**，与 v2 渲染特性层（转场 / 调色 / 导出）正交并行。v3 聚焦四件事：

- **多轨架构**（Multi-Track）—— 视频主轨保持唯一，字幕 / 文本 / 音频 / 叠加层支持同类多轨
- **手动文本入口**（Text Entry）—— 与自动字幕严格区分的独立创建链路
- **音频功能**（Audio）—— 提取音频 / 本地音乐 / 音效，以及波形 / 磁吸 / 音量基础编辑
- **本地系统 TTS**（Text-to-Speech）—— 基于 `AVSpeechSynthesizer` 的逐条文本朗读，单向 `ttsSource` 关联模型

v1 基线（`docs/v1/`）与 v2 排期（`docs/v2/`）均不受 v3 影响：v2 与 v3 改写的代码文件无交集（见 [V3-initiation.md](V3-initiation.md) 「与 v2 并行边界」）。

## 文档列表

| 文件 | 内容 | 状态 |
|------|------|------|
| [V3-initiation.md](V3-initiation.md) | 立项书：背景 / 范围围栏 / 里程碑 / 风险 / KPI | 规范定稿，待实现 |
| [multi-track-architecture-spec.md](multi-track-architecture-spec.md) | 多轨架构规范（竞品 + 规则 + 数据模型 + UI） | 规范定稿，待实现 |
| [audio-feature-spec.md](audio-feature-spec.md) | 音频功能规范（提取 / 导入 / 编辑 / 波形 / 磁吸） | 规范定稿，待实现 |
| [text-entry-spec.md](text-entry-spec.md) | 手动文本入口与编辑面板规范 | 规范定稿，待实现 |
| [tts-spec.md](tts-spec.md) | 本地系统 TTS 规范（`ttsSource` 关联模型） | 规范定稿，待实现 |

## 开发节奏

```
竞品分析 → 规则定义 → 规范文档 → 按文档开发 → 验收
```

依赖顺序：**多轨架构 → 文本入口 → 音频功能 → TTS**

- 多轨架构是其他三件的前置（音频段 / 文本段 / TTS 配音段都需要落到「新建一条同类轨」的能力）
- 文本入口先于 TTS（朗读按钮挂在 `TextEditPanel` 上）
- 音频功能与 TTS 在轨道层是同一种 segment kind，两者共用「磁吸 / 波形 / 音量」基础编辑

## 与 v1 / v2 的关系

- **v1**：所有数据模型（`EditorTrack` / `EditorSegment` / `SegmentContent`）保持向后兼容；v3 仅在 `AudioContent` 上增加可选字段 `ttsSource: TTSSource?`。旧草稿可正常加载。
- **v2**：转场 / 调色 / 导出三件 spec 不动；v3 的 `EditorStore` 新增 API 与 v2 互不冲突（见 [V3-initiation.md](V3-initiation.md) 「与 v2 并行边界」清单）。
