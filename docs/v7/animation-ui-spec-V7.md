# V7 Animation Runtime：UI 规范

> 版本：v7.1
> 状态：规范定稿
> 优先级：P1（Animation Runtime Am4，在 Am1-Am3 渲染基座落地后执行）
> 依赖：
>   - [animation-runtime-V7.md](animation-runtime-V7.md)（ClipAnimation 数据模型 + 首批预设）
>   - docs/v3/text-entry-spec.md §约束（底部工具栏布局规则）
>   - docs/v7/transition-ui-spec.md（同层工具栏的兄弟面板）

---

## 一、入口

### 1.1 底部工具栏「动画」按钮

当用户选中主轨的**图片或视频 clip**（单 segment 选中态）时，底部工具栏中显示「动画」按钮。

**按钮状态：**
- 默认（无动画）：图标 + 文字「动画」，无高亮
- 已设入场动画：图标左下角显示蓝色小点（in indicator）
- 已设出场动画：图标右下角显示蓝色小点（out indicator）
- 已设组合动画：图标中央显示蓝色小点

按钮点击 → 唤起底部面板（`AnimationPickerSheet`）。

**不显示「动画」按钮的情况：**
- 文字/字幕 segment 被选中（Phase 1 延后）
- 音频 segment 被选中
- 无 segment 被选中（时间轴空白区点击）
- 转场切割点被选中（显示转场面板，不显示动画按钮）

---

## 二、AnimationPickerSheet 面板结构

```
┌──────────────────────────────────────────┐
│   [入场]  [出场]  [组合]          ← Tab  │
├──────────────────────────────────────────┤
│                                          │
│  ○ 无  ○ 渐显  ○ 向左  ○ 向右  ← 宫格  │
│        ○ 向上  ○ 向下  ○ 放大           │
│                                          │
├──────────────────────────────────────────┤
│  时长  ────●──────────  0.5s  ← Slider │
└──────────────────────────────────────────┘
```

### 2.1 Tab 设计

三个 Tab：**入场** / **出场** / **组合**

Tab 切换规则：
- 默认打开时显示「入场」Tab
- 如果当前 segment 已有动画，打开时定位到已有动画的 Tab（入场优先）
- Tab 切换不影响其他 Tab 已设置的动画（各自独立）

**组合 Tab 互斥提示：**
- 如果当前 segment 已有入场/出场动画，切换到「组合」Tab 时显示提示：
  「设置组合动画将清除已有的入场和出场动画」（二次确认）
- 反之，已有组合动画时切换到「入场/出场」Tab 同样提示

### 2.2 预设宫格

- 布局：水平滚动 / 固定列数 2 列（或横屏 3 列）
- 每个格子：缩略图（或图标）+ 名称
- 第一格固定为「无」（对应移除动画）

**首批预设（按 Tab 分类）：**

入场 Tab：
| 格子 | 显示名 | AnimationSemantic |
|---|---|---|
| 0 | 无 | — （移除 inAnimation）|
| 1 | 渐显 | `.fadeIn` |
| 2 | 向右滑入 | `.slideInLeft` |
| 3 | 向左滑入 | `.slideInRight` |
| 4 | 向下滑入 | `.slideInUp` |
| 5 | 向上滑入 | `.slideInDown` |
| 6 | 放大 | `.zoomIn` |

出场 Tab：
| 格子 | 显示名 | AnimationSemantic |
|---|---|---|
| 0 | 无 | — （移除 outAnimation）|
| 1 | 渐隐 | `.fadeOut` |
| 2 | 向右退出 | `.slideOutLeft` |
| 3 | 向左退出 | `.slideOutRight` |
| 4 | 缩小 | `.zoomOut` |

组合 Tab：
| 格子 | 显示名 | AnimationSemantic |
|---|---|---|
| 0 | 无 | — （移除 comboAnimation）|
| 1 | 缓慢放大 | `.slowZoom` |
| 2 | 漂移 | `.drift` |
| 3 | 漂浮 | `.float` |

### 2.3 选中状态

- 当前已选预设：格子高亮描边（主题蓝色）+ 对勾标记
- 「无」格子：segment 无该类型动画时高亮

### 2.4 时长 Slider

**显示条件：** 当前 Tab 选中了非「无」的预设时显示；选中「无」时隐藏（或置灰）

**参数：**
- 范围：0.1s ～ `min(2.0, segDuration * 0.5)` 秒
- 步长：0.1s（精度到 0.1）
- 初始值：打开面板时显示当前 animation.duration；首次选预设使用 preset 默认时长（0.5s）
- 单位标签：Slider 右侧显示当前值，格式 `0.5s`

**组合动画的 Slider：**
- 组合动画时长 = segment 时长（不可调）
- Slider 隐藏；替换为文字：「全程 X.Xs」

**双侧约束显示：**
- 如果入场 + 出场时长超过 segment 时长，Slider 右端变红色，并显示警告文字：「动画时长过长，已自动压缩」
- 实际 `effectiveDuration` 在 `AnimationComposer` 中自动 clamp，不 crash

---

## 三、交互流程

### 3.1 首次添加动画

