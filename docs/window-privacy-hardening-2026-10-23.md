# 窗口隐私改进与回归记录

日期：2026-10-23，Asia/Singapore。本轮落实 Natively 研究中适合原生 AppKit / SwiftUI 的窗口管理改进。

## 已实现

- `WindowPrivacyManager` 统一应用现有 `.none` / `.readOnly` 请求，覆盖已注册窗口、当前 app 窗口、子窗口和 attached sheet。设置开关变化时包括未显示的历史窗口和引导窗口，修复它们此前只在创建时读取设置的问题。
- 自有窗口在显示、重新打开前应用策略；AppKit 窗口更新、恢复、激活、全屏/显示器变化，以及工作区 Space 切换、唤醒时恢复状态。注册表弱引用窗口，不新增常驻轮询。
- 所有显式 `.help()` 经统一 modifier 处理：请求隐藏时传空 tooltip 文本，同时保留辅助功能 hint。图标按钮保留可读名称，设置中的信息图标改为可访问的 Button。
- 隐藏模式下，模板、音频设备、模型和插入菜单改为 popover；历史行的上下文操作通过 “More actions” 按钮打开同类 popover。关闭隐藏后保留原生菜单。选择菜单动作后自动关闭。
- SwiftUI popover 的内容安装到真实宿主窗口时应用策略，并在绘制前再次应用，避免只保护主窗口。信息 popover 和快速切换列表也采用这一入口。
- 移除 pane 的 `.stationary`，保留 `.canJoinAllSpaces` / `.fullScreenAuxiliary`，明确设置 `hidesOnDeactivate=false`。保留 pane 不能成为 key/main window 的行为，不增加键盘拦截或私有焦点接口。
- 设置说明改为兼容性请求，去掉无条件防捕获承诺。

Natively 参考范围：[状态恢复](https://github.com/Natively-AI-assistant/natively-cluely-ai-assistant/blob/e3258110af05b85b8b0834722bfce369ba4118e4/electron/utils/stealthProtection.ts)、[tooltip 问题](https://github.com/Natively-AI-assistant/natively-cluely-ai-assistant/blob/e3258110af05b85b8b0834722bfce369ba4118e4/src/lib/nativeTooltipGuard.mjs)、[窗口属性](https://github.com/Natively-AI-assistant/natively-cluely-ai-assistant/blob/e3258110af05b85b8b0834722bfce369ba4118e4/native-module/src/stealth_window.rs)。未引入它的 Electron/Rust 实现、进程伪装、全局键盘捕获或私有 API。

## 自动验证

以下构建与测试针对当前工作区，包含本轮开始前已有、尚未提交的提示词及推理参数修改。本轮隐私提交不包含这些原有修改。

Debug 完整测试：**236 项，0 失败，3 项 opt-in 集成测试跳过**。新增 8 项测试，使用真实 NSWindow / NSPopover，覆盖：

1. 设置变化同步已存在、隐藏和后创建的窗口。
2. 子窗口的保护及关闭隐藏后的还原。
3. 偏好设置不变时，窗口/激活/Space/唤醒事件修复被重置的属性。
4. AppKit 创建的窗口在更新时被纳入管理。
5. 内容附着窗口时，在显示前应用保护，且附着视图不拦截点击。
6. 弱注册表不延长已关闭窗口生命周期。
7. **真实 NSPopover 的首次内容绘制时，宿主窗口已为 `.none`。** 这是属性时序验证，不是外部捕获的像素验证。
8. 策略应用不激活 app、不替换 key window；pane 保持跨 Space / 全屏辅助属性。

最终测试结果：`/private/tmp/voxnotch-privacy-final-tests-3.xcresult`。Release 优化构建通过，结果见 `/private/tmp/voxnotch-privacy-final-release.log`。一次并发运行曾遇到 Xcode build database lock，之后按顺序重跑完整测试通过。

## 本机 UI 验证

使用本轮 Debug 构建的独立副本 `com.jingyuanliang.VoxNotch.PrivacyValidation`、独立数据目录与合成会话，不启动真实转写或 AI 请求。

- 隐藏模式下模板菜单成功打开，选择 Coding Interview 后更新选中模板并关闭菜单。
- 设备菜单显示设备与开关动作；只打开后取消，未切换设备或音频状态。
- 进入专用 Chrome `about:blank` 窗口的 macOS 原生全屏 Space 后，pane 和模板 popover 仍在屏幕上，菜单仍可操作。退出全屏后继续存在。
- 窗口记录中 pane 为 `648×488`，模板 popover 为 `306×179`，两者 alpha 为 1、on-screen 为 true。未观察到空菜单或只剩很小的滚动区域。
- 上述交互验证后增加了显示入口的显式 prepare 和信息按钮辅助功能调整；最终自动测试及 Release 构建覆盖这两处调整。

本机证据目录：`/private/tmp/voxnotch-privacy-validation-opjsvpq9/`。`template-popover-windows.json`、`fullscreen-space-windows.json` 和 `validation-manifest.json` 保留窗口记录与副本 hash；临时文件可能被系统清理。WindowServer 的 sharing state 不单独作为防捕获通过证据。

## 本轮 Meet 验证未形成有效结论

再次打开同机两个 Meet 会话，Companion 发送原始 Entire Screen、普通会话接收，系统音频关闭、摄像头和麦克风未开启。开启隐藏时曾看到正常更新的接收视频；但切换全屏 Space、打开设置之后，关闭隐藏的对照未得到可用的接收视频。电脑控制工具随后连续超时，用户手动停止共享。

**本轮不计 Meet 隐藏通过，也不计隐藏失败：没有有效的关闭保护阳性对照。** `meet-initial-protected.png` 只是初始观察；`meet-hide-off.png` 误取到了另一个 Chrome 窗口，`meet-hide-off-receiver.png` 是空白接收画面，都不能支持通过。上一次 [Meet 对照](google-meet-screen-share-validation-2026-10-23.md) 是改进前构建的历史记录，不能替代本轮验证。

本轮尚未完成新构建的独立接收设备验证、悬停提示捕获验收、拖动缩放期间的泄漏帧检查或其他会议软件兼容矩阵。已清理隔离测试进程和其偏好设置，未撤销用户授予 Chrome 的权限。未确认剩余 Meet 标签页是否已退出，不继续操作用户正在使用的 Chrome。

## 保护边界

这些改动提高了窗口策略的一致性，**没有改变 Apple 对 `.none` 的支持边界**，也不能把同一属性反复应用变成通用防捕获保证。系统菜单、系统/XPC 管理的对话框及第三方组件生成的临时 UI 仍需分别进行接收端验证。它们不能因为主 pane 的标记正确，就被视为已经通过。[Apple 文档](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none)。
