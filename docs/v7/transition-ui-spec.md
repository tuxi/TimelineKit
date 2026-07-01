# 转场 UI 规范（V7）

> 版本：v7.0
> 状态：规范定稿，待实现
> 优先级：P1-B（M5，转场系统 P0 全部上线后执行）
> 依赖：
> - [transition-system-spec.md](transition-system-spec.md)：首批 4 个稳定预设的 presetID / 分类（M3）
> - v2 [transition-spec.md](../v2/transition-spec.md)：时长滑块约束（min=0.2s / max=3.0s）
> - v3 [text-entry-spec.md](../v3/text-entry-spec.md)：底部工具栏布局约束
> - v4 [text-style-fidelity-spec.md](../v4/text-style-fidelity-spec.md)：面板 Tab 样式参考

---

## 一、设计原则

1. **对齐剪映 iOS**：用户心智一致——切割点菱形图标 + 点击唤起底部面板
2. **不破坏现有轨道交互**：转场入口不遮挡轨道编辑区（遵守 V3 底部工具栏隔离规则）
3. **首版静态 Thumbnail**：P1-B 先用静态图标 + 文字标签；动态预览循环动画进 V7 P2

---

## 二、转场入口：TrackCanvasView 扩展

### 2.1 切割点菱形图标

主轨两个相邻 segment 之间的切割点处，渲染一个**菱形（◆）图标**：

- **无转场**：淡灰色半透明菱形（表示可添加转场）
- **有转场**：白色实心菱形 + 宽度等于 `transition.duration × pixelsPerSecond` 的蓝色半透明条带
- 菱形尺寸：20×20 pt
- 条带高度：与主轨轨道高度一致；条带中心 = 切割点 x 坐标
- 仅主轨（`isMainTrack == true`）的切割点显示此图标

**位置计算**（在 `TrackCanvasView` 的 overlay layer 中绘制）：

```swift
// 切割点 x = insertionTime[i+1] × pixelsPerSecond
// 条带 x 范围 = [切割点 - transitionDurationPx/2, 切割点 + transitionDurationPx/2]
```

### 2.2 点击交互

| 手势 | 行为 |
|---|---|
| 点击无转场的切割点（菱形图标区域或切割点周边 ±12pt）| 打开 `TransitionPickerSheet`，默认 Tab = 基础，未选中任何预设 |
| 点击已有转场的菱形图标 | 打开 `TransitionPickerSheet`，当前 Tab = 该转场所属分类，高亮当前预设 |
| 点击条带区域（非菱形）| 选中该转场对应的两个 segment（进入 segment 编辑模式），不弹面板 |
| 长按菱形图标（500ms）| 弹出快捷操作菜单：「删除转场」（红色）|

### 2.3 转场手柄（P1-B 暂不实现，V7 P2 追加）

V2 spec §5.2 定义的「左右拖拽转场标识两侧手柄调整时长」功能留到 P2 实现。P1-B 时长调整通过面板内滑块完成。

---

## 三、TransitionPickerSheet（底部面板）

### 3.1 整体结构

```
┌─────────────────────────────────────────────────────┐
│  ─────── drag handle                                │
│                                                     │
│  [基础] [移动] [缩放] [模糊]          ← Tab 栏       │
│  ─────────────────────────────────────────────────  │
│                                                     │
│  [无]  [叠化]  [闪黑]                              │
│                                                     │
│  ─────────────────────────────────────────────────  │
│                                                     │
│  时长  ●────────────────  0.5s                     │
│        0.2s                           3.0s          │
│                                                     │
│  [ 应用到全部 ]  (灰色，V7 P2 实现)                 │
└─────────────────────────────────────────────────────┘
```

### 3.2 Tab 栏

| Tab | presetID 列表（M4 上线时）| M6 追加 |
|---|---|---|
| 基础 | `none`（无转场）、`crossFade`（叠化）、`fadeThroughBlack`（闪黑）| — |
| 移动 | `slideLeft`（左移）、`pushLeft`（推进·左）| `slideRight`、`pushRight` |
| 缩放 | （空，M6 追加）| `zoomIn` |
| 模糊 | （空，M6 追加）| `blurFade` |
| 风格化 | （空，V7 P2+ 追加）| — |

Tab 显示规则：**空 Tab 自动隐藏**——M4 上线时「缩放」和「模糊」Tab 不显示；M6 完成后自动出现。V7 P1-B 「风格化」Tab 不显示。

### 3.3 预设列表

- 网格布局：每行 3 个（iPhone）/ 4 个（iPad）
- 每个单元格：
  - 正方形缩略图（静态图标，P1-B）—— 64×64 pt
  - 图标下方文字标签（14pt，gray）
  - 选中状态：蓝色描边 2pt + 右上角勾选标记（✓）
- **「无」选项**：始终出现在「基础」Tab 首位，显示「无」文字 + 空白图标

