# KoKo iOS functional test cases

This is the release-facing functional catalog for KoKo on physical iPhones. It
covers SSH and RunEverything features. Agent-side desktop protocol details and
lower-level negative tests remain in
`RunEverything/docs/remote-desktop-test-cases.md`.

## 1. Conventions

- **Devices:** `Air` = iPhone Air; `14PM` = iPhone 14 Pro Max class device.
- **Paths:** `LAN` = UDP PreferDirect; `UDP-R` = UDP Relay; `WSS` = WSS Relay;
  `Cell` = phone on cellular with LAN stripped.
- **Automation:** `Matrix` = `ios/scripts/re2-device-e2e-matrix.sh`; `XCTest` =
  repeatable host/simulator test; `Manual` = human observation or interaction.
- **Priority:** P0 blocks release, P1 is core regression coverage, P2 is
  scheduled/feature coverage.
- A case is not passed by UI state alone when it has a result JSON or host-side
  observable. Collect the evidence listed in section 16.

## 2. Common prerequisites

1. Build KoKo with Xcode 27.1 beta and install the same build on Air and 14PM.
2. Install a personally signed RunEverything Agent and launch it through
   LaunchServices. Record KoKo build, Agent build, macOS version, device model
   and iOS version.
3. Grant only the permissions required by the case. Start permission-negative
   cases from a known denied/reset state.
4. Prepare one reachable SSH host, one unreachable address, key and password
   accounts, and a host with enough scrollback output.
5. Prepare RunEverything pairing data for LAN and public relay. For stored
   reconnect cases, complete one successful pairing before disconnecting.
6. For IDE cases, keep a Cursor project open with the current IDE bridge
   registered. Prepare one existing composer/chat ID and a disposable branch.
7. For display cases, provide a primary display plus a distinct secondary or
   `RE_VDISPLAY=8k`. For audio/file/clipboard cases, prepare recognizable
   fixtures and checksums.
8. Never run takeover, gesture, clipboard, file-write or IDE mutation cases
   against a host containing unsaved user work.

## 3. Required execution matrix

### Release gate

- Air: P0 cases on LAN, WSS and UDP-R.
- 14PM: P0 cases on LAN and Cell; cellular uses `stripLAN=true`, with UDP-R
  preferred and WSS fallback recorded.
- Both phones: SSH smoke, stored reconnect, lifecycle resume, PiP, one complete
  gesture pass, and one complete IDE action pass.
- Run P1 on at least one phone per release and rotate the phone each release.
- P2 runs for feature releases or when its subsystem changes.

### Matrix script cases

- Safe unattended `all`: `lan`, `wss`, `udp-relay`, `life`, `weak-relay`,
  `data-chat`.
- Explicit prerequisites: `external-life`, `display-switch`,
  `stored-reconnect`, and `IDE_CHAT_ID=<id> ... ide-chat`.
- Input/special hardware cases remain explicit: `gestures*`, `pip*`, `5k*`.

## 4. App shell and host management

### KFT-SHELL-001 — First launch and navigation (P0, Manual, Air+14PM)
- **Steps:** Cold launch; open Hosts, Sessions, Settings and return to the
  starting tab.
- **Expected:** No blank root, clipped primary controls or unexpected modal;
  selected tab and navigation stack are coherent after rotation.

### KFT-SHELL-002 — Compact and large layouts (P1, Manual, Air+14PM)
- **Steps:** Exercise portrait/landscape and any supported large/hinged layout;
  open SSH and desktop content.
- **Expected:** Safe areas, sidebars, keyboard and bottom controls do not cover
  content. A layout transition does not disconnect a session.

### KFT-HOST-001 — Create, edit and delete host (P0, Manual, Air)
- **Steps:** Add an SSH host with label, address, port and auth; edit each
  field; delete with confirmation.
- **Expected:** Values persist, edits affect the next connection, and deletion
  removes only the selected host and associated UI references.

### KFT-HOST-002 — Secret persistence boundary (P1, XCTest+Manual, Air)
- **Steps:** Save password/key-backed hosts; relaunch; inspect exported/UI
  models without exposing Keychain.
- **Expected:** Secrets reconnect successfully but never appear in logs,
  screenshots, copied diagnostics or plain preferences.

## 5. SSH

### KFT-SSH-001 — Password connect (P0, Manual, Air+14PM, Wi-Fi+Cell)
- **Steps:** Connect with valid password, run `printf koko`, disconnect and
  reconnect.
