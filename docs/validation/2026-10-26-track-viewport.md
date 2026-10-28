# 轨道时间锚点、生命周期与 Duo 模拟器验收

- 日期：2026-10-26（Asia/Shanghai）
- 被测版本：`feat/agent-editor-integration`，`3b3de5d` 加本轮工作区更改，尚未提交
- 工具链：Xcode 27.1，Build 27A9275
- 范围：时间锚点 / 控制器生命周期修复；Duo 系统姿态、基础键盘转发及导出规格 sheet
- 本轮按用户确认完成模拟器范围，真机和硬件键盘验收留待后续

## 1. 发现与修复

### 1.1 布局分支重建会丢失视口

原实现的 stacked / workspace / folded 分支分别嵌入 `TrackEditorRepresentable`。创建新的 `ClipEditorViewController` 后，初始缩放重新 fit，滚动定位到播放头，且没有恢复原来的纵向位置。

当前由稳定的 `ClipEditorView` 持有 `EditorTrackViewportSession`，保存时间锚点、pixels-per-second、纵向偏移和轨道标签展开状态。重建后的 UIKit 控制器恢复这些状态；同一控制器的尺寸变化也走同样的恢复路径。

控制器身份允许随 SwiftUI 布局分支变化。保证的是同一编辑会话及视口状态连续，不宣称整个过程始终使用同一个 UIKit 实例。session 以弱引用记录当前控制器；旧实例的延迟 `update` / `dismantle` 不会覆盖新实例的状态。

### 1.2 连续重建的像素舍入误差

第一轮恢复实现会从 `UIScrollView.contentOffset` 重新推算时间。Duo 的实际显示缩放会将 offset 对齐到物理像素，重复恢复后可出现微小漂移。

新增的连续重建 24 次回归在修复前失败，30 秒锚点出现约 30.025 / 30.033333 秒的变化。现在保留程序性恢复前的逻辑时间，仅在横向位置或缩放发生实际变化后重新捕获锚点。该回归已通过。

纯计算测试检查精确时间换算；UIKit 视图检查允许最多一个物理像素的显示误差，但 session 中的逻辑锚点在重复程序性恢复后必须保持一致。

### 1.3 重排与初始化的其他边界

- 首次非零布局前的 `apply` 只缓存模型，避免使用零宽度 fit 缩放。
- 缩放视口或移除控制器前，取消活动手势，沿用原有取消处理恢复未提交的裁剪 / 拖动预览。
- 程序性 offset 更新不进入用户 scrub，避免尺寸变化误触 seek。
- 初次 fit 使用独立标志，修复用户缩放至最低 PPS 后结构更新又触发自动 fit 的问题。
- 恢复时按当前内容范围限制时间和纵向位置；新项目的 UUID 不匹配时不恢复前一项目的时间与缩放。

活动裁剪、拖动、重排的全部组合尚未做手工手势验收；现有自动化覆盖的是滚动 scrub 中的尺寸变化。

### 1.4 单场景边界的配置缺陷

修复前，Demo 最终产物中 `UIApplicationSceneManifest.UIApplicationSupportsMultipleScenes` 为 `true`，即使工程没有显式写出该键。此前“没有声明该键即可保证单场景”的判断不成立。

现在为 iOS / iOS Simulator 配置显式 [iOS-Info.plist](../../Examples/VideoEditorDemo/Config/iOS-Info.plist)，关闭自动 scene manifest 生成。Debug 与 Release 模拟器产物均检查为 `false`。macOS 配置保持原有窗口行为。多会话渲染隔离仍未实现，不能据此开放多个编辑会话；所有系统新窗口入口的逐一手工测试尚未完成。

## 2. 本轮执行结果

| 检查 | 环境 | 结果 |
|---|---|---|
| `swift test` 全量 | macOS 宿主 | 109 个 XCTest 用例通过，0 失败 |
| 时间锚点纯计算 | `TimelineViewportSnapshotTests` | 9 个用例通过，包含范围收缩、空时间线、连续尺寸变化与舍入保护 |
| UIKit 生命周期 | iPhone Duo Simulator，iOS 27.1 | 8 个用例通过，0 失败 |
| UIKit 生命周期 | iPad Pro 11-inch (M5) Simulator，iOS 26.1 | 同一组 8 个用例通过，0 失败 |
| Demo Debug 构建 | iPhone Duo Simulator | 通过 |
| Demo Release 构建 | generic iOS Simulator | 通过 |
| 最终 scene manifest | Debug / Release 模拟器产物 | `UIApplicationSupportsMultipleScenes = false` |

9 个纯计算用例包含在 109 个宿主 XCTest 中。`swift test` 在 macOS 不执行 `#if canImport(UIKit)` 中的 iOS 生命周期用例；两组 iOS 结果来自实际模拟器 XCTest 运行。

UIKit 回归覆盖：

