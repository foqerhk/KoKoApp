# KoKo

KoKo is a native iOS client for operating AI coding sessions and remote computers from iPhone and iPad. It supports two host types in one app:

- **SSH hosts** — connect directly to a Linux or Unix server, discover AI CLI conversations, and attach to a real PTY.
- **RunEverything desktops** — pair by QR code with a desktop Agent, then use remote desktop and AI conversations through the same encrypted connection system.

Supported AI tools:

| Agent | SSH host persistence | Paired desktop |
|-------|----------------------|----------------|
| **Cursor** | `agent persist` attach / resume | CLI resume; **client** Cursor IDE composers use `ide-mirror` (native bubbles) |
| **Claude Code** | GNU `screen` + `claude --resume` | CLI `screen`; **client** chats use `client-mirror` from local transcripts |
| **Codex CLI** | GNU `screen` + `codex resume` | same as Claude |
| **Gemini CLI** | GNU `screen` + `gemini --resume` | same as Claude |
| **TRAE** | GNU `screen` + `traex resume` | Codex-style rollouts under `~/.trae/cli`; client mirror + cold-start Trae |
| **Qoder** | GNU `screen` + `qoder -r` | `~/.qoder/projects`; client mirror + cold-start Qoder |
| **CodeBuddy** | GNU `screen` + `codebuddy --resume` | `~/.codebuddy/projects`; client mirror + cold-start CodeBuddy |

## What is implemented

### SSH and AI sessions

- Ed25519, ECDSA P-256/P-384, and RSA-2048 key generation
- Keychain storage for SSH private keys and passwords
- Host profiles, project directories, TOFU host-key confirmation, and public-key installation
- Remote conversation discovery for Cursor, Claude, Codex, Gemini, TRAE, Qoder, and CodeBuddy
- Persistent PTY sessions with attach, reconnect, create, and remote deletion flows
- Real terminal emulation, hardware/software keyboard input, and per-session local scrollback
- Optional AI CLI installation after confirmation, including npm bootstrap on supported Linux distributions
- Login assistance for browser OAuth, terminal authorization codes, and Codex device codes

### Paired remote desktop

- QR/deep-link pairing with an optional Agent access password
- Noise XXpsk3 encrypted sessions with Agent public-key pinning
- Same-LAN direct UDP, public UDP relay, and WSS relay fallback with relay failover
- Automatic recovery across Wi-Fi/cellular changes and app background/foreground transitions
- H.264/HEVC video, selectable Auto/Smooth/Balanced/High/Ultra quality, and adaptive bitrate recovery
- Mouse/trackpad modes, tap/right-click/drag, two-finger scrolling, pinch zoom, Space gestures, and keyboard modifiers
- Multiple-display discovery and switching, including high-resolution displays and optional virtual displays
- Optional host audio, remote camera preview, and using the iPhone camera as a host webcam when its virtual-camera driver is installed
- Clipboard paste, file browsing, download/share, and upload
- Privacy blanking, keyframe refresh, Wake on LAN, controller takeover, and connection-path diagnostics

### Unified conversations

- The Sessions screen merges conversations found through SSH and paired desktop Agents.
- Desktop conversation sync uses a separate encrypted data channel; it does not need an active video stream.
- Session list badges distinguish **client** vs **terminal** (`·客户端` / `·终端`) from each tool’s on-disk origin.
- **Client** chats open in the native bubble UI (`IDEChatView`): Cursor via `ide-mirror`; Claude, Codex, Gemini, TRAE, Qoder, and CodeBuddy via `client-mirror` (OSC 7788/7790 on the Agent PTY). If the desktop app is not running, the Agent starts it before resume.
- **Terminal** chats stay on SwiftTerm (`screen` + CLI resume). CLI-only Cursor IDs are never forced through `ide-mirror`.

## Universal iOS app

One target (`com.foqerhk.koko`) serves:

- compact iPhone and folded phone layouts → `PhoneRootView`
- unfolded Duo layout → `DuoRootView`
- iPad and regular-width layouts → `TabletRootView`

The large-screen shells support side-by-side management and multiple live session slots.

## RunEverything host requirements

- Remote desktop requires a logged-in graphical session plus Screen Recording and Accessibility permission for the installed Agent.
- Login startup and `caffeinate` keep the Agent available during normal operation, but do not bypass FileVault login or guarantee operation while a MacBook lid is closed or the machine enters deep sleep.
- Wake on LAN is sent by the online Agent to another machine on its LAN; it cannot wake the sleeping Agent host itself.
- Desktop control is single-controller. A second controller must explicitly take over the session.
- Host audio, virtual displays, and the iPhone-as-webcam path require their documented Agent-side runtime or helper components.

## Build

KoKo currently requires the local Xcode 27.1 beta toolchain because the source uses the current foldable/Duo APIs.

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.1-beta.app/Contents/Developer
cd ios
./scripts/setup.sh
open KoKo.xcodeproj
```

`setup.sh` fetches the local Swift packages and generates the Xcode project. See [ios/README.md](ios/README.md) for the implemented connection model and development details.

## Dependencies and license

See [ios/THIRD_PARTY_NOTICES.md](ios/THIRD_PARTY_NOTICES.md) for third-party packages and licenses. KoKo application source is provided as-is for study and contribution; add a project `LICENSE` file if you publish a fork.

## Privacy

[Privacy Policy](https://foqerhk.github.io/koko/privacy.html)
