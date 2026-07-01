# TimelineKit v7 文档基线

## 版本定位

V7 是在 V6（图片原生图层渲染 + 关键帧动画底座）之上的**转场系统 + Animation Runtime 全线升级大版本**。

V7 包含两条并行主线：

1. **转场系统（V7 Phase 1，M1-M7）**：把「散落硬编码的 dissolve-only 转场」升级为 `TransitionPresetRegistry` + `TransitionComposer` 可注册预设体系，修复跨内容类型黑屏根因。

2. **Animation Runtime（V7 Phase 2，Am1-Am6）**：建立 TimelineKit 统一动画架构基座——`ClipAnimation` 数据模型、`AnimationSemantic` 三层架构、`AnimationPresetRegistry`、`AnimationComposer` 单出口渲染，支持入场/出场/组合三类动画，适用于图片+视频全内容类型。

两条主线共用三层架构原则（见 V7-initiation.md §八·五），互不耦合，可独立推进。

V6 完成了：
1. 废除 StaticImageRenderer MP4 预合成路径
2. 关键帧 5 维（position / scale / rotation / anchor / opacity）数据底座
3. AI 动画参数（SImageAnimation / SDepthModel / SCamera）端到端映射
4. 渲染层硬规则固化（末态停驻 / overlay 透出 / 全局帧率对齐）

V7 解决的问题：
1. **转场黑屏/闪跳根因**：`LayerResolver` 仅处理 image→image 转场，视频涉及的转场全部直通 → 黑屏
2. **转场只有 dissolve**：`TimelineRenderer` 硬编码 `CIDissolveTransition`，无 preset 体系
3. **转场不跨内容类型**：video→image / image→video / video→video 转场未实现
4. **服务端转场无 fallback**：不支持的类型直接黑屏，无安全降级

---

## 文档列表

### 转场系统（Phase 1）

| 文件 | 内容 | 优先级 | 状态 |
|------|------|------|------|
| [V7-initiation.md](V7-initiation.md) | 立项书：背景 / 范围围栏 / 里程碑 / 风险 / KPI / 固定约束 | — | 立项定稿 |
| [competitive-benchmarks-v7.md](competitive-benchmarks-v7.md) | 竞品对标：转场系统深度调研（剪映/CapCut/FCP/Premiere/VN/Canva） | — | 调研定稿 |
| [transition-system-spec.md](transition-system-spec.md) | 转场系统核心 spec：TransitionPresetRegistry + TransitionComposer + 8 种首批预设实现 | **P0** | 规范定稿 |
| [visual-template-registry-spec.md](visual-template-registry-spec.md) | 视觉模板注册表基座：四件 Registry 的统一接口规范 + 服务端 TimelineTemplateConverter | **P1** | 规范定稿 |
| [transition-ui-spec.md](transition-ui-spec.md) | 转场 UI 规范：底部工具栏入口 + 转场面板 Tab / 预览 / 时长调整 / 删除 | **P1** | 规范定稿 |

### Animation Runtime（Phase 2）

| 文件 | 内容 | 优先级 | 状态 |
|------|------|------|------|
| [competitive-benchmarks-animation-V7.md](competitive-benchmarks-animation-V7.md) | 竞品对标：动画系统深度调研（剪映/VN/FCP/Premiere，入场/出场/组合） | — | 调研定稿 |
| [animation-runtime-V7.md](animation-runtime-V7.md) | Animation Runtime 核心架构：ClipAnimation / AnimationSemantic / AnimationPresetRegistry / AnimationComposer / 首批预设 | **P0** | 规范定稿 |
| [animation-draft-compat-V7.md](animation-draft-compat-V7.md) | DraftStore 集成 + Importer 边界：EditorSegment.animations 字段 / TimelineImporter 解码 / 向下兼容规则 | **P0** | 规范定稿 |
| [animation-ui-spec-V7.md](animation-ui-spec-V7.md) | Animation UI 规范：AnimationPickerSheet / 三 Tab / 预设宫格 / 时长 slider / Live Preview | **P1** | 规范定稿 |

### V7.5 交互补全

| 文件 | 内容 | 优先级 | 状态 |
|------|------|------|------|
| [material-entry-routing-spec.md](material-entry-routing-spec.md) | 素材入口路由规则：主轨添加、空轨道类型化入口、targetTrackID 定向落轨、auto-track 边界 | **P0** | 规则定稿，已落地 |

---

## 与 v1-v6 的关系

V7 在 V6 渲染架构上做加法，**不改动 V6 P0 已落地的任何文件**：

- **v6 `LayerResolver.swift`**：扩展 `resolve` 以输出 `TransitionInfo` 的 video 分支（原来只有 image→image）
- **v6 `TimelineRenderer.swift`**：将硬编码 `CIDissolveTransition` 替换为 `TransitionComposer.blend`
- **v6 `TransitionInfo`**：新增 `presetID: String` + video layer 支持
- **新增文件（3）**：`TransitionPresetRegistry.swift`、`TransitionComposer.swift`、`TimelineTemplateConverter.swift`

不动文件：`ImageLayerComposer`、`KeyframeEvaluator`、`EasingCurve`、`AnimationMacro`、`VideoLayerComposer`、`TextLayerComposer`、`CompositionBuilder`（V6 已整定的 unified compositor 路径）

---

## 开发节奏

```
M1（P0-A：黑屏根因修复 — LayerResolver 支持 video 转场）
  → M2（P0-B：TransitionPresetRegistry + TransitionComposer 骨架 + crossFade 首个实现）
  → M3（P0-C：8 种首批转场预设全部实现 + 导出链路验证）
  → M4（P1-A：服务端转场 fallback 映射 + TimelineTemplateConverter）
  → M5（P1-B：转场 UI 面板 + 底部工具栏入口）
  → M6（P2：视觉模板注册表基座四件完整落地）
  → M7（真机回归 + 720p 40s 性能验收 + 封版）
```

依赖顺序：**黑屏修复必须最先做** → 转场 compositor 骨架 → 预设批量实现 → 服务端映射 → UI → 注册表完整化
