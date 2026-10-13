# KoKo iOS

KoKo 是一个原生 Universal App，用同一套会话界面管理两类主机：

1. 通过 SSH 连接 Linux/Unix 主机上的 AI CLI；
2. 通过 RunEverything Agent 配对桌面主机，使用远程桌面和独立的 AI 数据通道。

本文按当前源码描述实现，不再只覆盖最早期的 SSH MVP。

## 设备布局

`AdaptiveRootView` 根据 size class、容器宽度和折叠状态选择外壳：

| 设备形态 | 根视图 | 交互 |
|---------|--------|------|
| 普通 iPhone / 折叠外屏 | `PhoneRootView` | Hosts、Sessions、Keys、Settings 四个 Tab |
| Duo 展开 | `DuoRootView` | 跨铰链分栏和多会话槽位 |
| iPad / regular width | `TabletRootView` | 大屏侧栏、管理区和多会话工作区 |

部署目标为 iOS 17，Target 同时包含 iPhone 与 iPad（`TARGETED_DEVICE_FAMILY = 1,2`）。

## SSH 主机链路

### 身份与主机

- 支持 Ed25519、ECDSA P-256/P-384、RSA-2048 密钥。
- 私钥和 SSH 密码保存在 Keychain。
- Host Profile 包含地址、端口、用户、认证方式和多个项目目录。
- 首次连接显示主机指纹供用户确认；之后固定已确认的 host key。
- 可把本机生成的公钥安装到服务器 `authorized_keys`。

### AI 会话

| Agent | 远端保活与恢复 |
|-------|---------------|
| Cursor | `agent persist attach`，或使用会话 ID 执行 `agent persist --resume` |
| Claude | `screen` + `claude --resume` |
| Codex | `screen` + `codex resume` |
| Gemini | `screen` + `gemini --resume` |
| TRAE | `screen` + `traex resume`（或 `traecli`） |
| Qoder | `screen` + `qoder -r <id>` |
| CodeBuddy | `screen` + `codebuddy --resume <id>` |

刷新 Sessions 时，`AgentSessionSync` 通过 SSH 读取上述 Agent 的本地会话元数据，并与 `screen -ls` 中的 `koko-*` 会话合并。SSH 主机**只有终端**：无「客户端」选项，也不会走 `ide-mirror` / `client-mirror`；打开会话后使用 Citadel SSH PTY 和 SwiftTerm；本地滚屏由 `ScrollbackStore` 按会话保存。

当远端缺少 CLI 时，KoKo 会先征求用户同意，再执行对应官方安装命令。除 Cursor 外，多数 Agent 在需要时可通过 apt/dnf/yum/apk 引导安装 npm。登录流程会识别 OAuth URL、需要粘回终端的授权码、Codex device code，以及 TRAE / Qoder / CodeBuddy 的常见登录页域名。

## RunEverything 桌面链路

### 配对与安全

- Hosts 页面可扫描 QR、粘贴配对码或接收 `koko://` deep link。
- 首次配对兑换短期 QR token，成功后保存可重连的 session ticket。
- 可选 Agent access password 保存在 Keychain。
- 控制与媒体会话使用 Noise XXpsk3；客户端固定 Agent static public key。
- 同一台主机被其他控制端占用时，用户可以明确选择接管。

### 连接策略

`RE2DesktopSession` 按当前网络和配对信息选择路径：

1. 同网段时优先直连 `UDP·LAN`；
2. 跨 NAT 时使用公网 `UDP·Relay`；
3. UDP 不可用或恢复场景回退到 `WSS·Relay`；
4. 已保存的候选 Relay 可用于重连故障转移。

`NWPathMonitor` 监听 Wi-Fi、蜂窝和断网变化。App 短暂进入后台时保留连接，长时间后台会软拆除媒体链路，并在回到前台后重新 BIND、Noise 和打开桌面。

### 远程桌面

当前 Viewer 已实现：

- H.264 与 HEVC 解码，Auto/流畅/标清/高清/超清五档和基于链路统计的 ABR；
- 主机多显示器发现、切换以及高分辨率显示器；虚拟显示器需要 Agent 侧 `re-vdisplay` helper；
- 绝对鼠标和相对触控板模式、点击、右键、拖动、双轴滚动；
- 双指缩放画面、三指切换 macOS Space/调度界面；
- 软键盘、硬件键盘与 Ctrl/Alt/Cmd/Shift 组合键；
- 可选主机音频（macOS 需 `RE_AUDIO=1` 与 ffmpeg）、主机摄像头预览，以及通过已安装的虚拟摄像头驱动把 iPhone 摄像头提供给主机；
- 手机剪贴板粘贴到主机；
- 远端文件列表、下载并通过系统 Share Sheet 分享、从 Files 上传；
- 隐私黑屏、请求关键帧、画质切换、P2P 重试和 Wake on LAN；
- 实时显示连接路径、吞吐、编解码和弱网提示。