- **Expected:** Prompt becomes interactive, output is exact, status transitions
  are accurate, and reconnect creates one usable terminal.

### KFT-SSH-002 — Key authentication variants (P0, Manual, Air)
- **Steps:** Connect using generated/imported Ed25519; repeat with supported
  ECDSA/RSA key.
- **Expected:** Correct key succeeds without password fallback; unsupported or
  wrong key reports an actionable authentication error.

### KFT-SSH-003 — Host-key trust lifecycle (P0, XCTest+Manual, Air)
- **Steps:** Connect to a new host, accept its fingerprint, reconnect, then
  change the server key.
- **Expected:** First-use confirmation is explicit; unchanged key reconnects;
  changed key is blocked and clearly distinguished from network/auth failure.

### KFT-SSH-004 — Terminal input, resize and Unicode (P0, Manual, Air+14PM)
- **Steps:** Type ASCII, emoji, CJK and control keys; rotate and show/hide the
  keyboard; run `stty size`.
- **Expected:** Text is not duplicated/corrupted, control keys work, PTY size
  follows the visible terminal and cursor remains visible.

### KFT-SSH-005 — Scrollback and concurrent sessions (P1, Manual, 14PM)
- **Steps:** Generate long output, scroll while output continues, then open
  multiple sessions and switch rapidly.
- **Expected:** Scroll position is stable, bounded history restores, session
  identity/output never crosses tabs, and closing one does not close another.

### KFT-SSH-006 — Failure recovery (P0, Manual, Air)
- **Steps:** Try bad DNS, refused port, timeout and wrong credentials; correct
  the configuration and retry.
- **Expected:** Failure categories are understandable, UI does not spin
  forever, and retry succeeds without recreating the host.

## 6. Pairing, paths and desktop video

### KFT-DESK-001 — Pair and first frame (P0, Matrix `lan`, Air+14PM, LAN)
- **Steps:** Pair, open desktop and observe through sustained painting.
- **Expected:** Pair/bind/Noise completes, desktop reaches streaming, decoded
  frame epoch advances, chrome and path label agree with UDP·LAN.

### KFT-DESK-002 — Relay paths (P0, Matrix `wss`+`udp-relay`, Air)
- **Steps:** Force each relay transport independently.
- **Expected:** WSS reports WSS·Relay; UDP-R reports UDP·Relay; both paint,
  remain interactive and satisfy path/result gates.

### KFT-DESK-003 — Cellular path selection (P0, Matrix `udp-relay`, 14PM, Cell)
- **Steps:** Disable Wi-Fi, set `stripLAN=true` and `forceUDP=true`, connect;
  separately force WSS.
- **Expected:** No private-LAN attempt stalls the connection; UDP-R is preferred
  and WSS works as fallback. Evidence records carrier/path, not just “online.”

### KFT-DESK-004 — Quality and freeze recovery (P0, Matrix `lan`+`wss`, Air)
- **Steps:** Run quality matrix, introduce a brief path interruption and
  request a keyframe. On WSS, separately make soft video reopen and Noise
  recovery fail while keeping the saved pairing valid.
- **Expected:** Each selected quality paints and continues, no stale-size frame
  persists, and the last frame remains visible during recovery. Exhausting
  video-only recovery automatically performs a full BIND→Noise→OPEN reconnect;
  the user does not have to leave and re-enter the viewer.

### KFT-DESK-005 — Desktop chrome and controls (P0, Matrix, Air+14PM)
- **Steps:** Enter/exit viewer; reveal controls; use reconnect and disconnect.
- **Expected:** Viewer controls are reachable on both devices, status/path/
  quality text is current, and disconnect returns to a usable host list.

## 7. Gestures and keyboard

### KFT-GEST-001 — Tap, double tap and right click (P0, Matrix `gestures`, Air)
- **Steps:** Target a disposable desktop control with each gesture.
- **Expected:** Exactly the intended left/double/right action occurs; remote
  cursor feedback matches the target and no click remains held.

### KFT-GEST-002 — Hold-drag and one-finger slide (P0, Matrix, Air+14PM)
- **Steps:** Drag a disposable window/selection; perform trackpad-style slide.
- **Expected:** Down/move/up sequence is complete, movement is smooth enough to
  control, and cancel/background releases all buttons.