1. 同一控制器连续缩放后保持时间、缩放和纵向位置，文档 / 播放头 / undo 状态不变。
2. 控制器重建后恢复视口；旧实例延迟销毁和更新不覆盖新状态。
3. 24 次连续重建不累积逻辑锚点误差。
4. 零尺寸更新推迟到真实布局后初始化。
5. 最低 PPS 在轨道结构变更后保留。
6. 新项目不恢复前一项目的时间或缩放。
7. 移除控制器后，autorelease pool 排空时实例被释放。
8. 用户滚动 scrub 中缩放窗口不会按新宽度误 seek。

## 3. Device Hub 手工检查

以下操作使用 Device Hub 的实际 Closed / Partially Open / Open / Rotate 控件，没有注入合成折痕。它们仍是模拟器结果。

| 操作 | 观察与数据 | 结论 |
|---|---|---|
| 展平 → 书本式半折叠 | 预览在一侧、轨道与控制区在另一侧；控制器发生替换 | 该布局路径可用，状态经 session 恢复 |
| 半折叠 → 合拢外屏 → 外屏旋转 → 展开 | 轨道宽度从约 319.33 → 542 → 815 → 533 / 617 pt 等变化 | 非零锚点 39.218 秒和 PPS 20.781273904839612 保持一致 |
| 三次左方向键 | Device Hub Capture Keyboard 开启；播放头 39.218 → 39.118 秒 | 30 fps 下准确回退三帧；这是模拟器键盘转发结果 |
| 方向键后转为桌面式半折叠 | 播放头保持 39.118 秒；视口关注时间仍为 39.218 秒 | 播放头与视口锚点分别保持 |
| 空格播放 / 暂停 | 播放按钮切换为暂停，画面与轨道前进；再次空格停止 | 基础键盘链路可用 |
| 播放中半折叠 → 展平 | 画面继续播放；新控制器以当前播放头约 8.53344 秒定位 | 观察到播放连续；未量测切换瞬间帧时序 |
| 半折叠打开导出规格 sheet，再旋转 | sheet 随可用区域移动，完成按钮可操作；关闭后回到编辑器 | 此 sheet 的基础区域适配通过；未更改导出参数 |

视口原始诊断摘录保存在 [duo-viewport-events.txt](artifacts/2026-10-26-duo-viewport-events.txt)。记录中的 controller UUID 变化证明运行时确实发生了实例替换，不以 Store 稳定代替 UIKit 生命周期验证。

## 4. 复跑方法

从仓库根目录执行。iOS 测试使用本机已有 XcodeGen 生成临时测试工程，避免聚合 Package scheme 同时构建 CLI 的 iOS 路径；本轮聚合 scheme 在该路径遇到既有 actor 隔离编译错误，未修改 CLI。正常宿主 `swift test` 通过。

```sh
swift test
mkdir -p /tmp/TimelineKitViewportHarness
TIMELINEKIT_PACKAGE_PATH="$PWD" xcodegen generate \
  --spec Tests/TimelineKitUIiOSTests/project.yml \
  --project /tmp/TimelineKitViewportHarness

xcrun simctl list devices available
xcodebuild test \
  -project /tmp/TimelineKitViewportHarness/TimelineKitViewportHarness.xcodeproj \
  -scheme TimelineKitViewport \
  -destination 'platform=iOS Simulator,name=iPhone Duo,OS=27.1' \
  -derivedDataPath /tmp/TimelineKitViewportTests \
  CODE_SIGNING_ALLOWED=NO
```

若同名设备有多台，使用清单中的实际设备 ID 替换 `-destination`。iPad 同理选择实际设备。本轮使用的测试结果包为 `/tmp/TimelineKitViewportResult-finalDuo.xcresult` 与 `/tmp/TimelineKitViewportResult-finaliPad.xcresult`；`/tmp` 文件仅供本机临时检查，不作为长期留存保证。

Demo 启动参数：

```text
-TimelineKitAdaptiveLayout
-TimelineKitOpenSampleProject
-TimelineKitViewportDiagnostics
```

最后一项只在 DEBUG 生效，在 App 临时目录追加 `timelinekit-viewport-diagnostics.log`，记录控制器 ID、视口尺寸、锚点、PPS、纵向位置和播放头。默认关闭，Release 不输出；停止诊断时移除该启动参数。日志不包含素材内容或项目名称。

## 5. 本轮未覆盖

- iPad / Duo 真机、物理铰链和硬件键盘；用户已确认本轮先完成模拟器范围。
- 输入法组合文本、字幕编辑前后焦点、Delete / 撤销 / 重做的完整键盘流程。
- 跨 App 文件 / 照片拖放、落点插入、分隔条完整拖动及比例持久化。
- 所有工具 sheet、摄像头真实激活 / 取消、PiP 和全部窗口尺寸矩阵。
- 多窗口渲染隔离、真实设备性能 / 内存及完整无障碍验收。

这些项目继续跟踪在 [工作区设计文档](../iphone-duo-ipad-workspace-spec.md)，不因本轮的基础姿态与生命周期回归通过而勾选整体完成。
