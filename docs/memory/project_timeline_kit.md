---
name: TimelineKit 落地状态
description: TimelineKit 独立剪辑包的当前实现状态和接入情况
type: project
---

TimelineKit 已完成基础架构并接入 FeatureVideoGen，具备可演示的剪辑器骨架。

**Why:** 将服务端 VideoTimeline 格式和剪辑器内部模型彻底解耦，避免用渲染规格直接做编辑模型。

**How to apply:** 后续所有剪辑编辑功能都在 TimelineKit 内部迭代，不影响 FeatureVideoGen 现有业务。

## 已完成

### 数据模型层
- Models/: TimeRange, EditorTimeline, EditorTrack, EditorSegment, EditorAsset, EditorTransition, KeyframeSet, SegmentContent, SegmentTransform, NormalizedPoint, EditorCanvas

### 转换层
- ServerTimelineSchema + TimelineImporter（start_offset 展开为绝对时间）
- TimelineExporter（折叠回相对时间）

### 状态管理
- EditorStore（@Observable @MainActor，undo/redo 50步）
- mutateTextContent / mutateTextStyle / previewFontSize 等 API

### AVPlayer 预览
- EditorStore 持有 AVPlayer，play/pause/seek/togglePlayback
- 定时观察者每 1/30s 同步 playheadTime
- AVPlayerRepresentable（UIViewRepresentable + AVPlayerLayer）
- 播放本地缓存的 video.mp4（服务端渲染结果，非客户端合成）

### 轨道编辑 UI（UIKit）
- ClipEditorViewController：scrollView + canvas + 左侧标签栏
- TrackCanvasView：帧布局，设置 contentSize 驱动横向滚动
- TrackLayout：time ↔ pixel 转换，支持 zoom 缩放
- 左侧 TrackLabelsView：52pt 固定列，每行显示轨道类型图标+中文标签
- RulerView：自适应刻度间隔（0.1~60s）
- SegmentBlockView：两端 trim 手势（拖动预览 + 松手提交 undo）
- 捏合缩放：20~600 px/s，锚点时间不跳，标尺刻度自适应
- V7.5：空轨道不再是不可点击的「点击拖入素材」提示；按 [material-entry-routing-spec](../v7/material-entry-routing-spec.md) 定义为类型化目标轨道入口：
  - overlay → 添加画中画，PhotosPicker 导入后落到目标 overlay track 的播放头位置
  - audio → 打开音频面板，提取/本地音乐完成后优先落到目标 audio track
  - text/subtitle → 直接在目标轨道创建片段
  - 主轨右侧 + 仍只表示添加主轨素材，插入主轨末尾

### 文字编辑面板（SwiftUI）
- TextEditPanel：剪映风格，位于 VStack 底部
- 顶部文字输入栏（单行 TextField + ✓ 确认）
- 5 标签：字体 / 样式 / 花字 / 文字模板 / 动画
- 字体 Tab：分类 chip + 2 列字体卡片网格（当前仅系统字体可选）
- 样式 Tab：预设样式横向滚动 + 子标签（文本/描边/背景/阴影）
  - 文本子标签：颜色色板 + 字号 Slider（实时预览，松手写 undo）+ 字重 Pills
- 键盘弹起时 iOS 自动避让，输入框和标签栏保持在键盘上方

### 接入 FeatureVideoGen
- DreamStudioView completed 状态右上角剪刀按钮，点击打开剪辑器 sheet
- openEditor() 读取 localVideoURL 传给 EditorStore 初始化 AVPlayer
- TimelineCache 新增 loadLatestTimelineJSONData / saveEditorTimelineJSON

## 待实现

| 优先级 | 功能 |
|---|---|
| 🟡 中 | 轨道片段可拖拽移动（长按+拖） |
| 🟡 中 | TrackLabelsView 随轨道内容更新（目前只有图标占位） |
| 🟢 低 | 字体 Tab 接入真实字体列表 |
| 🟢 低 | 样式 Tab 描边/背景/阴影子标签 |
| 🟢 低 | 文字层在预览区可拖拽移位 |
| 🔴 后期 | 客户端 AVComposition 合成（从 EditorTimeline 重新渲染，目前播放服务端 video.mp4） |