### KFT-GEST-003 — Vertical/horizontal scroll and pinch (P1, Matrix, Air)
- **Steps:** Scroll a two-axis document while deliberately varying finger
  spacing by 3–8%; then perform a deliberate pinch whose centroid drifts.
- **Expected:** Axis and direction are correct; pinch affects host content and
  does not accidentally navigate KoKo. Each touch sequence locks to one intent:
  spacing drift during scroll never zooms, and centroid drift during pinch
  never scrolls the remote document.

### KFT-GEST-004 — Spaces and Mission Control (P0, Matrix, 14PM)
- **Steps:** Three-finger left/right and up/down gestures.
- **Expected:** Host changes Space/overview as intended and desktop video keeps
  painting throughout and afterward.

### KFT-GEST-005 — Keyboard and modifiers (P1, Manual, Air+14PM)
- **Steps:** Enter CJK/ASCII; test Command/Ctrl/Option/Shift combinations and
  dismiss the software keyboard.
- **Expected:** Text and modifiers arrive once, no modifier remains stuck, and
  keyboard presentation does not hide required controls.

## 8. PiP and lifecycle

### KFT-PIP-001 — Enter, remain and restore (P0, Matrix `pip`, Air+14PM)
- **Steps:** Start streaming, enter PiP, switch apps for 30 seconds, return.
- **Expected:** PiP starts with live/recoverable video, controls remain valid,
  return restores the same session and `pipOK=true`.

### KFT-PIP-002 — PiP on relay and interruption (P1, Matrix `pip-relay`, 14PM)
- **Steps:** Enter PiP over UDP-R, lock/unlock or briefly interrupt the network.
- **Expected:** No crash or orphan PiP; the session either resumes with a fresh
  keyframe or exposes a clear reconnect action.

### KFT-LIFE-001 — Soft background resume (P0, Matrix
`life`/`cellular-life`, Air+14PM)
- **Steps:** Let the harness invoke session background/foreground handling.
- **Expected:** Existing session resumes painting automatically and
  `lifeBackground=true`; a manual reconnect must not hide failure.

### KFT-LIFE-002 — Real scene transition (P0, Matrix `external-life`, 14PM)
- **Steps:** While streaming, harness foregrounds Settings, waits, then returns
  to KoKo.
- **Expected:** Real app lifecycle callbacks suspend/recover cleanly; result
  records `externalLife=true` and post-return painting.

### KFT-LIFE-003 — Cold termination and stored reconnect (P0, Matrix
`stored-reconnect`, Air+14PM)
- **Steps:** Complete pairing, terminate KoKo, relaunch, reconnect without
  injecting a new pair.
- **Expected:** Stored profile is used (`stored=true`), secrets remain
  available, current transport is renegotiated and video paints.

## 9. Displays

### KFT-DISP-001 — Enumerate and switch displays (P0, Matrix
`display-switch`, Air)
- **Steps:** Refresh displays, switch primary→virtual/secondary→primary.
- **Expected:** Distinct IDs/names are listed; each switch confirms the target
  and advances frame epoch with the correct desktop geometry.

### KFT-DISP-002 — High-resolution display (P1, Matrix `5k`/`5k-relay`, Air)
- **Steps:** Select a real ≥5K display on LAN and UDP-R.
- **Expected:** Negotiated and decoded dimensions meet the 5K gate or produce a
  clear prerequisite failure; Agent and phone remain responsive.

### KFT-DISP-003 — Rotation and coordinate mapping (P1, Manual, Air+14PM)
- **Steps:** Rotate the phone after selecting each display; click all four host
  corners.
- **Expected:** Aspect fit/crop is stable and input maps to the selected
  display, not the primary or previous display.

## 10. Clipboard, files and audio

### KFT-DATA-001 — Clipboard text both directions (P0, Matrix `lan`, Air)
- **Steps:** Push unique Unicode text phone→host, then host→phone.
- **Expected:** Exact text arrives once, with no silent overwrite of unrelated
  clipboard data; result/menu evidence marks clipboard success.

### KFT-DATA-002 — Clipboard image and limits (P2, Manual, Air)
- **Steps:** Copy a small PNG each direction, then exceed the documented limit.
- **Expected:** Small image is usable; oversized content fails explicitly
  without disconnecting desktop/data channels.

