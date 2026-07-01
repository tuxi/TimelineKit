# TimelineKit — 架构设计

## 设计目标

TimelineKit 是一个独立的 Swift Package，提供视频剪辑编辑器的内核能力。它与业务层（FeatureVideoGen）和服务端格式（VideoTimeline JSON）完全解耦。

**三个核心原则：**
1. **素材与放置分离** — 资产存在 MaterialsPool，轨道只持有引用 ID
2. **统一绝对时间** — 所有时间都是从 timeline 起点开始的秒数，没有相对 offset
3. **关键帧优先** — 所有动画属性均可通过 KeyframeSet 驱动，预设名字是语法糖

---

## 层次结构

```
┌─────────────────────────────────────────────────────────────────┐
│  FeatureVideoGen（业务层）                                        │
│  DreamStudioView → 预览结果 → 跳转 ClipEditorView              │
└──────────────────────────────┬──────────────────────────────────┘
                               │ 传入 JSON Data / ServerTimelineSchema
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  TimelineKit（剪辑内核）                                          │
│                                                                  │
│  TimelineImporter ──→ EditorTimeline ←── TimelineExporter       │
│                            │                                     │
│                       EditorStore                                │
│                      (undo / mutate)                             │
│                            │                                     │
│   ClipEditorView (SwiftUI) │                                    │
│   ├── EditorPreviewView    │  播放预览（占位，后期接 AVPlayer）  │
│   ├── EditorControlBar     │  播放控制                          │
│   └── ClipEditorViewController (UIKit)                          │
│       ├── TrackCanvasView  │  轨道渲染 + 手势                   │
│       └── RulerView        │  时间标尺                          │
└─────────────────────────────────────────────────────────────────┘
                               │ VideoTimeline JSON (导出)
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  本地缓存（TimelineCache）                                        │
│  不上传服务端，只存本地，进入编辑器时加载                           │
└─────────────────────────────────────────────────────────────────┘
```

---

## 为什么 UIKit 而不是 SwiftUI 做轨道区域

| 问题 | SwiftUI | UIKit |
|---|---|---|
| ScrollView + 拖拽手势 | 水平 DragGesture 和 ScrollView 冲突 | UIScrollView.panGestureRecognizer 可受控禁用 |
| Trim handle 拖拽 | 方向判断困难 | UIPanGestureRecognizer.delegate 精确控制 |
| 60fps 帧率 | SwiftUI 动画不保证 | CALayer/CADisplayLink 原生支持 |
| 大量 segment 性能 | ForEach 重绘成本高 | 自定义 draw() 或 CALayer 复用 |

Preview 区和控制栏仍用 SwiftUI，UIKit 仅限于轨道画布。

---

## 扩展路径

| 未来功能 | 所需字段 | 已预留 |
|---|---|---|
| 变速 | EditorSegment.speed | ✓ |
| 画中画 / 多层 | EditorTrack.kind = .overlay | ✓ |
| 滤镜 / 调色 | EditorTrack.kind = .adjustment | ✓ |
| 关键帧动画 | KeyframeSet | ✓ |
| 源素材入出点 trim | EditorSegment.sourceRange | ✓ |
| 多音轨 | 多个 .audio track | ✓ |
| Blend mode | EditorSegment.blendMode | ✓ |
| macOS 支持 | 模型层全平台；Views 用 `#if canImport(UIKit)` 隔离 | ✓ |

---

## 目录结构

```
Sources/TimelineKit/
├── Models/
│   ├── TimeRange.swift          # 时间区间（唯一时间坐标系）
│   ├── EditorCanvas.swift       # 画布尺寸 + 宽高比预设
│   ├── NormalizedPoint.swift    # 归一化坐标（0-1）
│   ├── KeyframeSet.swift        # 关键帧动画
│   ├── SegmentTransform.swift   # 位置 / 缩放 / 旋转 / 透明度
│   ├── SegmentContent.swift     # 按类型的内容（video/image/text/subtitle/audio）
│   ├── EditorAsset.swift        # 素材 + MaterialsPool
│   ├── EditorTransition.swift   # 场景转场（独立对象，不挂在 clip 上）
│   ├── EditorSegment.swift      # 片段（sourceRange + targetRange）
│   ├── EditorTrack.swift        # 轨道（kind + zPosition + segments）
│   └── EditorTimeline.swift     # 顶层结构 + 操作便利方法
├── Store/
│   └── EditorStore.swift        # @Observable，undo/redo，mutation API
├── Conversion/
│   ├── ServerTimelineSchema.swift  # 服务端 JSON 的 Codable 镜像
│   ├── TimelineImporter.swift      # Schema → EditorTimeline
│   └── TimelineExporter.swift      # EditorTimeline → Schema → JSON
└── Views/                          # iOS only (#if canImport(UIKit))
    ├── ClipEditorView.swift         # SwiftUI 入口
    ├── EditorPreviewView.swift      # 预览区
    ├── EditorControlBar.swift       # 播放控制栏
    ├── ClipEditorViewController.swift  # UIKit 根控制器
    └── TrackCanvasView.swift        # UIKit 轨道画布
```
