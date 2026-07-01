# TimelineKit v2 文档基线

## 版本定位

v2 是 v1 剪辑底座之上的**增值功能层**，专注于：

- **转场**（Transition）—— 片段间过渡效果
- **滤镜 / 调色 / LUT**（Filter & Color Grading）
- **高清导出 / 后台导出**（Export Pipeline）

v1 规范、架构、遗留 Issue 锁定在 `docs/v1/`，与 v2 完全隔离。

## 文档列表

| 文件 | 内容 | 状态 |
|------|------|------|
| [transition-spec.md](transition-spec.md) | 转场规范（竞品分析 + 规则 + 数据模型 + 渲染） | 待撰写 |
| [filter-color-spec.md](filter-color-spec.md) | 滤镜/调色/LUT 规范 | 待撰写 |
| [export-pipeline-spec.md](export-pipeline-spec.md) | 导出流水线规范（分辨率、码率、后台任务） | 待撰写 |

## 开发节奏

```
竞品分析 → 规则定义 → 规范文档 → 按文档开发 → 验收
```

依赖顺序：**转场 → 滤镜调色 → 导出**（导出依赖前两者的渲染结果）。
