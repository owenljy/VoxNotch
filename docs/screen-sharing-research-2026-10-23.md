# macOS 整屏共享中的窗口隐藏：源码与产品研究

检索日期：2026-10-23。目标是会议软件共享原始显示器时，本机仍能看到并操作 VoxNotch pane，而接收端看不到它。

本次核对了 GitHub 源码、维护者讨论、平台文档及厂商技术说明，没有安装或运行第三方二进制。随后完成了 VoxNotch 隔离演示副本的 Google Meet 整屏共享对照，详见 [本机验证记录](google-meet-screen-share-validation-2026-10-23.md)。下文的“作者测试通过”与“本次已验证”含义不同。

## 研究结论

确实存在比 `NSWindow.sharingType = .none` 更深入的实现。最值得进一步验证的是私有窗口服务接口 **`CGSSetWindowCaptureExcludeShape`**：Chromium 当前源码仍在使用，另有开源桌面应用直接调用，商业产品 Control 也公开声明采用这一机制。它不是新的 `NSWindow.SharingType` 常量。[Chromium 源码](https://github.com/chromium/chromium/blob/30e0ade649c2aac015fd5e23a8e33942024a51fe/components/remote_cocoa/app_shim/native_widget_ns_window_bridge.mm#L75)、[OTTO 源码](https://github.com/ottoappmac/otto/blob/dc7acbe81215f9afe66c08b3796faabf7efcfc90/app/src-tauri/src/stealth.rs#L107)、[Control 技术说明](https://trycontrol.app/blog/how-control-works-technical-deep-dive)。

此前“没有公开的通用窗口防捕获替代常量”这一判断仍成立，但不能进一步推导成“没有其他实现路线”，也不能把 `.none` 描述为在所有新系统、所有 ScreenCaptureKit 路径上一律无效。社区有成功和失败两类记录，捕获端设置会影响结果。[Apple API 文档](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none)、[Natively 的具体兼容问题](https://github.com/Natively-AI-assistant/natively-cluely-ai-assistant/issues/140)。

## 1. 常见路线：仍然使用旧窗口标记

很多“隐形”项目并没有新的底层机制：

| 项目 | 核对到的实现 | 对 VoxNotch 的意义 |
| --- | --- | --- |
| OpenCluely 社区项目 | `window.setContentProtection(true)` | Electron 封装；不能直接当作闭源 Cluely 的源码 |
| Electron | macOS 的 `NativeWindowMac::SetContentProtection` 设置 `NSWindowSharingNone` | 与 VoxNotch 当前的核心请求相同 |
| Ghostbar | 主聊天窗口及自建下拉面板设置 `.sharingType = .none` | 自建菜单窗口也要覆盖，但没有新增全局防捕获能力 |
| KeePassXC | `AppKitImpl.mm` 的 `setWindowSecurity` 设置 `NSWindowSharingNone` | 正规密码管理器也使用这条兼容路线 |

源码：[OpenCluely](https://github.com/AndyDebrah/openCluely/blob/a0dd09091d6202c39a3cb2d71b41af5bd335fcf1/src/managers/window.manager.js)、[Electron](https://github.com/electron/electron/blob/2dcce8748f6912a7dd21adddcf6e76322f105050/shell/browser/native_window_mac.mm#L1190)、[Ghostbar](https://github.com/rbc33/Ghostbar/blob/7d895c0853075b4cd1b24e25f3f6d43de95b794d/Sources/Ghostbar/UI/ChatWindow.swift)、[KeePassXC](https://github.com/keepassxreboot/keepassxc/blob/d5e43b779d5e23c23963d53b806dcda5dd38f50e/src/gui/osutils/macutils/AppKitImpl.mm#L231)。

Electron 官方文档明确说明，使用 ScreenCaptureKit 的较新采集应用仍可能捕获受保护窗口。维护者在 issue #48258 中复现了系统录屏可见的问题，讨论过私有接口，并最终把旧接口问题作为预期行为关闭。上游 Chromium 使用私有接口，不等于 Electron 的 `setContentProtection` 已自动接入它；本次直接检查的 Electron 实现仍是旧标记。[Electron 官方文档](https://www.electronjs.org/docs/latest/api/browser-window#winsetcontentprotectionenable-macos-windows)、[维护者讨论](https://github.com/electron/electron/issues/48258)。

### 为什么有些用户仍报告整屏共享成功

Natively issue #140 提供了具体反例：2026-03-29 的报告中，Zoom 桌面端共享可见，浏览器端隐藏；2026-04-05 的另一位贡献者报告在 macOS 26.4 上切换 Zoom 的 `Advanced capture with window filtering` 后隐藏成功。这是社区环境记录，本次没有复测，不能推广为所有版本通用的设置。[原始讨论及评论](https://github.com/Natively-AI-assistant/natively-cluely-ai-assistant/issues/140#issuecomment-4189453500)。

Zoom 官方确认存在多种捕获模式，Auto 会自行选择；带过滤和不带过滤的模式行为不同，但官方对这些选项的说明不是对第三方窗口隐藏的保证。WebRTC 当前源码也保留按配置选择 ScreenCaptureKit 或另一种 macOS 捕获实现的分支。因此，“浏览器通常能隐藏”的观察也不能作为永久保证。[Zoom 设置文档](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0063824)、[WebRTC 源码](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/desktop_capture/screen_capturer_darwin.mm)。

## 2. 私有接口：窗口级 capture exclude shape

Chromium 在 2024-11-01 提交 `994837a8…` 中，将相关的 `SetAllowScreenshots` 实现从 sharing type 改成窗口区域排除接口，提交说明明确写明这是未公开接口。本次核对的 2026-10-23 源码仍包含该实现。[原始改动](https://chromium.googlesource.com/chromium/src/+/994837a8c8401ca28c6979ced8dd64cc97ca9b92%5E%21/)。

其逻辑是获取当前窗口连接及窗口 ID，创建以窗口自身坐标表示的区域，再调用 `CGSSetWindowCaptureExcludeShape`。当前实现还会在尺寸变化时重新应用区域，并处理父子窗口的保护继承。这些细节说明不能只在启动时调用一次便视为完成。[当前实现](https://github.com/chromium/chromium/blob/30e0ade649c2aac015fd5e23a8e33942024a51fe/components/remote_cocoa/app_shim/native_widget_ns_window_bridge.mm#L96)、[尺寸变化处理](https://github.com/chromium/chromium/blob/30e0ade649c2aac015fd5e23a8e33942024a51fe/components/remote_cocoa/app_shim/native_widget_ns_window_bridge.mm#L1505)。

另一个实际例子是 OTTO 的 Rust/Tauri 原生模块：它同时设置旧 sharing type 和私有 exclude shape，并在显示浮窗前应用。该源码忽略了部分底层调用返回值，注释对兼容性的声明也不是独立测试证据，不宜直接照搬。[OTTO 实现](https://github.com/ottoappmac/otto/blob/dc7acbe81215f9afe66c08b3796faabf7efcfc90/app/src-tauri/src/stealth.rs#L119)。

商业产品 Control 的技术文章明确描述其 Electron 原生模块采用同一 CGS 接口。这是厂商对自身实现的声明，有 Chromium 源码可交叉印证机制存在，但不能由此认证它声称的全部兼容性。[Control 技术文章](https://trycontrol.app/blog/how-control-works-technical-deep-dive)。

这条路线最接近 VoxNotch 的原始整屏共享需求，因为它作用于现有窗口，不必先把 SwiftUI 交互界面转成视频。它的代价是依赖 Apple 未公开的行为；Electron 为 Mac App Store 构建专门移除了相关私有接口。VoxNotch 当前经 GitHub DMG 分发，值得做隔离原型，但外部分发并不让私有接口成为受支持的系统保证。[Electron MAS 改动](https://github.com/electron/electron/pull/49633)。

本次尚未验证它在当前 Mac、Zoom/Meet/Teams 的原始整屏共享中是否完全去掉窗口，是否残留黑块、边框或阴影，以及动画或缩放时是否泄漏。这些是待测问题，不能根据函数名直接判定。

## 3. 公开接口：将内容放入受保护的视频图层

`AVSampleBufferDisplayLayer.preventsCapture` 是公开 API，本机 SDK 标明 macOS 10.15 起可用。它保护该视频图层的图像数据，不是整个 NSWindow 的保护属性。[Apple 文档](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/preventscapture)。

开源 macOS SwiftUI 示例 HardwareVideoDemo 使用 `AVAssetReader` 提供视频样本，在 `AVSampleBufferDisplayLayer` 上开启保护。作者描述捕获结果是视频区域变黑，其他普通 UI 仍被捕获。本次检查了其 SwiftUI 包装和播放器实现，没有运行示例或把其描述视为会议软件认证。[渲染包装](https://github.com/maitrungduc1410/HardwareVideoDemo/blob/0b16da6f1bf435dc148cd5d264794baeae7682c5/HardwareVideoDemo/SecureVideoView.swift)、[播放器及保护设置](https://github.com/maitrungduc1410/HardwareVideoDemo/blob/0b16da6f1bf435dc148cd5d264794baeae7682c5/HardwareVideoDemo/VideoPlayerManager.swift)、[作者说明](https://github.com/maitrungduc1410/HardwareVideoDemo)。

Wisp 项目发布了独立进程捕获测试及统计，报告其 macOS 26.6.1 环境下，受保护视频层在所测截图、视频和直接窗口捕获中未出现合成颜色标记。其报告明确没有把这个结果扩展为所有交互、所有会议接收端通过。本次阅读了报告和生产窗口保护代码，没有重跑它的测试。[Wisp 测试报告](https://github.com/ycl-2004/Wisp/blob/1e86359aa1dd69e31fed260f61e8f5a16fd7a79c/docs/screen-privacy-research-20260910.md)。

对 VoxNotch 的推断：可以研究把只读答案离屏渲染为图像样本，再通过受保护层显示。但需处理流式更新、滚动、缩放、复制、选择、辅助功能和错误恢复；普通 SwiftUI 明文内容不能同时留在可见层级中。黑块遮挡与彻底透明消失也是不同验收目标，不能混为一个“不可见”状态。

GitHub 上还有一些看似可直接接入 SwiftUI 的库，但平台不符：GreedyKit 的 manifest 只声明 iOS；SnapShield 的 manifest 声明 iOS/tvOS/visionOS，不能把 README 中宽泛的 macOS 描述当成现成 AppKit 支持。[GreedyKit manifest](https://github.com/igooor-bb/GreedyKit/blob/main/Package.swift)、[SnapShield manifest](https://github.com/EmadBeyrami/SnapShield/blob/main/Package.swift)。

## 4. 专用共享输出：可过滤，但改变共享来源

Unshown 的公开方案是通过 ScreenCaptureKit 排除指定应用，再显示到名为 Protected Share 的普通窗口，供会议软件分享。它明确要求共享这个专用窗口；共享原始显示器会绕过保护。其官网目前也没有列出已认证的会议宿主。[产品说明](https://unshown.vercel.app/)、[安全边界](https://unshown.vercel.app/security)。

这是真实可设计的替代架构，但不满足“保持选择原始 Entire Screen”的严格条件。`SCContentFilter` 只约束创建该采集流的程序，VoxNotch 给自己的流设置过滤器无法替 Zoom 的流设置规则。[Apple SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter)。

## 5. 其他商业产品的声明应如何理解

| 产品 | 本次查到的直接资料 | 能确认的边界 |
| --- | --- | --- |
| Cluely | 官网宣称不出现在共享与录制中，并提供共享测试页 | 能确认它提供此功能声明；本次未找到足以确认当前版本具体底层机制的官方源码或技术说明，不能把 OpenCluely 当成它的实现 |
| Control | 官方技术文档明确给出 CGS 私有接口方向 | 能确认作者声明的机制及该机制的开源实例，尚无本次兼容实测 |
| Final Round AI | 官方称使用 macOS Core Graphics 排除；帮助中心要求整屏共享测试并检查实际共享画面 | 资料未给出足以确认具体私有函数或当前实现细节的源码 |
| Unshown | 明确披露过滤后的共享窗口及其限制 | 不应计入原始整屏共享隐形方案 |

直接来源：[Cluely 官网](https://cluely.com/)、[Cluely 测试页](https://cluely.com/undetectability)、[Control](https://trycontrol.app/blog/how-control-works-technical-deep-dive)、[Final Round 技术描述](https://www.finalroundai.com/blog/what-is-stealth-mode)、[Final Round 共享测试指南](https://docs.finalroundai.com/docs/live-copilot/stealth)、[Unshown](https://unshown.vercel.app/security)。这些产品对自身能力的营销声明不能替代带版本号的独立验证。

Windows 示例也不应直接外推到 Mac。Windows 10 2004 起有公开的 `SetWindowDisplayAffinity(..., WDA_EXCLUDEFROMCAPTURE)`，其文档明确区分窗口不出现和旧模式的空白内容；这能解释很多跨平台项目为何 Windows 路线更直接，但该函数不适用于 macOS。[Microsoft 文档](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity)。

## Google Meet 专项补充

检索日期同上。Google 官方区分标签页、窗口和整个屏幕三类来源；本研究关注 `Your entire screen`。标签页共享中桌面 pane 不出现，不能作为整屏保护的证据。[Meet 官方共享说明](https://support.google.com/meet/answer/9308856?hl=en)。

### 明确的 macOS / Chrome / Entire Screen 报告

Natively issue #500（2026-08-24）报告：Google Meet 选择 Entire Screen 后，从第二台设备或参与者视角能看到浮层。报告人填写的环境是 macOS 12.x / Intel MacBook Air、Chrome 150.0.7871.125、Natively v2.7。这些版本信息是报告者自述，本次没有核实其组合或重现问题。[原始报告](https://github.com/Natively-AI-assistant/natively-cluely-ai-assistant/issues/500)。

修复 PR #509（2026-08-26 合并）指出，JS 层把内容保护与 Dock 隐藏模式混在一起，窗口每次显示时可能调用 `setContentProtection(false)`，覆盖原生模块的 `.none`。修复让浮层、pill、toggle 始终请求内容保护。作者提供自动检查结果，但明确表示缺少完整 native 构建和私有子模块，未运行完整 app，Meet 的第二端验证仍需维护者确认。因此“PR 已合并”不能记作“当前 macOS 上的 Meet 已经实测通过”。[修复及验证限制](https://github.com/Natively-AI-assistant/natively-cluely-ai-assistant/pull/509)。

后续提交 `925b541`（2026-09-07）又撤回了 PR #509 的始终保护行为，恢复为随 undetectable mode 切换，同时补齐辅助窗口的状态更新。作者验证的是 WindowServer 的 `kCGWindowSharingState` 变化，并未给出 Meet 接收端像素验证；因此 #509 既不能代表其当前产品行为，也不能作为 Meet 兼容认证。[后续撤回及测试边界](https://github.com/Natively-AI-assistant/natively-cluely-ai-assistant/commit/925b541f7a7e2ed1fb1917e7d2168ef99cc37b7a)。

另一份同名 Meet 问题 #459 的环境是 Windows 11，不能拿它作为 macOS 证据。[Windows 报告](https://github.com/Natively-AI-assistant/natively-cluely-ai-assistant/issues/459)。

### 不能根据旧 WebRTC 分支判断当前 Chrome 的 Meet 捕获后端

此前社区“Meet 会回退旧 CoreGraphics，因此 `.none` 可用”的解释存在版本与调用路径问题。Chromium 本次核对的源码在 `in_process_video_capture_device_launcher.cc` 中将 `kScreenCaptureKitMacScreen` 默认开启，对显示器来源优先创建 ScreenCaptureKit 设备，失败才继续尝试其他后端；系统原生选择器也有单独路径。只看到 libwebrtc 某个选项的默认值，不足以证明实际 Chrome 共享会走哪个后端。[Chromium 捕获设备选择源码](https://github.com/chromium/chromium/blob/4fcd974097d9b0967c0789b4dedc26ed40caa3c9/content/browser/renderer_host/media/in_process_video_capture_device_launcher.cc#L91)、[后端选择分支](https://github.com/chromium/chromium/blob/4fcd974097d9b0967c0789b4dedc26ed40caa3c9/content/browser/renderer_host/media/in_process_video_capture_device_launcher.cc#L195)。这是上游源码判断，不代表已确认用户安装的 Chrome 稳定版行为。

Safari 和 Firefox 也不能默认视为“旧接口安全区”：WebKit 有 ScreenCaptureKit 采集实现；Mozilla 维护者说明 macOS 15 上的系统分享选择器支持随 Firefox 132 落地。本次没有找到满足当前版本、原始整屏和接收端验证条件的 Safari/Firefox 隐藏通过记录。[WebKit 采集实现](https://github.com/WebKit/WebKit/blob/e7c482ada164db14120820ad2ab37dd44f1b1160/Source/WebCore/platform/mediastream/cocoa/ScreenCaptureKitCaptureSource.mm)、[Mozilla 维护者记录](https://bugzilla.mozilla.org/show_bug.cgi?id=1842237#c5)。

对 VoxNotch 的结论：**后续本机测试中，macOS 27.0.1 / Chrome 155.0.8059.85 / VoxNotch 0.5.1 (8) 演示副本在 Meet 原始整屏共享中，关闭隐藏时接收会话可见 pane，开启时未见 pane，底层画面仍更新。** 这是同一台 Mac 上两个 Meet 会话的观察，尚无独立第二台设备或全部生命周期的认证；不能推广到所有捕获后端。系统音频开启、缩放、弹出菜单等仍需分别验证。不能用本机系统截图、只共享标签页或单元测试代替会议接收结果。[本机验证过程与边界](google-meet-screen-share-validation-2026-10-23.md)。

## 对 VoxNotch 的建议与验证顺序

1. 保留 `.none` 作为兼容请求，把产品文案改为与实测范围相符的描述。VoxNotch 当前 Always-On pane 确实在创建时设置它，并监听设置变更，但没有 CGS 区域排除或受保护媒体渲染。
2. 原始整屏共享需求优先做独立的 CGS exclude shape 原型。检查符号可用性和调用结果，在显示前应用；覆盖 pane、辅助窗口、尺寸变化、重新打开及开关还原。不要在接口失败时宣称保护成功。
3. 以公开视频图层作为另一个独立实验，先只测试只读答案。分别验收“内容不可读”和“窗口完全不留痕迹”；若远端有黑块，应如实报告。
4. 专用共享窗口可作为另一种产品模式，但必须让用户明确选择该输出，不能把它包装成原始整屏保护。

建议的测试应使用独立录制进程和合成窗口，避免误把本应用自己的排除过滤器当作外部保护证据：

| 维度 | 最少应覆盖的情况 |
| --- | --- |
| 阳性对照 | 关闭保护时，目标色块和独立控制窗口都必须可见；空帧、无权限不能算通过 |
| 保护策略 | `.readOnly`、`.none`、私有排除区域、受保护视频层分别比较 |
| 原始显示器捕获 | SCK 整屏截图及连续视频，过滤器不主动排除 VoxNotch；启动后更新捕获过滤器 |
| 浏览器 | 实际 `getDisplayMedia` 选择整屏，确认 `displaySurface=monitor`，不能用标签页共享替代 |
| 会议端 | Zoom 桌面不同捕获模式、Meet、Teams；记录 macOS 与客户端版本，并检查真正接收端 |
| 窗口生命周期 | 先显示后开始共享、共享中打开、流式答案、拖动、缩放、菜单、popover、Space 和多显示器变化 |
| 结果分类 | 明文泄漏、黑块、边框/阴影残留、真正显示底层桌面分别记录 |

本次完成源码研究和上述有限的 Meet 本机对照，没有实现 CGS 或视频图层原型。现有 `.none` 在本次配置下有效；若要覆盖其他捕获路径，下一步可独立比较 CGS 私有窗口区域排除，不能用本次通过替代兼容矩阵。
