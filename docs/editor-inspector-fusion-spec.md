# 检查器与工具条融合设计

- 文档版本：0.1
- 更新日期：2026-10-28
- 状态：设计提案；未实施
- 适用范围：`TimelineKitUIiOS` 的 `ClipEditorView`、`EditorBottomToolbar`、`EditorToolPanelContent`、`EditorWorkspaceInspector`、`EditorLayoutPolicy` 与 `Examples/VideoEditorDemo`
- 源码基线：`main` / `6ffefbd`
- 关联文档：[iPhone Duo 与 iPad 自适应编辑工作区设计](iphone-duo-ipad-workspace-spec.md)

## 0. 结论

大屏下检查器应成为唯一的“工具与属性”表面，底部只保留时间线。手机和半折叠姿态则把检查器降级为按需面板。

具体决策：

1. `mediumWorkspace` 和 `wideWorkspace` 移除底部工具条；`wideWorkspace` 同时移除左侧工具 rail。
2. 检查器顶部用标签切换内容类型（视频、音频、调色、动画、文字、信息等），标签集合由当前选择决定。
3. 分割、删除、复制、粘贴、替换等命令移出检查器，放到顶部 toolbar、片段上下文菜单和键盘快捷键。
4. 文字、动画、转场等完整编辑器保留为 sheet 或全屏流程；检查器只放摘要属性和“编辑”入口。
5. 小屏保留底部工具条；不再提供与底部面板内容重复的检查器 sheet。
6. 半折叠时检查器默认关闭，通过系统 sheet/popover 打开，避免跨越折痕或长期压缩时间线。

这是对现有自适应规范中“中等空间保留底部工具条、宽屏保留左侧工具 rail”的修订。自适应规范的布局骨架继续有效，本文接管工具条与检查器的职责划分。

## 1. 问题定义

### 1.1 当前实现

| 位置 | 现状 |
|---|---|
| [`EditorToolPanelContent.swift`](../Sources/TimelineKitUIiOS/Views/EditorToolPanelContent.swift) | 同一个 `EditorToolPanelRoute` 同时包含完整编辑器、快捷操作、类目占位；底部 overlay 和检查器 sheet/column 都渲染它 |
| [`EditorBottomToolbar.swift`](../Sources/TimelineKitUIiOS/Views/EditorBottomToolbar.swift) | 底部类目条负责“剪辑 / 音频 / 文字 / 转场 / 调节 / 动画”；`EditorSecondaryToolPanel` 内还有分割、删除、复制、粘贴等命令 |
| [`EditorToolRail.swift`](../Sources/TimelineKitUIiOS/Views/EditorToolRail.swift) | 宽屏左侧 rail 再次提供同一组类目 |
| [`EditorWorkspaceInspector.swift`](../Sources/TimelineKitUIiOS/Views/EditorWorkspaceInspector.swift) | 检查器只是把 `EditorToolPanelContent` 放进右栏；没有选中/工具时为空 |
| [`ClipEditorView.swift`](../Sources/TimelineKitUIiOS/Views/ClipEditorView.swift) | `mediumWorkspace` 同时显示底部工具条和检查器；`wideWorkspace` 显示左侧 rail、素材区和检查器；半折叠把底部工具条放进时间线一侧 |

### 1.2 为什么用户会觉得重复

当前检查器不是“属性检查器”，而是“工具面板的第二展示位置”：

- 底部工具条/左侧 rail 负责选择类目。
- 检查器负责显示同一类目的内容。
- 手机上的底部 overlay 和检查器 sheet 直接渲染同一个 route，内容完全重复。
- 没有选中片段时，检查器没有可派发的内容，所以显示空白。

因此，问题不是把现有面板“搬进检查器”，而是先拆分**命令、工具流程、属性**三种职责。

## 2. 外部参考

### 2.1 Final Cut Pro

