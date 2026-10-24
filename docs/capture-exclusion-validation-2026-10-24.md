# CGS 捕获排除：ScreenCaptureKit 像素验证

日期：2026-10-24，Asia/Singapore。

## 结论

**`CGSSetWindowCaptureExcludeShape` 是“打码”，不是“隐形”。** 在 macOS 27.0.1 上，单独使用它时，ScreenCaptureKit 把窗口整块区域渲染成纯灰色 (128,128,128)。内容看不到，但会暴露窗口的位置、大小和出现时机。

`sharingType = .none` 在本次测试的全部 ScreenCaptureKit 场景下都会把窗口完整移除，接收画面中透出的是窗口底下的内容。两层同时开启时，结果与只开 `.none` 完全一致，看不到灰块。

因此 VoxNotch 同时设置这两层：

- `.none` 生效时，窗口完全隐形，CGS 没有可观察到的影响。
- 如果某条捕获路径不再遵守 `.none`，CGS 提供另一层内容打码请求。本机独立 CGS 测试可以挡住内容，退化为“出现一个灰色矩形”。这不证明所有捕获方都会遵守 CGS，**也不等于隐形**。

此前“Chromium 换用 CGS 说明它比 `.none` 更有效”的推断不成立。CGS 的灰块行为与 Chromium 企业版数据防泄漏的用途（遮住内容）相符；Chromium 换接口的真实原因仍未公开（bug 370058475 不可见）。

## 方法

`VoxNotchTests/CaptureExclusionPixelTests.swift`（opt-in）。窗口由独立进程 `scripts/capture-exclusion-probe.swift` 持有，测试宿主作为捕获方，与会议软件的角色一致，避免“自己截自己”导致的偏差。探针编译并调用生产文件 `VoxNotch/Managers/CaptureExclusion.swift`，不再复制 CGS 实现。测试宿主为 Debug 版 VoxNotch，已有录屏权限；没有权限时跳过像素测试，不弹出授权提示。

```bash
TEST_RUNNER_VOXNOTCH_CAPTURE_PIXEL_TESTS=1 xcodebuild -project VoxNotch.xcodeproj \
  -scheme VoxNotch -configuration Debug test \
  -only-testing:VoxNotchTests/CaptureExclusionPixelTests
```

每种保护模式按顺序检查：

| 场景 | 含义 |
| --- | --- |
| desktop | 窗口出现前采样点的颜色，作为“透明”的基准 |
| unprotected | 阳性对照，未保护时必须能看到品红窗口 |
| whileStreaming | 捕获进行中，对已显示的窗口开启保护（共享中切换设置） |
| afterRepaint | 随后窗口重绘一次 |
| afterFilterUpdate | 捕获方中途更新过滤器（FB21115847 场景） |
| screenshot | `SCScreenshotManager` 新截一张 |
| freshStream | 停止后重新开一条捕获流 |
| afterResize | 放大窗口后检查新露出的边缘和扩大区域 |
| afterRapidToggle | 旧刷新尚未结束时快速关闭再开启保护 |
| restored / rapidOff | 正常关闭或快速开启再关闭后，原内容必须恢复 |
| protectedBeforeShow | 捕获进行中，新窗口先保护再显示（会议中打开 Always-On） |

在窗口内部进行 3×3 网格采样，放大后额外采样扩大区域。任一点出现品红即为 `visible`；中心点与桌面基准近似为 `hidden`；中心点不同于基准则为 `masked`（例如灰块）。坐标按显示器逻辑 bounds 映射至捕获图像，兼容 Retina 比例。没有捕获帧或像素坐标无效时测试失败，不能把默认黑色当作隐藏成功。

## 原提交的结果

macOS 27.0.1 (26A434)，Apple Silicon Mac mini，主显示器。带基准判定的版本运行 5 次，除 CGS 的 whileStreaming 外结果一致：

