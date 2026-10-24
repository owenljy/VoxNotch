# Always-On TODO（交接文档）

最后更新：2026-10-24。这份文档给接手的 agent 用，读完不需要翻聊天记录。条目按优先级排列：**P0 发版阻塞 → P1 面试致命问题 → P2 安全 → P3 产品改进**。完成一条就勾掉，并在条目下补一行「完成于 commit xxx」。

## 0. 先读这些

### 产品目标
用户主要在**直播 coding 面试（LeetCode 风格）**和 **AI Engineer 的 RRK 面试**里使用 Always-On。需求优先级如下：

1. **共享屏幕时优先隐藏窗口，保护回答内容。** 用户已接受：如果 `.none` 被捕获方忽略，可以退化为 CGS 灰块打码。会话中不主动触发系统权限弹窗。捕获保护仍是 best effort，不能保证所有捕获方都遵守。
2. **极低延迟**
3. **体验好**

### 当前状态
- 本次准备发布 **v0.5.3（build 10）**，包含 v0.5.1 之后的全部改动。发布结果以 GitHub Release 和 Actions 为准。v0.5.2 首次尝试因 AppKit 的 sharingType 读回值与恢复请求不一致而使 4 个断言失败，未发布安装包；v0.5.3 改为记录真实 setter 请求，并隔离 AI 服务测试与本机钥匙串状态，保留失败 tag。
- 已包含会话权限预检查（`69f7b3c`）、固定证书签名（`54f20a4`）、首字超时/备用模型及预加载（`bf1d9e0`）、CGS 刷新修复（`ce55255`）和 SwiftUI 像素验证（`335695c`）。
- macOS 27.0.1 全量测试（含 CI 修复）：**297 项，0 失败，5 项条件测试跳过**。显示器恢复后的窗口/像素复测：**两轮共 32 项，0 失败、0 跳过**。此前 Release 构建通过。CI 修复后的补充像素复测因新测试宿主缺少录屏权限跳过；捕获实现未改动，以上两轮像素结果来自此前已授权构建。

### 关键文件
| 区域 | 文件 |
|---|---|
| 会话编排 | `VoxNotch/Services/AlwaysOn/AlwaysOnController.swift`（启停、暂停、开关音频源、切换麦克风、全局快捷键 `AlwaysOnShortcuts`） |
| 流式转录 | `LiveTranscriber.swift`（VAD 切块 → Parakeet v2，final 优先，丢弃过期的 partial）、`UtteranceSegmenter.swift`、`EchoFilter.swift` |
| 状态 | `VoxNotch/App/SubStates/AlwaysOnState.swift` |
| AI | `AssistantService.swift`、`AssistantPromptBuilder.swift`、`AutoTriggerPolicy.swift` / `AutoTriggerCoordinator.swift`、`VoxNotch/Services/LLM/OpenAICompatibleClient.swift` |
| 模板 | `VoxNotch/Models/AssistantPromptTemplate.swift`（Coding Interview、RRK – AI Engineer、Client Meeting、1:1、General，以及误识别对照表 `recognitionHints`） |
| 设置 | `VoxNotch/Managers/AssistantSettings.swift`、`VoxNotch/Views/Settings/Tabs/AlwaysOnTab.swift`、`AIProviderTab.swift`、`PermissionCheckSection.swift` |
| 面板 | `VoxNotch/Notch/AlwaysOn/`（`AlwaysOnPanelController`、`AlwaysOnRootView`、`AnswerPaneView`、`TranscriptPaneView`、`DeviceChip`、`PanelMouseArea`） |
| 权限 | `VoxNotch/Services/AlwaysOn/AlwaysOnPermissions.swift`、`VoxNotch/Services/KeychainStore.swift` |
| Phone View | `MobileCompanionServer.swift`、`MobileCompanionHTTP.swift`、`MobileCompanionPage.swift`、`VoxNotch/Notch/AlwaysOn/MobileCompanionView.swift`，见 `docs/phone-view.md` |
| 共享屏幕隐藏 | `docs/screen-sharing-research-2026-10-23.md`、`docs/window-privacy-hardening-2026-10-23.md`、`docs/google-meet-screen-share-validation-2026-10-23.md` |