1. 用户点击工具栏「动画」
2. 打开 `AnimationPickerSheet`，默认「入场」Tab，「无」格子高亮
3. 用户点击「渐显」格子 → 立即触发 **Live Preview**
4. Live Preview：时间轴游标跳回到该 segment 开始位置，播放该 clip（含入场动画效果）
5. Slider 出现，初始值 0.5s
6. 用户拖动 Slider → Preview 实时更新（时间轴不动，仅 Preview 画面更新）
7. 用户关闭面板（下划或点击遮罩）→ 动画保存

### 3.2 修改已有动画

1. 打开面板 → 直接定位到已有动画的格子（高亮显示）
2. 可以：换选其他预设 / 拖动 Slider 调整时长 / 点击「无」移除

### 3.3 移除动画

- 点击「无」格子 → 当前 Tab 对应的动画被移除
- 工具栏按钮小点对应消失

### 3.4 Live Preview 行为

```
用户点击预设格子
  │
  ├─ 临时设置 segment.inAnimation = ClipAnimation(semantic: selected, ...)
  ├─ 时间轴游标跳到 segment.targetRange.start
  └─ 自动播放 min(inAnimation.duration + 0.2s, segment.duration)
```

- Live Preview 期间不保存到 DraftStore（仅临时修改）
- 用户确认选择（不操作 3s 或滑动 Slider）→ 写入 DraftStore 并触发自动保存
- 用户点击「无」格子后 → 移除临时动画，Preview 恢复静止帧

---

## 四、面板与转场面板的关系

| | 动画面板 | 转场面板 |
|---|---|---|
| 触发方式 | 选中 segment + 点击「动画」 | 点击切割点菱形图标 |
| 可同时开启 | ❌（关闭动画面板才能打开转场面板，反之亦然）| — |
| 数据隔离 | `EditorSegment.animations` | `EditorTimeline.transitions` |
| 互相影响 | 无（动画不影响转场渲染顺序）| 无 |

---

## 五、约束

### 5.1 时长约束（UI 层强制）

```swift
// AnimationPickerSheet 中的 Slider 最大值计算
let inDur  = segment.inAnimation?.duration  ?? 0
let outDur = segment.outAnimation?.duration ?? 0
let maxHalf = segment.targetRange.duration * 0.5

switch currentTab {
case .in:
    sliderMax = min(2.0, maxHalf)
    // 额外约束：in + out ≤ segment.duration（out 已存在时）
    if outDur > 0 {
        sliderMax = min(sliderMax, segment.targetRange.duration - outDur)
    }
case .out:
    sliderMax = min(2.0, maxHalf)
    if inDur > 0 {
        sliderMax = min(sliderMax, segment.targetRange.duration - inDur)
    }
case .combo:
    // Slider 不显示，固定为 segment duration
    break
}
sliderMax = max(0.1, sliderMax)  // 最小 0.1s
```

### 5.2 Segment 过短时的降级

如果 segment 时长 ≤ 0.2s：
- 动画按钮仍显示（不隐藏）
- 打开面板后，显示提示：「片段过短，无法预览动画效果」
- 仍然可以设置动画，但 Preview 可能不明显

### 5.3 不支持多选动画

V7 Phase 1 不支持「批量应用动画到全部片段」（类似转场的「应用到全部」）。延后到 Am6 后追加。

---

## 六、`ImageAnimationPanel` 迁移说明（M6）

现有 `Views/ImageAnimationPanel.swift` 是图片专用的 Ken Burns 动画选择面板，对应 `ImageAnimationPreset`。

**M6 之前：**
- `ImageAnimationPanel` 继续存在，入口保持不变（图片 clip 选中后底部「动画」按钮显示旧面板）
- `AnimationPickerSheet` 在 Am4 上线后，逐步替换 `ImageAnimationPanel` 的「组合」Tab 内容

**M6 之后：**
- `AnimationPickerSheet` 完整替代 `ImageAnimationPanel`
- `ImageAnimationPanel` 标记 deprecated，最终从 Views/ 删除
- 「组合」Tab 展示所有迁移后的 Ken Burns 语义预设（slowZoom / drift / depthPush 等）

---

## 七、验收标准

| 验收项 | 标准 |
|---|---|
| 底部工具栏入口 | 图片/视频 clip 选中时出现「动画」按钮；文字/音频不出现 |
| 三 Tab 切换 | 入场/出场/组合 Tab 各自独立；切换不丢失其他 Tab 的设置 |
| 组合互斥提示 | 有入场/出场时选组合，出现二次确认；确认后清除入场/出场 |
| 预设格子选中 | 点击后立即高亮 + Live Preview 触发 |
| Live Preview | 游标跳回 segment 开始，自动播放动画段；Slider 拖动时实时更新 |
| 时长 Slider | 范围正确；in+out 总时长超限时 Slider 变红 + 警告文字 |
| 移除动画 | 点击「无」正确移除；工具栏指示点消失 |
| 草稿保存 | 关闭面板后，重新打开编辑器，动画设置保持 |
| 面板与转场面板不冲突 | 两者不能同时打开；切换时各自正确关闭 |