| 模式 | unprotected | whileStreaming | afterRepaint | afterFilterUpdate | screenshot | freshStream | protectedBeforeShow |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `.none` | visible | hidden | hidden | hidden | hidden | hidden | hidden |
| CGS | visible | **visible 或 masked 灰（每次不同）** | masked 灰 | masked 灰 | masked 灰 | masked 灰 | masked 灰 |
| 两者 | visible | hidden | hidden | hidden | hidden | hidden | hidden |

补充观察：

- 在窗口区域内外各取一组网格采样：单独用 CGS 时，窗口内 676/676 个点都是灰色；单独用 `.none` 或两者同时开启时，窗口内外的灰色比例一致（231/676 与 274/585），即与周围背景无差别。
- CGS 在捕获进行中开启后，有时新帧里这块区域仍沿用旧画面，直到窗口重绘才变成灰块；有时立即变灰。
- 本机未复现 FB21115847：捕获方中途更新过滤器后，`.none` 仍然生效。

## 范围

只覆盖 ScreenCaptureKit 的整屏捕获（连续流与截图），这是 Chromium 当前共享屏幕时优先使用的后端。没有覆盖 Meet、Zoom 等真实接收端，也没有覆盖其他 macOS 版本、多显示器、系统录屏或 QuickTime。Meet 端到端结果见 [Meet 验证](google-meet-screen-share-validation-2026-10-23.md)。

## 共享中切换的修复

原提交 `23b6a61` 的问题已在本机复现：单独开启 CGS 后，`whileStreaming=visible`，主动改变窗口颜色后才成为灰块。单纯 `window.display()` 仍无法可靠刷新；只改变一个像素可以修复初次启用，但放大边缘仍可能露出内容，关闭保护后也可能残留灰块。

现在，管理器仅在成功应用的窗口 ID、尺寸或开关状态变化时请求刷新；普通 drawing/update 回调不反复启动刷新。生产刷新逻辑：

1. 在下一次主线程循环处理，避开 `viewWillDraw` 内递归绘制。
2. 提交待处理的窗口事务，并重设排除区域，以覆盖调整尺寸后的表面。
3. 用覆盖内容区域、透明度为 1/255 的临时黑/白薄层触发整个表面的真实更新，40ms 后移除。薄层不接收鼠标、不进入辅助功能元素，不改变窗口位置、尺寸或焦点。
4. 每个窗口合并刷新；开关或尺寸的新请求使旧延迟回调失效，避免关闭保护后被旧请求重新开启。关闭或隐藏窗口会清理临时视图。

修复后的 AppKit 探针检查：CGS 独立模式在共享中启用、过滤器更新、新捕获流、窗口放大、快速切换和首次显示均为 `masked`；关闭后恢复 `visible`。两层同时开启仍为 `hidden`。

回归测试以**内容不可见**为硬要求：`cgs` 和 `both` 都不能出现 `visible`，允许 `masked`。完全隐形与灰块分别写入报告；单独 `.none` 的结果作为兼容性观察。快速切换、界面层级恢复、焦点不变，以及 CGS 不可用时继续应用 `sharingType` 也有独立检查。

刷新不能撤回捕获方此前已经拿到的帧，也不承诺从切换调用起零帧延迟。开始共享前开启保护仍优于在原内容已显示后再切换。

## 修复的验证记录

- 完整测试：296 项，0 失败，4 项条件测试跳过；已开启并实际执行 AppKit 像素矩阵。
- arm64 Release 构建通过。
- 探针和生产排除代码按 Swift 6、warnings-as-errors 单独编译通过。
- 补充 `cgs-swiftui`、`both-swiftui` 模式，使用 `NSHostingView<Color>` 覆盖与应用 pane 相同的 SwiftUI 图层路径。最后一次尝试因系统没有连接可用显示器而跳过，**尚未完成像素验证**。窗口管理回归重复执行通过；不能把本次整体 `TEST SUCCEEDED` 当成 SwiftUI 像素通过。