### 必须遵守的约定
- **主 target 默认 `@MainActor` 隔离**（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，Swift 6）。需要在后台用的纯值类型和工具，要显式写 `nonisolated`。默认参数里不能引用 `MainActor` 单例，要在 init 内部取值。
- **Always-On 面板永远不会成为 key window**（`.nonactivatingPanel`），以免抢走用户正在用的 app 的焦点。所以面板里的键盘操作只能做成全局组合键：`KeyShortcut` + `AssistantSettings` 持久化 + `ShortcutRecorderField` + 在 `AlwaysOnShortcuts.register()` 里注册，并且必须带 `isActive` 判断。
- **移动和缩放窗口不能用 SwiftUI 的 `DragGesture`。** macOS 上 SwiftUI 的 `.global` 坐标相对于窗口本身，用它挪窗口会形成布局死循环，崩溃信息是「more Update Constraints in Window passes」。要用 `PanelMouseArea`（AppKit 的鼠标事件）。从 SwiftUI 的 action 里改窗口 frame 时，必须用 `applyFrame(deferred: true)`。
- **不要写泛型的 `NSHostingView` 子类。** Swift 6.3 的 Release 优化（`EarlyPerfInliner`）会因此编译崩溃，v0.5.0 就是这样失败的。
- **会话中绝不调用会弹系统窗的 API。** 只能用 `AlwaysOnPermissions` 读取权限状态，钥匙串只能用 `KeychainStore.read(_, interactive: false)`。
- 第三方依赖：Markdown 渲染用 **Textual 0.5**（`StructuredText`），转录用 **FluidAudio**（锁定在某个 revision，Parakeet TDT v2）。

### 构建、测试、演示
```bash
# 和 CI 一样的全量测试
xcodebuild test -project VoxNotch.xcodeproj -scheme VoxNotch -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -disableAutomaticPackageResolution \
  -skipMacroValidation -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO

# 本地运行用的构建（项目里配置的开发证书已失效，所以用临时签名）
xcodebuild ... build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER=""

# 真实模型的延迟基准（需要本地已下载 Parakeet v2 和 Silero）
TEST_RUNNER_VOXNOTCH_LIVE_ASR_TESTS=1 xcodebuild test ... -only-testing:VoxNotchTests/LiveTranscriberBenchmarkTests
```
- **DEBUG 演示参数**（`AlwaysOnDemo.swift`），不需要麦克风和权限：
  - `-alwaysOnDemo YES`：播放一段脚本化的对话。
  - `-alwaysOnDemoAnswers YES`：加上示例 Markdown 回答。
  - `-alwaysOnDemoSnapshots /tmp/dir`：把面板截图存到这个目录。
  - `-settingsSnapshot /tmp/x.png -settingsSnapshotPanel alwaysOn`：截取设置窗口。
  - `-hideFromScreenRecording NO`：只对这次启动生效。
- **数值类参数**要用 plist 写法，例如 `-assistant.panelHeight "<real>820</real>"`。
- 如果用户在 Xcode 里开着 VoxNotch，**不要再启动演示实例**，否则会在用户屏幕上弹出面板，还会和他抢全局快捷键。
- **已知的测量结果：** 说完话约 340ms 拿到完整文本，约 514ms 定稿，问句结束约 415–443ms 自动触发作答。首次编译 CoreML 模型需要 14–20 秒。

---

## P0：发版阻塞

- [x] **P0-1 重新验证 `WindowPrivacyManagerTests` 与关闭保护后的恢复**
  - 已在云端复现旧断言失败，并在独立 NSWindow 探针中确认：设置 `.readOnly` 后 AppKit 仍可能读回 `.none`。单元测试改为记录并验证 setter 请求，同时继续通过独立捕获进程验证画面恢复。
  - 独立进程的 AppKit / SwiftUI 像素测试均验证：关闭保护和快速关闭后，原内容恢复可见。
  - 同时修复共享中启用 CGS 后的旧画面、放大边缘泄漏和关闭后残留灰块。详见 `capture-exclusion-validation-2026-10-24.md`。
  - 完成于 commit `ce55255`、`335695c`；本地 macOS 27 全量测试已通过。

