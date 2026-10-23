# Google Meet 整屏共享：VoxNotch 本机验证

日期：2026-10-23，Asia/Singapore。

本页记录隐私改进前缓存构建的成功对照。后续窗口隐私改进及本轮未形成有效结论的 Meet 重测，见 [改进与回归记录](window-privacy-hardening-2026-10-23.md)；不能把本页结果当作后续构建已通过的证明。

## 结果

**本次配置下，隐藏开关有效。** 在连续的 Meet 原始整屏共享中，关闭 `Hide from screen recording` 时，接收会话可以清楚看到合成会话 pane 和设置窗口；重新开启后，两者从接收视频中消失，原位置显示底层桌面。接收视频仍随界面操作更新，未观察到替代黑块或明显的窗口轮廓。

本次是同一台 Mac、同一 Chrome profile 内的两个独立 Meet 会话：Companion 会话发送，普通 host 会话接收。**没有使用独立的第二台物理设备，不能据此承诺所有参会者、浏览器或系统版本均不可见。** 本次也没有测量切换瞬间是否存在短暂泄漏帧。

## 环境与隔离

| 项目 | 实测配置 |
| --- | --- |
| macOS | `27.0.1`，build `26A434`，Apple Silicon Mac mini |
| Chrome | `155.0.8059.85`；未应用待重启的浏览器更新 |
| 共享来源 | Chrome 选择 `Entire Screen`；不是标签页或单窗口 |
| 音视频 | 共享系统音频关闭；摄像头关闭，Meet 麦克风未开启 |
| VoxNotch | 本机缓存 Debug `0.5.1 (8)` 的隔离副本；未重新编译当前工作区 |
| 目标内容 | `alwaysOnDemo` 合成会话文本；未点击 Ask，未启动真实转写 |
| 保护机制 | 现有 `NSWindow.sharingType` 的 `.readOnly` / `.none` 切换；未添加 CGS 私有接口 |

测试副本使用独立 bundle ID `com.jingyuanliang.VoxNotch.ScreenShareTest`、独立偏好设置和应用数据目录。只修改副本的 bundle 名称/ID 并重新作临时签名，以避免复用原应用的设置或进程。该副本不能当作当前工作区最新未提交改动的构建验证。

副本可执行文件 SHA-256：`86208482c7622215bc59b7b0c472396f7aacee1d180e6183cc53200dd16eb60d`。

## 对照过程

| 步骤 | 本机状态 | Meet 接收会话观察 |
| --- | --- | --- |
| 初始阳性对照 | 关闭隐藏，显示演示 pane | 合成文本和 `screen-share-test` 标签可见 |
| 保护组 | 隐藏开启；AX 可读到 pane 内容，WindowServer 报告窗口在屏幕上、alpha 为 1 | 权限处理后，接收画面正常更新，未见 pane |
| 连续共享中的反向对照 | 在测试副本 General 设置内点击开关，确认 Value 为 off；不重启 app、不重启共享 | 同一个 pane 和设置窗口重新出现在接收视频中 |
| 连续共享中的再次保护 | 再次点击开关，确认 Value 为 on | pane 和设置窗口再次消失，底层桌面继续可见并更新 |

最终保护状态的窗口元数据：pane window ID `3386`，frame `x=414, y=524, width=648, height=488`，layer `27`，`kCGWindowIsOnscreen=true`，alpha `1`。该项与开关的反向对照一起用于排除“窗口未创建、已关闭或移到屏幕外”的解释。

单独的 `kCGWindowSharingState` 不作为通过依据：早期关闭隐藏的可见阳性对照中，它也被观察为 `0`。最终结论来自实际接收视频和 UI 开关对照。

早期两张保护组截图未计为通过：一张采集时窗口尚未确认就绪，另一张接收视频空白。随后 macOS 的 Chrome 屏幕访问提示由用户授权并手动点击 Allow，重新确认视频可更新，才完成有效对照。电脑控制工具禁止操作承载权限提示的系统进程，没有尝试绕过该限制。

## 证据与复核

原始截图可能含本机其他窗口内容，因此仅保留在本机临时目录，未复制到仓库或上传：

`/private/tmp/voxnotch-meet-validation-o5blp3z6/`

| 文件 | 含义 |
| --- | --- |
| `meet-live-hide-off.png` | 有效反向对照：pane 和设置窗口在接收视频中可见 |
| `meet-live-hide-on.png` | 随后再次开启隐藏：相同位置呈现底层桌面 |
| `meet-protected-live-3.png` | 首次有效保护组的正常接收视频 |
| `settings-hide-on.txt` | UI 开关再次开启的 AX 记录 |
| `final-protected-windows.json` | 最终窗口位置、屏幕可见状态和 PID |
| `validation-manifest.json` | 精确版本、副本可执行文件及截图 SHA-256 |

`meet-protected-receiver-1.png`、`meet-protected-receiver-2.png` 是上述无效/不确定阶段，不用于支持隐藏成功。`local-protected-pane.png` 为本机窗口截图的空白结果，也不作为会议接收证据。

## 范围与清理

本次覆盖浮动演示 pane、设置窗口及共享期间的开关切换。尚未覆盖独立接收设备、系统音频开启、真实流式答案、拖动缩放、子菜单/popover、多显示器、Space 迁移，以及 Safari/Firefox/Zoom/Teams。没有确认此次 Chrome 实际使用的内部捕获后端，不能由结果反推所有 ScreenCaptureKit 流的行为。

测试后已停止屏幕共享、退出两个 Meet 会话并关闭临时 Meet 标签页；已停止隔离测试进程并删除其偏好设置。原 VoxNotch 进程继续运行，原应用设置和用户未提交源码未改动。用户为 Chrome 授予的屏幕访问权限未撤销。本机临时证据目录保留，系统清理临时文件后可能失效。

后续若需要更强的发布声明，应至少补独立第二台设备的接收验证，并完成上述生命周期与音频选项测试；本次不支持“任何会议都绝对看不到”的承诺。
