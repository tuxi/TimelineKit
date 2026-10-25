# iPhone Duo 与 iPad 自适应编辑工作区设计

- 文档版本：0.3
- 更新日期：2026-10-25
- 状态：设计提案；产品方向已确认，功能尚未实施或完成设备验收
- 适用范围：`TimelineKitUIiOS`、共享编辑组件与 `Examples/VideoEditorDemo`
- 参考实现：`iPhoneDuoDesign` 学习项目（独立仓库，2026-10-25 对照阅读）

## 1. 产品目标

TimelineKit 提供两种有明确展示和交互差异的编辑形态：

1. **手机剪辑界面**：聚焦当前操作，通过工具分类、底部面板和逐步展开的流程完成编辑。
2. **大屏剪辑工作区**：同时呈现预览、时间线和当前编辑上下文，支持连续选择片段、修改属性和浏览素材。

iPhone Duo 内屏与 iPad 共用大屏工作区的设计语言。适配的主要价值是利用空间改进编辑流程；仅调整预览比例、卡片大小或控件间距，不构成本方案的大屏体验。

### 1.1 体验差异

| 维度 | 手机剪辑界面 | 大屏剪辑工作区 |
|---|---|---|
| 信息组织 | 当前操作优先，工具逐步展开 | 预览、轨道和属性可同时观察 |
| 素材浏览 | 打开选择界面，选择后回到编辑 | 在工作区内展开素材区，连续选择和添加 |
| 属性编辑 | 底部编辑面板 | 跟随选中片段更新的 Inspector（属性检查器） |
| 操作入口 | 底部工具分类与片段操作 | 工作区工具栏、Inspector 与片段上下文操作 |
| 空间控制 | 提供适合单手触控的默认布局 | 面板可收放，预览与轨道的空间可调整 |
| 连续操作 | 按任务进入和退出工具 | 保持工具上下文，依次处理多个片段 |

示例：调整三个音频片段的音量时，大屏用户可以保持音频 Inspector 打开，依次选择片段进行修改；预览和时间线持续可见。选择新片段更新 Inspector 的目标，不需要反复关闭、重新打开工具。

### 1.2 Duo 与 iPad 的适配关系

两者共享可缩放布局、面板组织和会话连续性，但各自需要独立验收：

| 共用基础 | Duo 专项 | iPad 专项 |
|---|---|---|
| compact / regular 编辑形态 | 内外屏切换、半折叠区域 | 自由缩放窗口和不同窗口比例 |
| 素材区与 Inspector 收放 | 系统栏侧置、不对称 safe area | 大窗口同时展开多个面板 |
| 预览、时间线和编辑状态连续 | 桌面式、书本式等使用姿态 | 键盘、指针和跨 App 素材拖放 |

Duo 适配确定的是形态切换、折叠/遮挡区域和系统栏适配的骨架；这部分与 iPad 共用，做好之后 iPad 的大屏形态基本可以确定。但 iPad 仍有两类问题不能由 Duo 验收覆盖：自由缩放窗口（半屏、三分屏、Stage Manager）和桌面输入（键盘、指针、拖放、多窗口）。因此结论是“形态共用、验收分开”，不是“Duo 通过即可宣称 iPad 完成”。

完成 Duo 验收不能替代 iPad 验收。iPad 小窗口也需要手机剪辑界面，大屏设备身份不保证当前窗口有足够空间。

## 2. 苹果设计依据与工程边界

本节记录苹果官方资料中的平台行为；后续工作区布局、优先级和实施阶段是 TimelineKit 的设计决策。