- [ ] **P0-2 发布 v0.5.3，并确认新的签名流程在 CI 上跑通**
  1. 升级版本号：`VoxNotch.xcodeproj/project.pbxproj` 里 Debug 和 Release 两个配置的 `MARKETING_VERSION` 都改成 `0.5.3`，`CURRENT_PROJECT_VERSION` 都改成 `10`。同时更新 `CHANGELOG.md`，以及 `docs/releasing.md` 里的 "Current version"。
  2. CHANGELOG 里要写明：**这是第一个用固定证书签名的版本，从 ad-hoc 版本升级时，macOS 会最后一次重新请求权限。** 同时概括 v0.5.1 之后的新内容：Phone View、iPad 分栏、麦克风校验、回答历史预览、防录屏加固、Coding Interview 模板改进、Reasoning effort、会话中不弹权限。
  3. `git push origin main`，然后推送 tag `v0.5.3`，盯着 `Build & Release` workflow。
  4. **重点检查：** 「Import signing certificate」这一步成功，并且日志里的 `designated => identifier "com.jingyuanliang.VoxNotch" and certificate root = H"a722522038615d41e96104cbe6110d94ead809b4"` 存在。
  5. 下载 DMG，在本机运行 `codesign -d -r- /Volumes/VoxNotch/VoxNotch.app` 复核。
  - **验收：** Release 页面上有 DMG 和 sha256，DR 锁定在这张证书上。

- [ ] **P0-3（需要用户自己做）备份签名证书**
  - `~/VoxNotch-signing/voxnotch-signing.p12` 和 `p12-password.txt` 存进密码管理器。
  - **这张证书永远不能换。** 一旦换掉，所有用户的权限都会被重置一次。背景见 `docs/releasing.md` 的 Signing 一节。
  - GitHub Secrets：`MACOS_SIGNING_CERT_P12`（base64）、`MACOS_SIGNING_CERT_PASSWORD`。

---

## P1：面试致命问题（权限弹窗与共享屏幕）

背景：macOS 的系统权限弹窗是系统进程画的，**没法从屏幕共享里隐藏**，所以只能确保会话中不会触发它。`69f7b3c` 已经做到「会话中不主动请求权限」，下面是剩下的风险。

- [ ] **P1-1 在真机上验证权限门控**（`69f7b3c` 只有单元测试，还没有实际跑过）
  - 在「系统设置 → 隐私与安全性」里关掉 VoxNotch 的屏幕与系统音频录制权限，然后开启 Always-On。预期：没有任何系统弹窗，面板顶部出现「System audio off — permission not granted」，麦克风照常转录。
  - 在 Settings → Always-On → **Before Your Interview** 里点「Run Permission Check」，所有待处理的弹窗应该在这一刻依次出现。
  - 用一个签名不同的构建去读钥匙串里的 API Key（模拟更新后的状态），然后点 Ask。预期：不弹窗，AI 栏显示「macOS needs your approval…」；在权限检查里点 Approve 后恢复正常。
  - 我已经实测确认：**只用 `kSecUseAuthenticationUIFail` 拦不住钥匙串弹窗**，必须配合 `SecKeychainSetUserInteractionAllowed(false)`。具体实现见 `KeychainStore.read`。

- [ ] **P1-2 系统音频改用 Core Audio 进程音频采集（彻底解决方案）**
  - **问题：** 系统音频现在走 ScreenCaptureKit（`SystemAudioCaptureManager.startStreaming` 会调用 `SCShareableContent`）。macOS 15 及以上会**定期**对这类 app 弹出「是否继续允许录屏」，它可能出现在开启 Always-On、暂停后恢复、重新打开系统音频这三个时刻。B 方案无法阻止这个弹窗。
  - **做法：** 改用 macOS 14.4+ 的 `AudioHardwareCreateProcessTap` + `CATapDescription`（全局系统音频的 tap，排除 VoxNotch 自己的进程），配合聚合设备读取音频。这样只需要「仅录制系统音频」权限：Info.plist 加 `NSAudioCaptureUsageDescription`，权限检查改用对应的 TCC 状态，不再需要录屏权限。
  - **保留回退：** 保留 ScreenCaptureKit 的实现作为回退，加一个隐藏开关可以切回去。
  - **验收：** 在 macOS 27 上，没有录屏权限也能转录系统音频；菜单栏不出现录屏指示；`AlwaysOnPermissions.systemAudioGranted` 和 `PermissionCheckSection` 改为检查新的权限；回声去重和延迟基准没有退化。
  - **需要实测确认：** process tap 是否真的没有定期重新确认的弹窗。

- [ ] **P1-3（如果 P1-2 推迟，先做这个低成本缓解）暂停时不停止系统音频采集**
  - 现在 `togglePause` 会完全停止采集，恢复时要重新调用 `SCShareableContent`，多一次触发弹窗的机会。
  - 改成：暂停时麦克风照旧释放，系统音频的 stream 保持运行，只是不再把样本送进转录。
  - 代价是暂停期间系统录屏指示会一直亮着。这一点需要和用户确认。

