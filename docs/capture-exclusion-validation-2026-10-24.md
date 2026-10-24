# CGS 捕获排除：ScreenCaptureKit 像素验证

日期：2026-10-24，Asia/Singapore。

## 结论

**`CGSSetWindowCaptureExcludeShape` 是“打码”，不是“隐形”。** 在 macOS 27.0.1 上，单独使用它时，ScreenCaptureKit 把窗口整块区域渲染成纯灰色 (128,128,128)。内容看不到，但会暴露窗口的位置、大小和出现时机。

`sharingType = .none` 在本次测试的全部 ScreenCaptureKit 场景下都会把窗口完整移除，接收画面中透出的是窗口底下的内容。两层同时开启时，结果与只开 `.none` 完全一致，看不到灰块。

因此 VoxNotch 同时设置这两层：

- `.none` 生效时，窗口完全隐形，CGS 没有可观察到的影响。
- 如果某条捕获路径不再遵守 `.none`（如 macOS 15.4+ 社区报告的情况），CGS 仍能挡住内容，泄漏程度从“内容可见”降为“出现一个灰色矩形”。**这仍然不是隐形。**

此前“Chromium 换用 CGS 说明它比 `.none` 更有效”的推断不成立。CGS 的灰块行为与 Chromium 企业版数据防泄漏的用途（遮住内容）相符；Chromium 换接口的真实原因仍未公开（bug 370058475 不可见）。

## 方法

`VoxNotchTests/CaptureExclusionPixelTests.swift`（opt-in）。窗口由独立进程 `scripts/capture-exclusion-probe.swift` 持有，测试宿主作为捕获方，与会议软件的角色一致，避免“自己截自己”导致的偏差。测试宿主为 Debug 版 VoxNotch，已有录屏权限；测试过程中没有请求新权限。

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
| protectedBeforeShow | 捕获进行中，新窗口先保护再显示（会议中打开 Always-On） |

判定：品红为 `visible`；与基准颜色一致为 `hidden`；既不是品红、也不同于基准为 `masked`（例如灰块）。

## 结果

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

该测试的 `both` 断言可作为回归检查：如果未来 macOS 不再遵守 `.none`，它会报告 `masked`，而不是悄悄通过。