### 3.4 时长滑块

```
min  = max(0.2, transition.minValidDuration)   // 见 v2-spec §2.1
max  = min(3.0, min(leadingDuration, trailingDuration))
step = 0.1s
defaultValue = 0.5s（新建转场）/ transition.duration（已有转场）
```

- 拖动时实时更新预览（`EditorStore.updateTransition(id:duration:)`）
- 拖动结束后写入草稿（触发 undo-tracked mutate）
- 文本标签显示当前时长，格式 `X.Xs`

### 3.5 面板操作逻辑

| 操作 | 行为 |
|---|---|
| 选择预设（从无→有）| 调用 `EditorStore.addTransition(between:and:type:duration:presetID:)`；面板保持打开；segment 时长实时收缩 |
| 切换预设（有→有）| 调用 `EditorStore.updateTransition(id:type:presetID:)`；不重建 compositionVersion（只改类型，不改时长）|
| 选择「无」（有→无）| 调用 `EditorStore.removeTransition(id:)`；segment 时长恢复 |
| 下拉关闭面板 | 保存当前状态，不取消 |
| 背景点击关闭 | 同上 |

---

## 四、EditorStore 扩展（V7 追加）

为支持 `presetID` 字段，在现有 transition 操作上追加一个参数：

```swift
// 已有（v2）：
public func addTransition(between leadingID: UUID, and trailingID: UUID,
                           type: EditorTransition.TransitionType, duration: Double)

// V7 追加 presetID 重载（旧接口保留向后兼容）：
public func addTransition(between leadingID: UUID, and trailingID: UUID,
                           presetID: String, duration: Double,
                           direction: EditorTransition.Direction? = nil,
                           intensity: Float? = nil)

// 已有（v2）：
public func updateTransition(id: UUID, duration: Double)

// V7 追加 presetID 更新重载：
public func updateTransition(id: UUID, presetID: String,
                              duration: Double? = nil,
                              direction: EditorTransition.Direction? = nil)
```

内部实现：新重载通过 `TransitionPresetRegistry.presetID(for:)` 推导 `TransitionType`，构造 `EditorTransition`，走现有 undo-tracked mutate 路径。

---

## 五、转场面板呈现层次

转场面板（`TransitionPickerSheet`）作为 **Sheet** 呈现（`.sheet` 修饰符），与现有「字幕编辑面板」（Sheet）/ 「文本编辑面板」（Sheet）共享 Sheet 槽位：

- 打开转场面板前，关闭其他任何打开的 Sheet
- 面板高度：medium detent（约屏高 45%）+ 可拖拽到 large detent
- 面板在「无转场」状态下时长滑块不显示（因为没有转场可调整）；选中预设后滑块出现

---

## 六、无障碍 & 多语言

| 项目 | 要求 |
|---|---|
| 预设 Thumbnail 的 accessibility label | 使用 `displayName`（中文）|
| 时长滑块 accessibility value | `"\(duration)秒"` |
| 「应用到全部」按钮（V7 P2）| accessibility label = "应用到全部转场" |
| 多语言 | `displayName` 通过 Localizable.strings 提供；presetID 不做本地化 |

---

## 七、验收标准

| 验收项 | 标准 |
|---|---|
| 切割点菱形显示 | 主轨每个切割点均有菱形图标；有转场时显示蓝色条带 |
| 点击无转场切割点 | 面板打开，默认「基础」Tab，无预设高亮 |
| 点击有转场切割点 | 面板打开，跳转到该转场所属 Tab，高亮当前预设 |
| 选择预设 | segment 时长实时变化；面板内时长滑块可用 |
| 选择「无」 | segment 时长恢复；面板内时长滑块隐藏 |
| 切换预设不重建 composition | 切换预设时 `compositionVersion` 不变（仅 presetID 更新） |
| Undo 一步还原 | 添加/删除/更换转场均可 undo 一步恢复 |
| 时长滑块约束 | 无法拖到超出两侧 segment 时长的范围 |
| 8 个首批预设全部可在面板中选到 | 基础 3 + 移动 4 + 缩放 1 + 模糊 1 均出现在对应 Tab |
| 面板打开不遮挡轨道编辑区 | Sheet 打开后轨道仍可水平滚动（Sheet 为独立层） |

---

## 八、V7 固定约束重申

> 见 [V7-initiation.md §八](V7-initiation.md)。实现本 spec 时须遵守：
> - **底部工具栏严格区分：无选中片段仅展示新建入口，选中片段仅展示编辑快捷操作**（V3 约束）
> - **轨道点击仅选中唤起快捷操作栏，不遮挡轨道编辑区**（V3 约束）
> - **转场面板作为 Sheet 呈现，不作为内联 overlay**
> - **选中「无」转场等于删除转场，segment 时长原子恢复**（v2 约束）