- [ ] **P1-4 调查 AppKit 警告「Invalid attempt to open a new transaction during CA commit」/「Entangling fence requested after pre-commit」**
  - 用户在 Xcode 的控制台里看到过。目前没有导致崩溃，但和之前的拖动崩溃属于同一类问题：在一次绘制提交的过程中又改动了窗口。
  - **怀疑点：** `AlwaysOnPanelController.applyFrame`、`TranscriptPaneView` 里 `onChange(revision)` 触发的 `scrollTo`、`onScrollGeometryChange`。
  - **验收：** 拖动、缩放、长时间流式转录时，控制台不再出现这两条警告。

---

## P2：Phone View 安全与正确性（来自 2026-10-24 的代码审查）

已经做对、不需要再改的：
- 只绑定选定的那块网卡，没有用 Bonjour 广播。
- 严格校验请求的 Host 和 Origin，防 DNS rebinding。
- 配对 token 是 256 位，放在 URL fragment 里，用防时序攻击的方式比较。
- 有严格的 CSP。
- 返回的 snapshot 是白名单字段：不含 API Key、prompt 和音频。
- Always-On 停止后服务也停。

- [ ] **P2-1（High）用户需要先做决定：明文 HTTP**
  - **问题：** `MobileCompanionServer.swift:86` 用的是没有 TLS 的 `NWParameters.tcp`。手机每约 400ms 拉取一次，同一个 Wi-Fi 下的人可以抓包拿到 token 和全部转录、回答，而且 token 在关闭之前一直有效。
  - **方案 A：** 自签 TLS。手机浏览器第一次打开会提示不安全，需要手动信任。
  - **方案 B：** 不加 TLS，改成：界面明确提示「只在可信网络使用」、token 定时轮换、绑定第一台连上的设备、显示连接数并支持踢掉其他设备。

- [ ] **P2-2（Medium）关掉 Phone View 后，Mac 面板不会恢复**
  - 配对成功时 `onReady` 会隐藏 Mac 面板。但「Turn Off Phone View」（`MobileCompanionView.swift:74`）和监听失败时，只会隐藏配对窗口（`MobileCompanionServer.swift:45` 的 `onStopped`）。结果是 Always-On 仍在录音，但用户看不到任何面板。
  - **修法：** 在 `onStopped` 里，如果 `AlwaysOnController.shared.isActive`，就调用 `AlwaysOnPanelController.shared.show()`。

- [ ] **P2-3（Medium）网络短暂波动就会拆掉配对**
  - `MobileCompanionServer.swift:107` 把 `.waiting` 和 `.failed` 当成同一种情况，直接停止服务，token 也随之作废，手机需要重新扫码。
  - **修法：** 只在 `.failed` 时停止；`.waiting` 时只更新状态提示。

- [ ] **P2-4（Medium）每次拉取都在主线程做全量编码**
  - 每次请求都在 MainActor 上对完整转录加最多 50 条回答做 JSON 编码并计算 SHA-256（`MobileCompanionServer.swift:155-158`、`MobileCompanionHTTP.swift:73-74`），即使内容没有变化。长会话时会和低延迟路径抢主线程。
  - **修法：** 按 `AlwaysOnState.revision` 和回答的状态缓存编码结果，并把编码移到主线程之外。

- [ ] **P2-5（Medium）第二台设备可以静默围观**
  - `hasConnectedClient` 只会从 false 变成 true 一次，唯一的限制是最多 16 个连接。
  - **修法：** 并入 P2-1 方案 B，显示连接数并支持踢掉其他设备。

- [ ] **P2-6（Low）「Copy Link」会把带 token 的链接放进剪贴板**
  - 位置：`MobileCompanionView.swift:67-69`。剪贴板可能被通用剪贴板或剪贴板管理工具同步到其他设备。
  - **修法：** 加提示，或者 60 秒后自动清空剪贴板（清空前先确认剪贴板里还是这条链接）。

- [ ] **P2-7（Low）`MobileCompanionServer.swift` 里原有的 Swift 6 并发警告**
  - 位置：第 96、116、213、234 行，「reference to captured var 'self' in concurrently-executing code」。

---

## P3：产品改进（按「对面试的价值 ÷ 工作量」排序）

- [ ] **P3-1（M）抓取题目文本**
  - 面试官经常把题目贴在 CoderPad 或 LeetCode 上，而不是读出来，但现在 prompt 只能看到语音转录。
  - **做法：** 加一个全局快捷键：抓取剪贴板，或者在本地用 Vision 对前台窗口做 OCR（gpt-oss 不支持图像输入）。结果作为一个固定的「Problem statement」块放进 `AssistantPromptBuilder.messages`，位置在 transcript 之前，以保持 prompt 前缀稳定。
  - **注意：** 截取前台窗口需要录屏权限。这里同样必须**先检查权限、绝不在会话中弹窗**。