### AI 数据通道

AI 会话列表和 PTY 不依赖桌面视频流：

- `DesktopSessionHub` 为已配对主机复用或建立独立加密 data channel；
- Sessions 页面把 Agent 上发现的 Cursor、Claude、Codex、Gemini、TRAE、Qoder、CodeBuddy 会话与 SSH 会话合并；
- 列表用 `Agent·客户端` / `Agent·终端` 区分 GUI 客户端与纯 CLI 存储（`source` / `entrypoint` / rollout `originator`）；
- **终端**会话：Agent PTY + 持久化 `screen`（Cursor CLI 仍走 `agent` / `agent persist`，不经过 mirror）；
- **客户端**会话：同一套 `IDEChatView` 气泡页。Cursor IDE composer 走 `ide-mirror`（桥接 + `state.vscdb`，可注入输入、模式/模型等）。Claude / Codex / Gemini / TRAE / Qoder / CodeBuddy 走 `client-mirror`：读取本机 transcript（JSONL/JSON），经 OSC 7788/7790 推送；手机发消息走各 CLI 的 print/resume 子命令。打开前若桌面 App 未运行，Agent 会 `open -ga` 对应客户端（IDE 扩展会话则先唤醒 Cursor / VS Code）。
- 不要把纯 CLI 会话 ID 强行送进 `ide-mirror` / `client-mirror`，否则会立刻 `pty_exit` 并提示「电脑上的这个会话已结束」。

## RunEverything 主机常驻能力

对应的 macOS Agent 已包含：

- 菜单栏配对、状态、配置和权限检查界面；
- Screen Recording、Accessibility、Camera、Microphone 和手机虚拟摄像头权限引导；
- LaunchAgent 登录启动与 `KeepAlive`；
- Agent 运行期间调用 `caffeinate -i -s -m`，阻止空闲/接电系统/磁盘睡眠，但允许显示器关闭和锁屏；
- Relay 断线后的循环重连。

因此 KoKo 不要求 Tailscale 或 macOS Screen Sharing；LAN/公网 Relay 是当前产品链路的一部分。

长期无人值守仍有以下边界：

- 远程桌面需要已经登录的 macOS 图形会话，并要求实际安装、签名和运行的 Agent 获得 Screen Recording 与 Accessibility 权限；
- LaunchAgent 在用户登录后启动，不能绕过 FileVault 登录；
- `caffeinate` 不保证 MacBook 合盖或电池深度睡眠后仍在线；
- KoKo 的 Wake on LAN 由在线 Agent 发往局域网内其他设备，不能唤醒已经睡眠的 Agent 主机；
- 当前桌面控制为单控制器模型，另一台手机连接时需要明确接管；
- 托盘“登录时启动”和安装脚本的后台 `run -no-qr` 是两种 launchd 路径，后者没有菜单栏配对 UI。

当前已补充只读的无人值守状态链路：

- root power daemon 在开机、尚未登录时向 Relay 上报生命周期阶段；
- KoKo 主机列表显示最后心跳、登录阶段、电源/电量和合盖守护状态；
- 登录后 Agent 通过加密 data channel 上报磁盘、温度、TCC、版本及可选 UPS/NUT；
- 断电、恢复供电和低电量事件会进入主机事件记录；连接存活时可触发手机本地通知；
- 生命周期通道不承载画面、键鼠、shell 或系统登录密码，不能绕过 FileVault。

## 构建要求

- macOS 开发机
- iOS 17+ 设备或模拟器
- Xcode 27.1 beta（当前折叠屏/Duo API 所需）
- `xcodegen`

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.1-beta.app/Contents/Developer
cd ios
./scripts/setup.sh
open KoKo.xcodeproj
```

命令行构建：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.1-beta.app/Contents/Developer
xcodebuild -project KoKo.xcodeproj -scheme KoKo \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ./DerivedData \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 build
```

`setup.sh` 获取 SwiftTerm、Citadel、swift-opus，应用本地补丁并通过 XcodeGen 生成工程。设置页“关于 → 版本”显示当前 marketing version 与 build number。

## 主要依赖

| 包 | 用途 | 许可证 |
|----|------|--------|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 终端仿真 | MIT |
| [Citadel](https://github.com/scientific-creative/Citadel) | SSH、PTY、host key 校验 | MIT |
| [swift-opus](https://github.com/alta/swift-opus) | 远程桌面音频解码 | MIT |
