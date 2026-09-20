# KoKo

KoKo is a native iOS SSH terminal for developers who manage AI coding agents on their own Linux servers from iPhone and iPad.

Supported agents (on your server):

| Agent | Remote persistence |
|-------|--------------------|
| **Cursor** | `agent persist` attach / resume |
| **Claude Code** | GNU `screen` (`koko-claude-*`) |
| **Codex CLI** | GNU `screen` (`koko-codex-*`) |
| **Gemini CLI** | GNU `screen` (`koko-gemini-*`) |

## iOS app

```bash
cd ios
chmod +x scripts/setup.sh
./scripts/setup.sh
open KoKo.xcodeproj
```

Run on a physical iPhone or the iOS Simulator (Xcode 16+, iOS 17+). Unfolded foldable iPhones automatically use the **Duo** split layout from `ipad/KoKoPad/Views/`.

## iPad app

```bash
cd ipad
chmod +x scripts/setup.sh
./scripts/setup.sh
open KoKoPad.xcodeproj
```

See [ipad/README.md](ipad/README.md) for tablet vs foldable layout details.

### Highlights

- SSH key generation (Ed25519 / ECDSA / RSA) with Keychain storage
- Host profiles, TOFU host-key confirmation, public-key install helper
- Session list synced from the server (Cursor chats + Claude/Codex/Gemini metadata + live `screen -ls`)
- Real SSH PTY terminal (SwiftTerm + Citadel)
- Local scrollback per session
- Optional one-tap agent CLI install on the server (with consent)
- Agent login assistance (OAuth links / device codes where applicable)

### Dependencies

Swift packages are fetched locally by `ios/scripts/setup.sh` (not vendored in this repo). See [ios/README.md](ios/README.md) and [ios/THIRD_PARTY_NOTICES.md](ios/THIRD_PARTY_NOTICES.md).

## License

See [ios/THIRD_PARTY_NOTICES.md](ios/THIRD_PARTY_NOTICES.md) for third-party licenses. KoKo application source is provided as-is for study and contribution; add a project `LICENSE` file if you publish a fork.

## Privacy

[Privacy Policy](https://foqerhk.github.io/koko/privacy.html)