- FCP Mac：Inspector 位于检视器右侧，时间线位于窗口底部；Inspector 顶部用标签切换 Video、Audio、Color、Info 等属性。[Apple Support：Mac 版 Final Cut Pro 界面](https://support.apple.com/guide/final-cut-pro/final-cut-pro-interface-ver92bd100a/mac)
- FCP iPad：底部是磁性时间线；“Inspect”按钮按需打开检查器，检查器显示当前选中片段的格式、变换、音频、效果、转场、字幕等属性。[Apple Support：iPad 版 Final Cut Pro 编辑屏幕](https://support.apple.com/guide/final-cut-pro-ipad/edit-screen-dev3de99654f/ipados)
- 两者共同点：检查器跟随选择自动更新；底部区域以时间线为主，没有一整排工具类目按钮。

### 2.2 Apple HIG

- Inspector 的职责是显示当前选中项的详细信息，并在选择变化时自动更新；根据布局，可以使用 split view 的一栏来承载。[HIG：Panels](https://developer.apple.com/design/human-interface-guidelines/panels)
- regular width 下，inspector 应放在主内容旁边，而不是用 popover 代替；compact 环境才适合临时呈现。[HIG：Mac Catalyst](https://developer.apple.com/design/human-interface-guidelines/mac-catalyst)
- Inspector 内的相关属性切换适合用 segmented control 或标签，而不是再放一套底部类目条。[HIG：Segmented controls](https://developer.apple.com/design/human-interface-guidelines/segmented-controls)
- Duo 的侧边栏、折叠区域和半折叠姿态需要按可用区域布局；可滚动内容可以经过折痕，但交互元素不能落在折痕里。[HIG：Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)、[Design for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111466/)

### 2.3 结论

FCP 的“检查器 + 底部时间线”模型适合 TimelineKit 的大屏形态。Duo 的特殊性在于：展开后不一定有稳定的第三列，半折叠时更不应该强制常驻检查器。因此采用“**大屏常驻、受限姿态按需**”的检查器策略，而不是所有尺寸统一一种布局。

## 3. 职责模型

| 类型 | 内容 | 放置位置 |
|---|---|---|
| 命令 | 分割、删除、复制、粘贴、替换、撤销、重做 | 顶部 toolbar、片段上下文菜单、键盘快捷键 |
| 工具流程 | 导入素材、文字编辑、动画选择、转场编辑、音频素材导入 | 素材面板、sheet、全屏编辑器 |
| 属性 | 变换、裁剪、透明度、速度、音量、静音、淡入淡出、调色、滤镜、文字样式、动画参数、转场时长 | 检查器标签页 |

规则：

- 检查器不承载“分割/删除/复制/粘贴”等命令；这些操作不应出现在属性面板里。
- 检查器可以包含“重置本节”“移除效果”等与属性直接相关的操作，但必须可撤销。
- 底部工具条在小屏继续作为工具流程入口；在大屏不再存在。
- 素材导入属于素材面板/工具流程，不属于片段属性。

## 4. 检查器信息架构

### 4.1 结构

```text
┌─────────────────────────────────────┐
│ 检查器        片段名称        [收起] │
├─────────────────────────────────────┤
│ 视频   音频   调色   动画   信息     │  ← 按内容类型生成
├─────────────────────────────────────┤
│ 变换                                │
│   位置 / 缩放 / 旋转 / 不透明度      │
├─────────────────────────────────────┤
│ 裁剪                                │
│   比例 / 边缘                       │
├─────────────────────────────────────┤
│ 速度                                │
│   倍率 / 倒放 / 保留音高             │
└─────────────────────────────────────┘
```

- 头部：标题、当前片段名称、收起/关闭。
- 标签：根据当前选择的内容类型生成；同类型切换时保留当前标签。
- 内容：可滚动的属性分组；每组有独立重置；连续修改沿用现有 undo 提交规则。
- 空状态：没有选中片段时显示项目设置（画布、帧率、导出规格）和“选择片段”提示，而不是空白。

### 4.2 内容类型与标签

| 选择内容 | 默认标签 | 可用标签 |
|---|---|---|
| 视频片段 | 视频 | 视频、音频、调色、动画、信息 |
| 图片片段 | 视频 | 视频、调色、动画、信息 |
| 文字/字幕 | 文字 | 文字、布局、动画、信息 |
| 音频片段 | 音频 | 音频、效果、信息 |
| 转场 | 转场 | 转场、信息 |
| 无选择 | 项目 | 项目 |
| 多选 | 多选摘要 | 先提供共同属性；复杂多选编辑后置 |

标签命名使用属性语义，而不是命令语义：

- “剪辑”拆成“视频”和“信息”。
- “调节”改为“调色”。
- “文字”保留，但内容是可编辑属性摘要，不是完整文本编辑器。

### 4.3 完整编辑器的处理

| 现有面板 | 检查器中的形态 |
|---|---|
| `TextEditPanel` | 检查器显示字体、字号、颜色、对齐、位置摘要；点击“编辑文本”打开完整编辑器 sheet |
| `AudioEditPanel` | 音量、静音、速度、淡入淡出可直接嵌入检查器音频标签 |
| `ColorAdjustmentPanel` | 调节滑杆和滤镜选择可嵌入调色标签 |
| `AnimationPickerSheet` | 检查器显示当前动画摘要和“选择动画”；完整预设网格在 sheet |
| `TransitionEditSheet` | 选中转场时显示转场类型和时长；完整编辑在 sheet |
| `SegmentReplacePanel` | 替换是命令，移出检查器；由片段上下文菜单或顶部“片段”菜单提供 |
| `TextSegmentActionPanel` | 快捷操作移出检查器；保留属性入口 |
| `AudioSecondaryPanel` | 音频素材导入，移入素材面板/导入菜单 |

### 4.4 标签状态

- 切换同类型片段：保留当前标签；如果新片段不支持该标签，回退到默认标签。
- 切换内容类型：使用该类型的默认标签，不沿用上一个类型的标签。
- 取消选择：回到“项目”标签，不保留上一个片段的属性焦点。
- 多选：先显示“多选”摘要；不修改单个片段的属性，除非所有选中项支持同一属性。
- 布局切换、展开/折叠、检查器收起：不改变选中片段、标签和草稿；只改变呈现。

## 5. 各屏幕与姿态布局

### 5.1 总表

| 状态 | 预览 | 检查器 | 底部区域 | 工具入口 |
|---|---|---|---|---|
| 普通 iPhone / Duo 外屏 | 上方 | 无常驻；不提供重复的工具 sheet | 时间线 + 底部工具条 | 底部工具条 |
| Duo 展开竖屏 | 预览 + 检查器两列 | 常驻，可折叠；宽度不足时 sheet | 时间线 | 检查器标签 |
| Duo 展开横屏 / iPad 横屏 | 素材区 + 预览 + 检查器 | 常驻右侧 | 时间线全宽 | 检查器标签 |
| Duo 半折叠横屏（竖向折痕） | 左 | 默认关闭；从时间线侧打开 sheet | 时间线在右 | 顶部/时间线侧操作 + 检查器按钮 |
| Duo 半折叠竖屏（横向折痕） | 上 | 默认关闭；sheet 或底部抽屉 | 时间线在下 | 顶部/时间线侧操作 + 检查器按钮 |
| iPad 分屏 / Stage Manager | 按可用空间 | 能放两列则常驻，否则 sheet | 时间线 | 检查器标签或检查器按钮 |

### 5.2 展开横屏

```text
┌──────────┬──────────────────────┬──────────────┐
│ 素材区   │                      │ 检查器       │
│          │        预览          │ 视频/音频/   │
│          │                      │ 调色/动画    │
├──────────┴──────────────────────┴──────────────┤
│ 时间线（全宽）                                  │
└─────────────────────────────────────────────────┘
```

- 没有底部工具条，也没有左侧工具 rail。
- 素材区可收起；检查器可收起为 44pt 竖条。
- 命令放在顶部 toolbar 和片段上下文菜单。
- 检查器宽度建议 320–360pt；预览最小宽度在原型中测量。

### 5.3 展开竖屏

```text
┌──────────────────────┬──────────────┐
│                      │ 检查器       │
│        预览          │ 视频/音频/   │
│                      │ 调色/动画    │
├──────────────────────┴──────────────┤
│ 时间线                               │
└──────────────────────────────────────┘
```

- 不显示素材区和左侧 rail，把宽度留给预览和检查器。
- 检查器默认展开；可折叠为 44pt 竖条。
- 如果窗口宽度不足以同时满足预览最小宽度和检查器最小宽度，检查器改为 sheet；不能压缩到不可用。
- 时间线保持全宽，位于底部。

### 5.4 半折叠横屏（竖向折痕）

```text
┌───────────────┬───┬──────────────────────┐
│               │   │ 时间线               │
│     预览      │折 │                      │
│               │痕 │ [检查器] 按钮        │
└───────────────┴───┴──────────────────────┘
```

- 预览在折痕左侧，时间线在右侧；检查器默认关闭。
- 通过时间线侧的“检查器”按钮打开系统 sheet/popover；sheet 由系统避让折痕。
- 不把检查器做成右侧第三列，否则时间线宽度会被压到不可用。
- 时间线保持连续滚动；交互元素不落入折痕。

### 5.5 半折叠竖屏（横向折痕）

```text
┌──────────────────────────────────────┐
│                预览                  │
├──────────────────────────────────────┤
│                折痕                  │
├──────────────────────────────────────┤
│ 时间线                               │
│ [检查器] 按钮                        │
└──────────────────────────────────────┘
```

- 检查器默认关闭，以 sheet 或底部抽屉打开；优先使用系统 sheet。
- 播放、分割、撤销等操作留在时间线侧或顶部 toolbar。
- 底部工具条不再横跨全宽；工具入口改为检查器按钮/上下文菜单。

### 5.6 小屏

- 保留底部工具条和底部 overlay，这是紧凑空间的工具流程。
- 不再提供与底部 overlay 重复的检查器 sheet；检查器按钮隐藏。
- 项目设置使用单独入口，不占用工具类目。
- 选择片段后仍可通过底部工具条进入对应工具；属性变更继续即时写回。

## 6. 与现有实现的迁移映射

| 现有类型/路径 | 目标 |
|---|---|
| `EditorToolPanelRoute` | 拆成 `EditorInspectorTab` + `EditorInspectorContext`；命令类 route 移到 toolbar/context menu |
| `EditorToolPanelContent` | 保留为紧凑工具面板容器；新增 `EditorInspectorContent` 负责属性标签 |
| `EditorBottomToolbar` | 只在 compact/phone 使用；regular 移除 |
| `EditorToolRail` | 移除；检查器标签取代 |
| `EditorWorkspaceInspector` | 改为带标签、头部和滚动属性的检查器；不再直接渲染 `EditorToolPanelContent` |
| `EditorInspectorSheet` | 仅用于 compact 的项目设置/受限姿态检查器；不再作为工具面板的第二副本 |
| `TextEditPanel` | 保留完整编辑器；检查器嵌入文字属性摘要 + “编辑文本”入口 |
| `AudioEditPanel` | 属性控件可直接嵌入检查器音频标签 |
| `ColorAdjustmentPanel` | 调节/滤镜控件嵌入调色标签 |
| `AnimationPickerSheet` | 检查器显示动画摘要；完整选择器在 sheet |
| `SegmentReplacePanel` / `TextSegmentActionPanel` / `AudioSegmentActionPanel` | 命令移出检查器；由顶部“片段”菜单、上下文菜单和快捷键提供 |
| `AudioSecondaryPanel` | 音频素材导入移到素材面板/导入菜单 |
| `EditorLayoutPolicy` | 增加 `inspectorPresentation`（persistent/collapsible/sheet）和 `showsBottomToolbar` 决策；wide 只在横屏/足够宽度启用 |

## 7. 交互与状态规则

- 选择片段后，检查器立即显示该片段的默认标签，不要求先点工具类目。
- 切换片段时检查器内容更新，但布局切换、检查器收起/展开不改变选择。
- 连续修改多个片段时，每次编辑按现有规则进入 undo；打开检查器、切换标签、布局变化不产生 undo。
- 检查器收起后保留当前片段、标签和输入草稿；展开后恢复。
- 文本输入、属性滑杆拖动期间发生布局变化时，保留焦点和组合文本；不能把视图消失当作确认或取消。
- 检查器标签使用 segmented control 或可滚动标签条；同组标签不超过 5 个时优先 segmented control。
- 检查器内的“重置”只重置当前分组，并进入 undo；不提供全局“重置片段”按钮。
- 半折叠 sheet 打开时，时间线保持当前时间位置；关闭 sheet 后恢复到原时间锚点。
- 命令工具栏不重复出现在检查器和底部；同一命令只有一个主入口，其他入口必须是上下文或快捷键。

## 8. 实施阶段

| 阶段 | 交付 | 完成标准 |
|---|---|---|
| P0 | `EditorInspectorTab` / `EditorInspectorContext` / 属性内容抽象；视频片段标签先落地；测试 | 选择视频片段能生成默认标签；不改变现有界面 |
| P1 | 展开横屏：移除底部工具条和左侧 rail；素材区 + 预览 + 检查器；命令移到顶部/上下文菜单 | 横屏下无重复工具入口；预览、检查器、时间线同时可见；连续编辑成立 |
| P2 | 展开竖屏和 medium：预览 + 检查器；检查器折叠；紧凑布局保留底部工具条 | 竖屏宽度不足时检查器转 sheet；状态连续 |
| P3 | 半折叠：检查器 sheet/popover；竖向/横向折痕验证 | 检查器不跨折痕；时间线可用；sheet 关闭后时间位置保持 |
| P4 | 状态持久化、键盘/指针、无障碍、性能 | 面板宽度/标签/收起状态按策略恢复；焦点、VoiceOver、快捷键通过 |
| P5 | 移除旧路径 | 删除 regular 的底部工具条/左侧 rail 和重复检查器 sheet |

## 9. 验收矩阵

- [ ] 展开横屏没有底部工具条和左侧工具 rail，时间线占据底部全宽。
- [ ] 展开竖屏能同时看到预览、检查器和时间线；空间不足时检查器转为 sheet，而不是压缩预览。
- [ ] 半折叠横屏/竖屏默认不显示常驻检查器；打开 sheet 后不跨折痕，关闭后时间位置不变。
- [ ] 选择视频/文字/音频/转场时，检查器自动显示对应默认标签，不需要先选底部类目。
- [ ] 同类型片段切换保留当前标签；内容类型切换回到默认标签；取消选择显示项目设置。
- [ ] 检查器不出现分割/删除/复制/粘贴等命令；这些命令在顶部菜单、上下文菜单或快捷键中可达。
- [ ] 文字、动画、转场的完整编辑器仍可从检查器打开；关闭后属性同步。
- [ ] 手机保留底部工具条和 overlay；没有重复的检查器 sheet。
- [ ] 布局切换、检查器收起/展开、sheet 打开/关闭不改变选择、undo 和草稿。
- [ ] 键盘焦点、VoiceOver 标签、动态字体和减少动态效果可用。
- [ ] 修改属性只重建必要的预览资源，不因检查器标签切换重建 composition 或 timeline。

## 10. 原型需要测量的参数

1. 横屏检查器宽度：320–360pt 的可用范围；预览最小宽度。
2. 竖屏检查器宽度：280–320pt；低于多少宽度改为 sheet。
3. 标签数量与样式：segmented control 的最大数量；超出时改为可滚动标签。
4. 半折叠 sheet 的 detent 和锚点；竖折/横折下的默认高度。
5. 检查器收起后的 44pt 竖条是否保留当前标签图标。
6. 素材区、工具入口和顶部命令菜单在横屏/竖屏的默认展开状态。
7. 检查器标签和面板宽度的偏好是否按姿态分别恢复。

## 11. 风险

| 风险 | 处理 |
|---|---|
| 直接把现有 `EditorToolPanelContent` 搬进检查器，重复仍然存在 | 新建属性内容，不复用动作面板 |
| 文字完整编辑器在窄检查器中不可用 | 检查器只放摘要，完整编辑走 sheet |
| 移除底部工具条破坏已有肌肉记忆 | 顶部“片段”菜单、上下文菜单、快捷键提供等价入口；灰度切换 |
| 半折叠 sheet 覆盖时间线 | 默认关闭，按需打开；优先系统 sheet 避让折痕 |
| 标签状态在切换片段时跳动 | 同类型保留、跨类型回默认；状态存于编辑会话 |
| 检查器更新导致播放/预览重建 | 只更新属性视图；渲染会话保持稳定 |
| 多选属性语义复杂 | 先做单选的共同属性摘要，多选编辑后置 |
| 竖屏检查器压缩预览 | 设定预览最小宽度；不足时转为 sheet |

## 12. 参考

- [HIG：Panels](https://developer.apple.com/design/human-interface-guidelines/panels)
- [HIG：Mac Catalyst](https://developer.apple.com/design/human-interface-guidelines/mac-catalyst)
- [HIG：Segmented controls](https://developer.apple.com/design/human-interface-guidelines/segmented-controls)
- [HIG：Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [HIG：Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- [Design for iPhone Duo（Tech Talk 111466）](https://developer.apple.com/videos/play/tech-talks/111466/)
- [Apple Support：Mac 版 Final Cut Pro 界面](https://support.apple.com/guide/final-cut-pro/final-cut-pro-interface-ver92bd100a/mac)
- [Apple Support：iPad 版 Final Cut Pro 编辑屏幕](https://support.apple.com/guide/final-cut-pro-ipad/edit-screen-dev3de99654f/ipados)
- 本地参考：[iPhone Duo 与 iPad 自适应编辑工作区设计](iphone-duo-ipad-workspace-spec.md)、`iPhoneDuoDesign` 参考项目