- Duo 外屏采用 compact width，内屏采用 regular width。展开后的应用仍属于 iPhone 环境，不应使用 `.pad` 决定是否显示大屏工作区。
- 通过 size class、局部视图或场景尺寸布局，避免依赖固定屏幕尺寸和横竖屏判断。Duo 内屏也不能靠限制支持方向维持固定布局。
- 侧边纵向栏会占用内容宽度；内屏竖屏是唯一保留横向 bar 的姿态。计算可用宽度时先扣除系统栏和安全区，不能以屏幕宽度作为预览、素材区或 Inspector 的宽度。
- Inspector 的系统 bar 为横向，不随侧边纵向栏迁移；自定义 Inspector 需要显式验证其 bar 与内容的关系。
- 使用 iOS 27.1 SDK 构建后，系统导航和工具栏可以沿侧边竖向排列，需要验证内容及自定义工具的关系。[Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/)、[Three steps to make your app shine](https://developer.apple.com/iphone-duo/prepare/)
- 折叠和摄像头可能形成 reserved regions。系统提供区域查询和 arrangement 容器帮助布局；safe area 之外的内部区域仍需要关注。[Strike a pose with adaptive layouts](https://developer.apple.com/videos/play/tech-talks/111463/)
- 桌面半折叠场景适合上方媒体、下方触控操作的分工。[Design for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111466/)
- 铰链状态、角度可用于交互效果；常规布局优先依赖区域及 arrangement 能力。[Leverage multiple displays and scenes](https://developer.apple.com/videos/play/tech-talks/111464/)
- iPad 需要检查自由缩放和系统窗口排列下的布局。[HIG：Layout](https://developer.apple.com/design/human-interface-guidelines/layout)

设计原则与工程实现分别见 [HIG：Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo) 与 [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)。

当前 Swift Package 最低支持 iOS 18，Demo 的 iOS deployment target 为 18.6。采用新 SDK 与提高最低系统版本是两个独立决策。本方案默认保留现有最低版本，新 API 通过 availability 分支使用，并提供旧系统布局路径；具体 API 签名和可用版本在实现时按所用 SDK 核对。

Duo 的 reserved regions、`ArrangementView` 和 toolbar 纵向行为从 iOS 27.1 开始提供；参考实现用 `@available(iOS 27.1, *)` 包裹，并在旧系统显示回退页。TimelineKit 需要在同一入口内做可用性分支，而不是提高最低版本。Xcode 26 及更早构建不会延伸到状态栏和摄像头之下，验收工具链使用 Xcode 27.1 或后续版本。

## 3. 当前实现审查

以下为 2026-10-25 的源码观察，不代表已复现设备故障。

| 文件 | 当前实现 | 改造或验证方向 |
|---|---|---|
| [ClipEditorView.swift](../Sources/TimelineKitUIiOS/Views/ClipEditorView.swift) | `.pad` 使用 62% 预览高度，其余为 53%；所有窗口采用上下三层布局 | 引入手机与大屏工作区；按内容最低空间分配预览和轨道 |
| [EditorBottomToolbar.swift](../Sources/TimelineKitUIiOS/Views/EditorBottomToolbar.swift) | 固定高度的自定义横向工具栏 | 自建 `HStack` 不会获得侧边纵向布局、溢出或压缩；主操作需评估迁入系统 toolbar，自定义工具条只承担补充控制 |
| [ClipEditorView.swift](../Sources/TimelineKitUIiOS/Views/ClipEditorView.swift) | 文本、音频、调色等面板由底部 overlay 派发 | 提取可嵌入 Inspector 的面板内容，共享编辑行为 |
| [ClipEditorView.swift](../Sources/TimelineKitUIiOS/Views/ClipEditorView.swift)、[TTSConfigSheet.swift](../Sources/TimelineKitUIiOS/Views/TTSConfigSheet.swift) | 过渡编辑使用固定 `.height(310)` detent，其他面板使用固定或中等 detent | 改为内容驱动的 detent，并验证外屏、内屏、半折三种姿态 |
| [ProjectBrowserView.swift](../Sources/TimelineKitUIiOS/Views/ProjectBrowserView.swift) | 固定两列项目卡片 | 根据卡片内容最小宽度自适应列数，保留选中与导航状态 |
| [ClipEditorViewController.swift](../Sources/TimelineKitUIiOS/Views/ClipEditorViewController.swift) | 每次布局更新 inset 和视口，首次布局定位播放头 | 验证连续缩放时的时间锚点、滚动、拖拽和播放头定位 |
| [TrackCanvasView.swift](../Sources/TimelineKitUIiOS/Views/TrackCanvasView.swift)、[ThumbnailTiledLayer.swift](../Sources/TimelineKitUISharedViews/ThumbnailTiledLayer.swift) | 局部使用 `UIScreen.main.scale` | 显示图层跟随所在视图环境的 display scale 更新 |
| [CompositionBuilder.swift](../Sources/TimelineKitRender/Rendering/CompositionBuilder.swift) | 文本图层使用 `UIScreen.main.scale` | 区分显示缩放与导出栅格化需求，按输出画布验证清晰度 |
| [VideoLayerComposer.swift](../Sources/TimelineKitRender/Rendering/VideoLayerComposer.swift) | 全局静态 `frameProvider`；现有全屏预览有暂停与恢复处理 | 多编辑窗口前审查会话隔离，保留全屏预览切换语义 |
| [TextLayerComposer.swift](../Sources/TimelineKitRender/Rendering/TextLayerComposer.swift) | 同样持有全局静态 `frameProvider` | 与视频帧提供者一并处理，不能只审查一处 |
| [MacInspectorPanelView.swift](../Sources/TimelineKitUIMac/MacInspectorPanelView.swift) | Inspector 为占位视图，只有面板外框和空状态，没有属性表单 | 只参考三栏分区与宽度约束；iOS Inspector 的内容需要新建 |

现有 `EditorStore`、`CompositionCoordinator`、共享预览和 UIKit 轨道是复用基础。macOS 工作区可作为信息组织参考；iOS 大屏继续使用 SwiftUI / UIKit 实现触控交互。

`ClipEditorView` 当前注释中的三层布局约束需要在实施时同步修订为“手机布局约束”，并补充大屏工作区约束。既有裁剪、磁吸、撤销和持久化语义继续沿用。

### 3.1 工程配置与验证基础

- Demo 工程已声明 `TARGETED_DEVICE_FAMILY = "1,2,7"`，iPad 与 visionOS 均在支持范围内；iPad 四个方向、iPhone 三个方向均已开启。适配工作不需要修改 target family 或新增方向声明。
- 因此不能通过增删 `UISupportedInterfaceOrientations` 来“锁定”某种布局。方向变化必须由布局本身吸收，Duo 开合与 iPad 窗口变化同理。
- 工程使用自动生成的 scene manifest，未显式声明 `supportsMultipleScenes`。第一阶段需要在场景层明确单会话行为，不能依赖系统默认不创建第二个场景。
- `Tests/` 现有 Core、Render、UIShared、UISharedViews、UIMac、MCP 六个测试目录，没有 iOS UI 测试 target。可复用的只有 `TimelineTrackLayoutTests` 一类纯计算测试，布局与时间锚点逻辑目前没有自动化落点。
- `MacInspectorPanelView` 的注释已说明属性表单属于后续迭代，因此不存在可直接迁移的 Inspector 实现，实施估算时不能按“已有 macOS 版本”计算。

### 3.2 参考实现校验：iPhoneDuoDesign

`iPhoneDuoDesign` 是独立的 Duo 学习项目，剪辑器使用假数据、单轨和 sheet Inspector，不承担真实渲染与多轨验证。它对本方案的价值是布局行为和系统组件用法。以下路径相对于该仓库，结论已按源码核对。

| 参考实现 | 对 TimelineKit 的结论 |
|---|---|
| 无折痕时始终“预览上、时间线下”；竖向折痕改为“预览左、时间线右”；横向折痕保持上下并对齐折痕（`VideoEditorDemoView.swift:36-47`、`:107-156`） | 编辑器主结构保持稳定轴向，折痕只改变区域分配；时间线不拆成两个独立滚动区 |
| 折痕两侧各至少 140pt 才采用左右布局，否则退回普通上下布局（`:89-105`） | 阈值方向正确，但 140 是预览/时间线共用的对称经验值；M1 需分别测量两者，不能直接照搬 |
| 预览高度按 0.55 比例并 clamp，下限 120pt，为时间线保留 100pt（`:107-123`） | 可作为 M1 初始假设；最终值由实际预览、控制条和轨道控件测量得出 |
| 局部高度 < 200 或宽度 < 260 时进入紧凑时间线，隐藏标尺并压低片段（`:308-340`） | 降级依据应是时间线容器自身尺寸，不是设备或屏幕尺寸 |
| 计划文档明确拒绝用 `ArrangementView(.split)` 做编辑器主骨架，因为横屏会把时间线放到右侧、只剩半宽（`.codeagent/plans/video-editor-demo.md` 3.2） | `ArrangementView` 只用于辅助面板/素材区等双视图区域；预览与时间线保持上下主结构 |
| 主操作放入系统 toolbar，使用 `Label`（图标 + 标题）、`ToolbarItemGroup`、`visibilityPriority`、`ToolbarOverflowMenu`（`ToolbarOverflowDemo.swift:84-124`） | 自建 `EditorBottomToolbar` 不会纵向化或进入 overflow；主操作需要系统 toolbar，补充控制可留在自定义条 |
| 在编辑器根容器查询 `division` / `occlusion`，用 `.includeInactive` 观察未激活区域；嵌套卡片内查询会得到负值或屏外坐标（`docs/lessons/07-occlusion-region.md:31-39`） | 区域查询必须放在编辑器根容器；对全部 active 区域取并集，不能只取第一个 |
| 两个 `WindowGroup(id:)`，用 `openWindow` 和 `supportsMultipleWindows` 门控，每个窗口状态独立（`iPhoneDuoDesignApp.swift:12-20`、`MultiSceneDemoView.swift:15-55`） | 多窗口入口按能力显示，不按设备型号；每个场景需要独立编辑会话 |
| Inspector 使用 `.medium/.large` sheet，toolbar 采用系统语义（`VideoEditorDemoView.swift:59-65`、`:748-829`） | 固定高度 detent 不适合多姿态；大屏目标仍是内联 Inspector，sheet 只作为紧凑或临时方案 |

参考实现的共同前提是 iOS 27.1 API，工程 deployment target 为 27.0，Duo 专属视图用 `@available(iOS 27.1, *)` 包裹。TimelineKit 最低支持 iOS 18.6，回退分支更多，不能假设这些容器和区域 API 在所有目标系统上可用。

## 4. 布局决策

### 4.1 输入与决策顺序

布局输入包括 horizontal / vertical size class、局部可用尺寸、safe area、有效 reserved regions、键盘占用、文字大小，以及用户的面板展开偏好。

1. 以 size class 选择手机或大屏的主要交互形态。
2. 在可用区域中检查预览、轨道和面板是否满足各自内容的最低需求。
3. 宽度为 regular、垂直空间不足时退回上下布局：iPad 横向分屏、Slide Over 或 Stage Manager 矮窗口不能仅凭 regular width 启用侧栏工作区。此时保留大屏的连续操作上下文，但采用上下排列。
4. regular width 且高度满足时，按空间提供单辅助面板或多面板工作区。
5. 空间不足时逐步收起非必要面板或改用临时呈现，保留工具入口和当前任务。
6. 对有效折叠区域重新安排内容与操作，必要时调整工作区方向。

不设置绑定某款设备像素尺寸的分支。内容最小尺寸属于组件约束，应通过实际控件、文字大小和触控需求验证；窗口变宽不自动覆盖用户主动收起面板的偏好。临时空间约束与用户偏好分开保存。

上述最低尺寸是 M2 的输入，必须在 M1 测量原型中产出，不能留到 M2 实现之后再试凑，见第 8 节。

### 4.2 手机剪辑界面

- 预览、控制条、时间线和工具入口形成主要编辑路径。
- 工具通过底部面板或系统 presentation 按需打开。
- 在低高度、键盘弹出或较大文字下重新分配空间，保障当前输入及核心轨道操作可访问。
- 预览按项目画布比例 fit；给控制、轨道和工具预留最低空间后，再分配剩余高度。

### 4.3 大屏工作区：中等空间

适用于 Duo 展平内屏、iPad 中等窗口。以下是逻辑分区示意，具体排列服从系统栏和实际空间：

```text
┌───────────────────┬─────────────────┐
│                   │ 辅助面板        │
│       预览        │ 素材 / Inspector│
│                   │ 按需切换        │
├───────────────────┴─────────────────┤
│ 播放与工作区操作                    │
├─────────────────────────────────────┤
│ 连续时间线                          │
└─────────────────────────────────────┘
```

- 默认保留预览与时间线，并支持同时显示当前属性面板。
- 素材浏览与 Inspector 默认复用一个辅助区域，用户可以切换或收起。
- 素材在工作区内连续添加；属性面板随选中片段更新。
- 可用宽度先扣除系统侧边栏、safe area 和活动折叠区域；辅助面板的展开不应以把预览或轨道压到不可用为代价。
- 不适合侧向展开时，使用可容纳的上下安排或临时面板，保留大屏的连续操作上下文。

### 4.4 大屏工作区：充足空间

```text
┌──────────┬────────────────┬───────────┐
│ 素材区   │                │ Inspector │
│          │      预览      │           │
├──────────┴────────────────┴───────────┤
│ 播放与工作区操作                     │
├──────────────────────────────────────┤
│ 连续时间线                           │
└──────────────────────────────────────┘
```

- 素材和 Inspector 可同时展开，也可以分别收起。
- 系统侧边栏会占用内屏横屏的宽度；三栏都按扣除后的容器宽度布局。Inspector 的 bar 是横向，不随其他工具栏纵向排列。
- 允许调整上方工作区与时间线的空间比例，并限制在内容可用范围内。
- 项目管理与编辑素材浏览保持职责清晰；不要求编辑过程中始终显示项目列表。
- 大屏默认支持触控；键盘和指针在同一工作流中提供效率增强。
- 预览与时间线保持稳定的上下主结构；`ArrangementView` 只用于素材区和 Inspector 这类辅助双视图，不作为主分栏。

## 5. Duo 姿态与系统区域

| 场景 | 工作区行为 |
|---|---|
| 外屏 | 手机形态；尊重侧边系统栏及不对称 safe area |
| 内屏展平 | 大屏形态；按空间展开辅助区域，允许连续时间线使用可用宽度 |
| 内屏横屏 | 大屏形态；侧边纵向栏占用宽度，内容按扣除后的容器布局 |
| 内屏竖屏 | 唯一保留横向 bar 的姿态；宽度充足，优先使用全宽时间线 |
| 桌面半折叠 | 优先将预览放到上方完整区域，轨道和常用操作放到下方稳定触控区域 |
| 书本式半折叠 | 结合区域形状安排预览与辅助面板，关键交互目标避开折叠区域 |
| 与其他 App 分屏 | 重新评估当前窗口空间，必要时进入手机形态；左右 App 的控件各在外边缘 |
| 内外屏连续切换 | 重排同一编辑会话，保留选中、时间位置和未完成任务 |

实现规则：

- 折叠区域分两类处理：`division`（折痕）决定工作区分区，`occlusion`（摄像头）只影响被遮挡的控件。两者都通过 reserved regions 查询，不写死位置或尺寸。
- 区域查询放在编辑器根容器，使用 `.includeInactive` 获取未激活区域；`region.frame` 属于查询容器的坐标空间，可能为负值或落在容器外。布局只使用 `isActive` 的区域，并对全部 active 区域取并集。
- 无活动折痕时保持“预览上、时间线下”的稳定结构。竖向折痕采用“预览左、时间线右”，横向折痕保持上下并把分界对齐折痕；时间线始终是一个连续滚动区，不拆成两个时间轴。
- 折痕本身不放任何可交互控件。时间线内容可以滚动经过折痕，但播放头、裁剪手柄、选中边框和按钮必须位于可用区域；播放头落在折痕时锚定最近可用边缘，时间值不变。
- 折痕两侧的可用尺寸要分别满足预览和时间线的最低需求。参考实现的 140pt 对称阈值只作为起点；任一侧不满足时退回普通上下布局，而不是压缩到不可操作。
- `ArrangementView` / `UIArrangementViewController` 只用于辅助双视图（素材、Inspector 等），不用于预览与时间线的主分栏；不要把它们嵌在 `NavigationSplitView`、`List` 或 `ScrollView` 内，导航容器放在外层。
- 系统导航及工具栏使用标准容器（toolbar / tab bar / navigation container），才能获得侧边纵向布局、溢出和压缩。自建横向 `HStack` 不会自动纵向化；它只能承担补充控制，不能作为系统适配的唯一入口。
- 不通过增删方向声明来维持布局。iPad 四方向与 Duo 开合都已在现有声明范围内，布局必须在方向变化时自行重排。
- 自定义预览、播放控制和时间线需单独评估内部区域，不能仅增加外边距。可用宽度先扣除侧边栏、safe area 和活动折叠区域。
- 时间线属于连续滚动内容，不因出现折叠区域就拆成两个独立时间轴。优先选择能保持连续编辑的可用区域；必须改变视觉映射时，统一更新显示、点击、拖动、裁剪和吸附的坐标换算。
- 播放头不强制固定在几何中心；若该位置落在折叠区域，可锚定合适的可用编辑区域，保持同一时间位置。
- `alert`、`menu`、`popover` 和 `sheet` 优先交给系统定位；自定义面板验证其目标区域及尺寸，不以固定高度覆盖所有场景。

## 6. 交互与状态连续性

### 6.1 面板交互

- 分离“当前片段”“当前工具”“面板位置与可见性”。收起、迁移面板不清除片段选择。
- 保留手机现有工具与选择派发语义；大屏需明确区分用户切换工具与系统移动面板，避免布局变化触发现有类目切换的取消选择逻辑。
- 切换选中片段时，Inspector 显示兼容属性；没有选中时提供明确空状态，并禁用需要选择目标的动作。
- 连续修改不同片段时，每次编辑按既有提交规则进入 undo；面板打开和布局切换不生成 undo。
- 布局切换期间保留输入焦点、草稿及输入法组合文本；不能把视图消失当作用户确认、取消或清空内容。
- 工具 sheet 使用内容驱动的 detent（如 `.medium` / `.large`），不用固定高度覆盖所有姿态。外屏 sheet 默认纵向控件，内屏使用横向 bar，半折时系统会滑开避让折痕；自定义 sheet 内容需逐一验证这些行为。

### 6.2 时间线与手势

- 缩放或折叠前记录关注的时间锚点及其视口位置，重排后恢复合理位置；避免仅保留像素 offset。
- 保留 pixels-per-second 缩放、选中片段与轨道纵向关注位置，必要时将 offset 限制到新范围。
- 程序性重定位不触发用户 scrub，不修改当前播放时间或产生额外 seek。
- 裁剪、移动等活动手势遇到布局变更时需有明确中断策略：保留已提交操作，未提交预览按既有取消语义恢复；不重复提交或留下半次 undo。
- 自动布局和视口重排不得写入 segment 的 target range、source range 或项目画布。

### 6.3 输入方式

第一阶段保证触控完整可用，后续提供空格播放、撤销 / 重做、逐帧定位、删除及合理焦点顺序。文本输入获得焦点时，编辑器快捷键不能截获正常输入。

素材区可增加向时间线拖入素材、从照片或文件拖入资源的能力；保留显式添加入口。指针 hover、手柄反馈和上下文菜单用于提升精细编辑效率。[HIG：Drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)

### 6.4 系统栏与工具入口

- 导入、撤销、Inspector、导出等主操作放入 `NavigationStack` / `NavigationSplitView` 的 toolbar；每个非文字项使用 `Label` 同时提供图标和标题，否则不会进入纵向栏。
- 用 `ToolbarItemGroup` 分组，`visibilityPriority(.high/.low)` 控制溢出顺序，必须隐藏的操作放 `ToolbarOverflowMenu`。文字按钮、分段控件等过宽控件用 `.axisBehavior(.horizontalOnly)` 留在横向 bar。
- 工具栏必须挂在真正的导航容器上；放进 `ScrollView` 或固定高度卡片后，系统不会把它当作 bar，也不会纵向化。
- `TabView` 与 toolbar 同时在纵向栏竞争时，按任务类型选择 `ToolbarVerticalCompressionBehavior`；编辑器属于任务型，优先保留核心工具而不是标签栏。
- 自建底部工具条不参与上述机制。它可以保留为触控快捷入口，但主操作必须在系统栏中有等价入口。
- Inspector 的 bar 是横向，不随侧边纵向栏迁移；自定义 Inspector 需单独验证。

## 7. 架构与兼容方案

### 7.1 单一编辑会话，两种呈现

建议职责如下；下列会话与布局类型为设计角色，不代表现有公开 API。

```text
ClipEditorView（现有公开入口）
  ├── 稳定的编辑会话
  │     ├── EditorStore / 文档 / 选择 / undo
  │     ├── CompositionCoordinator / 播放器
  │     └── 当前任务 / 输入草稿 / 工作区偏好
  └── 自适应工作区容器
        ├── 手机呈现
        ├── 大屏呈现
        └── 系统区域适配
              ↓ 共用
        预览 / UIKit 时间线 / 素材与属性编辑内容
```

- 在稳定身份中持有 `EditorStore` 和播放协调器；切换布局不重新创建它们。
- 宿主传入 `editorStore` 时，继续使用同一实例。保留 `editorAccessory` 与持久化回调的契约，见 [Agent 集成说明](editor-agent-integration.md)。
- 不为手机与大屏各创建一个同时存活的播放器或时间线控制器。SwiftUI 分支切换时，显式处理 UIKit 容器的身份与状态恢复。
- 布局组件的 `onAppear` / `onDisappear` 不承担编辑会话的打开、退出或保存职责；真实编辑器退出继续执行原有保存语义。
- 视口变化只更新显示布局及必要的显示资源，不因尺寸变化重建 composition、清空 undo 或修改 timeline。

### 7.2 模块归属

| 模块 | 责任 |
|---|---|
| `TimelineKitCore` | 继续承载与设备无关的时间线模型和编辑语义 |
| `TimelineKitRender` | 保持预览 / 导出语义；区分渲染画布与 UI 视口 |
| `TimelineKitUIShared` | 共用编辑状态和持久化；只抽取确有复用价值的任务状态 |
| `TimelineKitUISharedViews` | 共用预览和适合跨平台的面板内容 |
| `TimelineKitUIiOS` | 手机 / 大屏工作区、触控、UIKit 时间线、Duo 区域及版本兼容 |
| `TimelineKitUIMac` | 提供工作区组织参考；保留 macOS 原生交互 |
| `VideoEditorDemo` | 展示项目浏览及两种编辑形态，承载设备和窗口验收 |

第一阶段不新增专用 `UIiPad` 或 `UIDuo` target。布局差异由 iOS 工作区容器表达，编辑动作及面板内容复用。

### 7.3 多窗口与场景边界

第一阶段范围为单一编辑会话对窗口变化的适配。多项目同时编辑、外接独立预览和 Duo 双屏附件属于后续扩展。

工程当前使用自动生成的 scene manifest，未显式声明 `supportsMultipleScenes`。第一阶段必须明确以下之一，并在实现时验证：

- 不注册多场景，编辑会话只存在于唯一场景；
- 或注册多场景，但在场景层校验，同一项目已有编辑会话时拒绝或转为只读提示。

不能依赖“系统默认不会开第二个窗口”。iPad 程序坞、Stage Manager 和 Duo 外部显示都可能触发新场景。

若采用多场景，使用 `WindowGroup(id:)` 声明窗口，通过 `openWindow(id:)` 打开；入口用 `supportsMultipleWindows` 动态判断，不按设备型号显示。每个场景必须持有独立的编辑会话和渲染资源，不能共享同一 `EditorStore` 实例。

开放第二个编辑会话前，必须处理两处进程级静态状态：`VideoLayerComposer.frameProvider` 与 `TextLayerComposer.frameProvider`。两者都是 `nonisolated(unsafe) static var`；单窗口内“预览 + 全屏预览”已可能竞争写入，两个会话并存时会互相覆盖。还需验证同一项目并发保存和媒体资源生命周期。多窗口入口需跟随系统能力动态可用，不能只按设备型号显示。[多显示与场景说明](https://developer.apple.com/videos/play/tech-talks/111464/)

## 8. 实施顺序

| 阶段 | 交付内容 | 完成标准 |
|---|---|---|
| M1：会话、面板与测量基础 | 稳定编辑会话；分离工具内容与呈现；提取布局决策；布局测量原型（含折痕/遮挡与调试覆盖层）；确定测试落点 | 现有手机操作和宿主 API 回归通过，布局变化不重建会话；产出预览与时间线各自的最小尺寸、折痕回退阈值和自动化测试入口 |
| M2：两种 UI 形态 | compact 手机界面；regular 中等空间工作区；自适应项目网格；按阈值降级 | 能同时观察预览、轨道和属性，连续编辑流程成立；regular + 矮窗口退回上下布局 |
| M3：Duo 专项 | 内外屏连续性、侧边系统栏、reserved regions、半折叠布局、摄像头遮挡与 sheet 三姿态 | Duo 姿态矩阵及切换过程通过验收 |
| M4：iPad 完整工作区 | 宽窗口多面板、比例调整、键鼠和素材拖放 | iPad 多窗口尺寸与输入矩阵通过验收 |
| 后续扩展 | 多编辑窗口、独立预览及显示附件 | 完成渲染会话和保存隔离后另行定义范围 |

首个可交付版本至少包含 M1–M3，并在 iPad 的全屏及紧凑窗口验证共享基础。宣称完整 iPad 工作区适配时，还需完成 M4；只有可拉伸的界面不满足交付标准。

M1 的测量原型只做尺寸测量与占位布局，不改现有编辑交互。需要产出预览、轨道、Inspector 和素材区的最小可用尺寸，以及这些尺寸在不同文字大小和键盘状态下的变化范围。没有这组数据，M2 的形态切换与降级规则只能试凑。

折痕两侧要分别测量：预览需要画布比例和控制条空间，时间线需要片段最小宽度、手柄命中区和标尺高度，不能共用参考实现的 140pt 对称阈值。原型应显示当前 size class、容器尺寸、active `division` / `occlusion` 的 frame 和可用区域，做法可参考 `iPhoneDuoDesign` 的 `poseBadge`（`VideoEditorDemoView.swift:181-198`）。

M1 同时确定自动化测试落点：新建 `TimelineKitUIiOSTests`，或把布局决策与时间锚点换算抽成纯函数并入 `TimelineKitUISharedViewsTests`。当前没有 iOS UI 测试 target，若不先建立入口，第 9 节的连续缩放与锚点检查只能依赖人工回归。

## 9. 验收矩阵

以下均为待执行检查项，不表示当前已通过。

### 9.1 场景覆盖

| 环境 | 布局检查 | 连续操作检查 |
|---|---|---|
| 普通 iPhone | 竖向、横向、低高度 | 剪辑、字幕、音频、导出保持可用 |
| Duo 外屏 | safe area、侧边系统栏、工具入口 | 播放与编辑中展开到内屏 |
| Duo 内屏展平 | 大屏工作区、素材与 Inspector、侧边栏占宽 | 连续选择多个片段编辑，再返回外屏 |
| Duo 内屏横竖切换 | 竖屏保留横向 bar，横屏使用侧边纵向栏 | 旋转后时间锚点、选中和面板状态保持 |
| Duo 画中画 / 系统浮层 | 垂直空间被压缩、工具栏更容易溢出 | 播放中布局调整，预览与时间线仍可用 |
| Duo 摄像头遮挡 | `occlusion` 区域激活/未激活 | 交互控件不被遮挡，布局不跳变 |
| Duo 半折叠 | 桌面式、书本式、旋转后区域变化 | 预览与关键交互目标可见，时间映射正确 |
| Duo 分屏 | 当前 App 在不同侧、空间缩减 | 切换形态后保持选中、时间位置与草稿 |
| iPad 不同屏幕尺寸 | 全屏横竖向、半屏、三分屏、四分屏及自由缩放 | 连续拖动窗口尺寸，面板合理收放 |
| iPad 输入 | 触控、键盘、指针、软件键盘出现 | 焦点、快捷键、字幕输入和素材拖放 |
| 旧系统 | availability 回退布局 | 打开项目、手动编辑、保存、导出 |
| RTL | 侧边栏仍与硬件同侧，内容对侧留白 | 工具、播放头与手势方向正确 |
| 辅助功能 | 较大文字、VoiceOver、键盘导航 | 工具可访问，选中与控件标签清楚 |

### 9.2 必须满足的结果

- [ ] regular 环境提供专门的大屏编辑流程，支持预览、时间线和当前属性同时可见。
- [ ] 手机 / 大屏切换不改变当前项目、选择、undo / redo 和未完成输入。
- [ ] 播放中改变布局不因会话重建中断；切入后台或系统中断沿用既有播放策略。
- [ ] 轨道时间锚点及缩放合理保留，程序性布局不会误触 scrub。
- [ ] 折叠区域附近的播放头、手柄和控制可操作，拖动、命中与吸附使用一致坐标。
- [ ] 摄像头 `occlusion` 区域激活前后，关键控件不被遮挡，布局不产生跳变。
- [ ] 主操作在系统 toolbar 中可纵向展示、溢出和压缩；自定义工具条不是唯一入口。
- [ ] 工具 sheet 在 Duo 三种姿态下不被固定高度裁切，输入内容保持。
- [ ] PiP、键盘或系统浮层压缩空间时，预览与时间线按最低尺寸降级，不重叠或截断。
- [ ] 面板移动不触发取消选择、空文本删除、误保存或重复提交。
- [ ] 同一时间线在布局变化前后，画布、片段数据及导出参数一致，预览与导出语义一致。
- [ ] 相同项目和任务下，缩放窗口不反复重建 composition；通过性能采样检查重建次数、卡顿和资源释放。
- [ ] 第一阶段不出现第二个并发编辑会话；若系统创建新场景，行为符合第 7.3 节选定策略，两个静态 `frameProvider` 不会被交叉写入。
- [ ] 全屏预览返回后，时间位置回写与渲染恢复继续正确。
- [ ] 宿主持有的 `EditorStore`、Agent 外部修改及保存回调在两种布局下保持原有契约。

### 9.3 验证方法

布局选择、时间锚点换算和手势取消等有行为边界的逻辑应纳入自动化测试。当前没有 iOS UI 测试 target，M1 需先确定落点：新建 `TimelineKitUIiOSTests`，或把决策逻辑抽成纯函数放入 `TimelineKitUISharedViewsTests`。测试至少覆盖 size class 与尺寸组合的形态选择、regular + 矮窗口的降级、时间锚点换算，以及面板收放与选择状态的独立性。

系统栏纵向化、溢出顺序、sheet 三姿态、键盘与折叠区域需要模拟器与可用真机验收；静态截图不能替代对溢出和折行的观察。

使用 Xcode 27.1 或后续支持 Duo 的工具链，在 Device Hub 中验证开合、旋转和折叠过程。验收记录应注明系统 / SDK 版本、设备、窗口状态和测试项目。开发机能编译及静态截图均不能替代连续操作验收。

## 10. 后续需要通过原型确定的参数

产品方向已确定，以下细节不在本文写死设备断点。第 1、4、6 项的初始范围必须在 M1 测量原型中产出，作为 M2 布局切换与降级的输入；其余项在相应阶段的设备验收中确定：

1. 常规布局下，素材区、Inspector、预览和可操作轨道的最小尺寸。
2. 中等空间辅助面板的默认展开状态，以及不同任务下的切换方式。
3. 折叠时预览和时间线的区域分配，特别是书本式姿态的连续编辑体验。
4. 预览 / 轨道比例的初值、可调整范围及偏好恢复策略。
5. 首批快捷键、外部拖入素材的定位提示和失败反馈。
6. 折痕两侧预览与时间线各自的最小尺寸，以及任一侧不满足时的回退阈值。
7. 摄像头 `occlusion` 的预留策略：哪些控件在区域激活前就避让，哪些只在激活时移动。
8. 系统侧边栏宽度对三栏工作区的影响，以及面板收起的优先级。

这些参数的选择应服务于“看得清、够得着、连续编辑不丢状态”，并通过第 9 节矩阵验证。