- [ ] **P3-2（S）追问快捷操作和重新生成**
  - 现在 `AssistantAnswer.Trigger` 只有 manual 和 auto 两种，只有失败的回答才有 Retry。
  - **做法：** 加「Optimize / Explain line by line / More edge cases / Shorter / Regenerate」，每个操作在 instruction 里追加一行要求，可以配全局快捷键。
  - 涉及文件：`AnswerPaneView`、`AssistantService.ask`、`AssistantPromptBuilder.instruction`。

- [x] **P3-3（S）首字超时 + 备用模型**
  - 按用户最终要求，默认 **1.5 秒**没有首字就取消并重试一次。Settings → AI Provider → Response timing 可设置超时和备用模型；留空重试原模型。
  - 备用模型复用当前 endpoint / API key，已开始输出后不自动重启回答。
  - 完成于 commit `bf1d9e0`，已合并到 main。

- [x] **P3-4（S）预加载转录模型**
  - 默认在启动时预加载已下载的模型；Settings → Always-On 可开关或手动准备。前台会话与预加载共用准备任务和缓存，内存压力时释放。
  - 预加载不启动采集，也不自动下载缺少的模型。
  - 完成于 commit `bf1d9e0`，已合并到 main。

- [ ] **P3-5（S）补齐全局快捷键**
  - 暂停、清空、See-through、最小化、切换模板。按「必须遵守的约定」里的方式实现。

- [ ] **P3-6（S）显示 token 用量和费用**
  - 发送 `stream_options: {include_usage: true}`，解析返回的 usage chunk。在每条回答、每次会话的历史里显示 token 数和估算费用。
  - 这对全量上下文模式和 Groq Free 版每分钟 8K token 的限额很有用。

- [ ] **P3-7（M）按模板设置自动作答策略**
  - coding 面试长时间讨论时，现在任何问句后的停顿都会自动作答，既费 token，也会把用户正在看的回答换掉。
  - **做法：** 让模板可以选择「只在明确提问时触发」或者「静音后触发」。coding 模板可以只在明确提问，或者面试官说「go ahead and code」时触发。
  - 涉及文件：`AssistantPromptTemplate`、`AutoTriggerPolicy`、`AutoTriggerCoordinator`。

- [ ] **P3-8（需要用户配合）在 gpt-oss-120b 上验证 Coding Interview 模板的效果**
  - 用户现在用的是 Groq 上的 `qwen/qwen3.8-27b`（预览版，价格是 gpt-oss-120b 的 5–6 倍）。建议换成 `openai/gpt-oss-120b`，Reasoning effort 用 Automatic（也就是 low），并升级到 Groq Developer 套餐（每分钟限额从 8K 提高到 250K token）。
  - 用 "implement a trie" 和 "k closest points" 两道题检查：
    - 只用 Python，不问语言；
    - 注释约 6–10 句，说人话，没有 docstring；
    - 不用 LeetCode 的函数名，不提题号；
    - Approach 外行也能看懂；
    - 不提语音识别。
  - 本地 `gemma4` 的测试结果：注释偏多，偶尔会改动接口。需要在 120b 上复测。

- [ ] **P3-9（可选）识别层的词表增强**
  - 用 FluidAudio 的 CTC vocabulary boosting，需要额外约 100MB 模型，并且只能在定稿时运行，会增加约 100–150ms。
  - 它对同音词（trie / try）无效，只适合发音独特的专有名词。所以先确认 LLM 层的纠错（`recognitionHints` 加自定义术语）还不够用，再考虑做。

---

## 附：已经决定、不需要再讨论的

- Always-On 和按住热键的 dictation 互斥。面板默认贴在刘海下方，可以拖动和吸附。只支持英语，转录模型用 Parakeet v2。
- 每次请求发送**完整上下文**（默认 Entire session），并把之前的 AI 回答按时间顺序插入。末尾用 `<latest>` 块聚焦最近 1–2 个还没回答过的问题。
- Coding Interview 模板固定用 Python，注释易懂，Approach 外行能看懂，包含「关键词 → 算法」对照表，绝不提语音识别。
- 签名用固定的自签证书，**不用 Developer ID**（这是用户的选择）。