### KFT-FILE-001 — Upload and download (P0, Matrix `lan`+`wss`, Air)
- **Steps:** Transfer fixtures each direction and compare SHA-256.
- **Expected:** Names, bytes and checksums match, progress completes and
  `filePushOK`/`filePullOK` are true.

### KFT-FILE-002 — Resume, cancel and path safety (P1, Manual+Go tests, Air)
- **Steps:** Interrupt a large transfer, resume, cancel another, and request a
  `../` path.
- **Expected:** Resume does not duplicate bytes, cancel cleans partial state,
  and traversal is rejected without leaking host files.

### KFT-AUD-001 — Mute/unmute and route changes (P1, Manual, Air+14PM)
- **Steps:** Play identifiable host audio; toggle mute; connect/disconnect
  headphones and change volume.
- **Expected:** Audio follows mute/route state, reconnect does not duplicate
  streams, and desktop remains smooth.

### KFT-AUD-002 — Permission denied/interruption (P1, Manual, Air)
- **Steps:** Deny required audio permission; then test call/Siri interruption.
- **Expected:** UI reports unavailable audio without blocking video; after the
  interruption or permission grant, audio can recover.

## 11. Data channel and takeover

### KFT-DATA-003 — Desktop plus independent chat data channel (P0, Matrix
`data-chat`/`cellular-data-chat`, Air+14PM, LAN+UDP-R)
- **Steps:** Stream desktop while listing Agent/IDE chats through the data
  tunnel.
- **Expected:** Tunnel reports `separate=true`, list succeeds, desktop frame
  epoch advances during the probe and `chatOK=true`.

### KFT-TAKE-001 — Second-phone takeover (P0, Manual, Air+14PM)
- **Steps:** Air controls host; 14PM attempts stored reconnect without force,
  then confirms forced takeover.
- **Expected:** Initial attempt receives busy with Air identified; after
  confirmation 14PM controls, Air receives superseded and does not auto-fight
  for ownership. Only one phone injects input.

### KFT-TAKE-002 — Same-client reconnect (P1, Manual, each phone)
- **Steps:** Briefly drop and restore the active phone’s network.
- **Expected:** Same client reconnects without a takeover prompt; stale
  controller state is released after timeout.

## 12. IDE chat and queue actions

### KFT-IDE-001 — Stored IDE chat lifecycle (P0, Matrix `ide-chat`, Air)
- **Steps:** Set `IDE_CHAT_ID` to an existing composer and run open, reconnect,
  disconnect+reconnect, close+reopen.
- **Expected:** Every step receives fresh full history, is connected, has
  messages and reports `ideChat.ok=true`.

### KFT-IDE-002 — Queue add, edit, delete and send now (P0, Manual, Air+14PM)
- **Steps:** While one request runs, queue two uniquely named prompts; edit one,
  delete the other, then choose Send now.
- **Expected:** Order and edited text match the phone, delete is reflected in
  Cursor, Send now advances exactly the selected prompt, and no duplicate
  pending bubble remains after bridge acknowledgement.

### KFT-IDE-003 — Fork (P0, Manual, Air)
- **Steps:** Fork from a known assistant message and submit a distinct prompt.
- **Expected:** New branch starts from the selected point, original history is
  unchanged, and subsequent updates stay in the selected branch.

### KFT-IDE-004 — Keep and Undo (P0, Manual, Air+14PM)
- **Steps:** Produce a disposable file change; Keep it. Produce a second change;
  Undo it.
- **Expected:** Keep removes pending-review state while retaining disk changes;
  Undo reverts only the targeted change and both phone/Cursor views converge.

### KFT-IDE-005 — Stop main and child agents (P0, Manual, Air)
- **Steps:** Start a long task that launches child work; press Stop once.
- **Expected:** Main and child activity cease, UI leaves running state, queue
  remains consistent and no delayed child result mutates files afterward.

### KFT-IDE-006 — Offline queue convergence (P1, Manual, 14PM, Cell)
- **Steps:** Queue/edit while connectivity flaps, restore connectivity and
  reopen the same chat.
- **Expected:** Locally pending content is neither lost nor duplicated; bridge
  canonical history replaces acknowledged pending items.

## 13. Permissions, privacy and errors

### KFT-PERM-001 — Screen Recording denied (P0, Manual, Air)
- **Steps:** Revoke host Screen Recording and open desktop.
- **Expected:** No false streaming success; both host and phone explain the
  required permission and retry works after granting it.

