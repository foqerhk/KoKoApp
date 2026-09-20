# KoKo iOS

原生 iPhone / 折叠屏 / iPad SSH 终端，用于连接 Linux 服务器上的 AI Agent（Cursor / Claude / Codex / Gemini）。

大屏布局（iPad 三栏、折叠屏 Duo 双栏）源码在同级 [`../ipad/`](../ipad/) 目录，与 iOS 工程共享 Services / Store / Terminal。

## 要求

- Xcode 16+
- iOS 17+ 设备或模拟器
- 服务器已安装对应 CLI；Cursor 可在连接时征求同意后一键安装
- 非 Cursor Agent 需要 GNU **screen**（`screen -ls` 可用）
- `xcodegen`（`brew install xcodegen`）

## 打开项目

```bash
cd ios
./scripts/setup.sh    # 克隆依赖、打本地 SPM 补丁、生成工程
open KoKo.xcodeproj
```

## 会话模型

| Agent | 远端保活 | 连接命令 |
|-------|----------|----------|
| **Cursor** | `agent persist` | `agent persist attach` / `--resume=` |
| **Claude / Codex / Gemini** | GNU **screen**（`koko-<kind>-<id>`） | `screen -x` 或新建 screen 后启动 CLI |

下拉刷新会话列表时，KoKo 会通过 SSH 读取各 Agent 的本地 session 元数据，并合并 `screen -ls` 中 `koko-*` 会话。

## MVP 链路

1. **密钥** — 生成 Ed25519 / ECDSA / RSA 密钥，公钥添加到服务器 `authorized_keys`
2. **主机** — 配置 SSH 地址、认证方式、项目目录
3. **会话** — 选择 Agent 类型；进入后 SSH + PTY attach
4. **终端** — 本地 scrollback 可滑动查看最近输出（`keepHistoryOnFullscreen` + ScrollbackStore）

## 依赖

| 包 | 用途 | 许可证 |
|----|------|--------|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 终端仿真 | MIT |
| [Citadel](https://github.com/scientific-creative/Citadel) | SSH + PTY | MIT |

## 构建

```bash
cd ios
xcodebuild -project KoKo.xcodeproj -scheme KoKo \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ./DerivedData \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 build
```

设置页 **关于 → 版本** 显示 `v1.0.0.YYYYMMDDHH:mm:ss` 构建时间戳，便于确认是否为最新安装。