### KFT-PERM-002 — Accessibility denied (P0, Manual, Air)
- **Steps:** Allow capture but deny Accessibility; attempt gestures/keyboard.
- **Expected:** Viewing works, input failure is explicit, and no action is
  reported successful merely because a packet was sent.

### KFT-PERM-003 — iOS local network/photo/file/audio permission states (P1,
Manual, Air+14PM)
- **Steps:** Test deny, limited (where supported) and grant; relaunch after each.
- **Expected:** Each dependent feature degrades independently, Settings
  guidance is accurate and relay/SSH functions unrelated to the permission
  remain usable.

### KFT-PRIV-001 — Privacy blank on/off (P0, Matrix menu, Air)
- **Steps:** Enable privacy blank, verify host state, disable it.
- **Expected:** Phone remains controllable as designed, host privacy state
  matches control, and normal painting returns without reconnect.

### KFT-ERR-001 — Expired pair and offline Agent (P0, Manual, Air)
- **Steps:** Use expired/tampered pairing, then stop the Agent and retry.
- **Expected:** Security and offline failures are differentiated; neither loops
  indefinitely or destroys a valid stored profile.

## 14. Long-run and recovery

### KFT-SOAK-001 — Two-hour mixed session (P1, Manual+metrics, 14PM)
- **Steps:** Alternate desktop, PiP, audio, clipboard, files and IDE chat over
  two hours with one network transition.
- **Expected:** No crash, runaway memory/thermal condition, stuck ownership or
  permanent frame freeze; final reconnect succeeds.

### KFT-REC-001 — Agent restart and stale endpoint recovery (P0, Manual, Air)
- **Steps:** Restart Agent during a stored session so its UDP endpoint changes;
  reconnect through relay.
- **Expected:** Client does not trust stale LAN/UDP indefinitely; it negotiates
  a working path or requests a fresh pair with a clear reason.

## 15. Automation mapping and pass rules

- `lan`, `wss`, `udp-relay`: KFT-DESK-001..005 and menu data assertions.
- `life`, `cellular-life`, `external-life`, `stored-reconnect`:
  KFT-LIFE-001..003.
- `display-switch`, `5k*`: KFT-DISP-001..002.
- `data-chat`, `cellular-data-chat`: KFT-DATA-003.
- `ide-chat`: KFT-IDE-001; the mutation cases remain manual because they alter
  a live IDE queue/files.
- `gestures*`: KFT-GEST-001..004; host logs are required to prove button-up,
  axis and Space actions.
- `pip*`: KFT-PIP-001..002.

An automated case passes only when its strict result gate passes. A timeout,
missing prerequisite, stale result marker, wrong path, or absent evidence is
Fail/Blocked, never Pass. Record Blocked separately from product failure.

## 16. Evidence package

Create one timestamped evidence directory per run and include:

1. `run.md`: date/time/time zone, tester, case IDs, result, device/model/iOS,
   KoKo commit/build, Agent commit/version, host OS, selected display and
   permission state.
2. Network facts: requested path, observed final path, Wi-Fi/cellular state,
   relay region and any deliberate impairment. Do not include tokens.
3. Automation: exact command, sanitized request JSON,
   `re2-e2e-result.json`, device console and matching Agent log window.
4. SSH: terminal screenshot or transcript with host/user/address and secrets
   redacted.
5. Desktop/gesture/PiP/display: before/after screenshot or short recording plus
   result fields (`frameEpoch`, dimensions, path, gesture/PiP/display gates).
6. File/clipboard/audio: fixture names, sizes, SHA-256 for files, exact
   clipboard sentinel and audio route/permission state.
7. IDE: composer ID prefix, bridge version, action timestamps, queue/history
   before/after screenshots, and disposable Git diff for Keep/Undo. Redact
   prompts or source that cannot be shared.
8. Takeover/lifecycle: synchronized evidence from both phones and Agent audit
   entries showing controller transition or reconnect.
9. Failure evidence: first error, complete relevant logs, reproduction count
   and whether retry/relaunch changed the outcome. Never attach pairing tokens,
   passwords, private keys, cookies or unredacted home paths.

Minimal record:

```text
Case ID:
Result: Pass | Fail | Blocked
Device / iOS:
KoKo / Agent build:
Path / network:
Prerequisite state:
Steps actually run:
Expected / observed:
Evidence files:
Issue link:
```
