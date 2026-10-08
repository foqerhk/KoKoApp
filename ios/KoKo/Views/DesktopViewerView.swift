import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Full remote-desktop viewer: video, cursor, gestures, clipboard, files, displays, stats.
struct DesktopViewerView: View {
    @ObservedObject var session: RE2DesktopSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var keyboardFocused = false
    @State private var showFiles = false
    @State private var showDisplays = false
    @State private var showMoreMenu = false
    @State private var showWOL = false
    @State private var wolMAC = ""
    @State private var importerPresented = false
    @State private var pinchScale: CGFloat = 1
    @State private var pinchAnchorScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var panAtDragStart: CGSize = .zero
    @State private var lastFingerTranslation: CGSize = .zero
    @State private var viewportSize: CGSize = .zero
    @State private var isPinching = false
    /// Debounce three-finger Space swipes (WSS + Mac slide animation).
    @State private var lastSpaceSwipeAt: Date?

    @State private var dragIsViewportPan = false
    @State private var isMouseDragging = false
    /// Arm text-select (mouse-down drag) only after hold ≥200ms then move.
    @State private var oneFingerBeganAt: Date?
    @State private var oneFingerStartNorm: (x: Double, y: Double) = (0.5, 0.5)
    @State private var lastPointerNorm: (x: Double, y: Double) = (0.5, 0.5)
    @State private var stickyCtrl = false
    @State private var stickyAlt = false
    @State private var stickyCmd = false
    @State private var stickyShift = false
    @State private var shareURL: URL?
    /// Camera PiP — separate from desktop gestures (hit-tested only on the window).
    @State private var cameraPipOffset: CGSize = .zero
    @State private var cameraPipScale: CGFloat = 1
    @State private var cameraPipDragOrigin: CGSize = .zero
    @State private var cameraPipScaleOrigin: CGFloat = 1
    @State private var phoneWebcamPipOffset: CGSize = .zero
    @State private var phoneWebcamPipScale: CGFloat = 1
    @State private var phoneWebcamPipDragOrigin: CGSize = .zero
    @State private var phoneWebcamPipScaleOrigin: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Never absorb touches — if the input surface is briefly disabled,
                // hits must fall through rather than die on a black sink.
                Color.black.ignoresSafeArea()
                    .allowsHitTesting(false)

                if let cg = session.frameImage {
                    Image(decorative: cg, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(pinchScale)
                        .offset(panOffset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(session.frameEpoch)
                        .allowsHitTesting(false)
                } else {
                    VStack(spacing: 14) {
                        if session.phase == .failed {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.orange)
                        } else {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                        }
                        Text(session.statusText.isEmpty ? String(localized: "Connecting…") : session.statusText)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        if !session.pathLabel.isEmpty {
                            Text(session.pathLabel)
                                .font(.caption.monospaced())
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        if session.phase == .failed, let err = session.lastError {
                            Text(err)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                        if session.phase == .failed, let hint = session.recoveryHint {
                            Text(hint)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.85))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        if session.phase == .failed, let paired = session.currentPaired, paired.canReconnect {
                            Button(String(localized: "Reconnect")) {
                                Task { try? await session.reconnect(profile: paired) }
                            }
                            .buttonStyle(.borderedProminent)
                        } else if session.phase == .failed {
                            Text(String(localized: "Scan a fresh Agent QR from Hosts to re-pair."))
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.75))
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding()
                }

                // Full-bleed input layer ABOVE the video (and below PiP/cursor).
                // Kept outside the Image branch so a missing/changing CGImage never
                // tears down the UIKit gesture recognizers mid-touch.
                if session.phase == .streaming || session.phase == .openingDesktop,
                   session.frameImage != nil {
                    DesktopInputSurface(
                        onTap: { pt in handleTap(at: pt, in: geo.size) },
                        onLongPress: { pt in handleRightClick(at: pt, in: geo.size) },
                        onOneFinger: { pt, trans, state, selectDrag in
                            handleOneFinger(at: pt, translation: trans, state: state, selectDrag: selectDrag, in: geo.size)
                        },
                        onPinch: { scale, loc, state in
                            switch state {
                            case .began, .changed:
                                applyHostPinch(scale: scale, around: loc, in: geo.size)
                            default:
                                finishHostPinch()
                            }
                        },
                        onTwoFingerScroll: { dx, dy in
                            guard !isPinching else { return }
                            // Match macOS natural trackpad: finger up → content up.
                            let wheel = Int(dy.rounded())
                            let wheelH = Int((-dx).rounded())
                            guard wheel != 0 || wheelH != 0 else { return }
                            session.sendMouse(
                                x: session.cursorX, y: session.cursorY,
                                buttons: 0, move: false, wheel: wheel, wheelH: wheelH
                            )
                        },
                        onThreeFingerSwipe: { swipe in
                            finishHostPinch()
                            // Debounce: WSS RTT + Mac Space animation — a 2nd swipe
                            // within ~0.45s used to strand Dock mid-slide ("卡住").
                            let now = Date()
                            if let last = lastSpaceSwipeAt, now.timeIntervalSince(last) < 0.45 {
                                return
                            }
                            lastSpaceSwipeAt = now
                            switch swipe {
                            case .left, .right:
                                session.sendMouse(
                                    x: session.cursorX, y: session.cursorY,
                                    buttons: 0, move: false,
                                    gesture: "space", spaceDelta: swipe.spaceDelta
                                )
                            case .up, .down:
                                session.sendKey(keyCode: swipe.keyCode, down: true, modifiers: RE2HostKey.Mod.ctrl)
                                session.sendKey(keyCode: swipe.keyCode, down: false, modifiers: RE2HostKey.Mod.ctrl)
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(4)
                    // Modals / sheets sit above; disable only while chrome is up.
                    .allowsHitTesting(!chromeBlocksDesktopInput)
                    .accessibilityIdentifier("desktopInputSurface")
                }

                // Always draw the overlay cursor while we have a desktop size.
                // Never require Agent CURSOR packets (unreliable) or a perfect
                // on-screen transform — after crash/reconnect, leftover pinch/pan
                // used to push the tip off-screen and the glyph vanished entirely
                // while taps still drove the Mac.
                if (session.phase == .streaming || session.phase == .openingDesktop),
                   session.desktopWidth > 0, session.desktopHeight > 0,
                   geo.size.width > 1, geo.size.height > 1 {
                    let raw = cursorScreenPoint(in: geo.size)
                    // Keep a visible tip even when the logical point is panned away.
                    let x = min(max(raw.x, 2), geo.size.width - 2)
                    let y = min(max(raw.y, 2), geo.size.height - 2)
                    cursorGlyph
                        .position(x: x + 6.5, y: y + 10)
                        .zIndex(5)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("desktopCursorOverlay")
                }

                // Weak-net UX: keep last frame (stall concealment); surface hint only.
                if session.phase == .streaming, !session.weakNetHint.isEmpty {
                    VStack {
                        Text(session.weakNetHint)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.orange.opacity(0.85), in: Capsule())
                            .padding(.top, 8)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                }

                // Above DesktopInputSurface so PiP owns its hits; outside = remote gestures.
                if session.cameraOn {
                    FloatingCameraPipWindow(
                        image: session.cameraPreview,
                        title: String(localized: "Remote Camera"),
                        accessibilityID: "remoteCameraPip",
                        placeholder: session.cameraError,
                        anchor: .bottomTrailing,
                        containerSize: geo.size,
                        offset: $cameraPipOffset,
                        scale: $cameraPipScale,
                        dragOrigin: $cameraPipDragOrigin,
                        scaleOrigin: $cameraPipScaleOrigin,
                        onClose: { session.setRemoteCameraEnabled(false) }
                    )
                    .zIndex(10)
                }

                if session.phoneWebcamOn {
                    PhoneWebcamFloatingPipHost(
                        streamer: session.phoneCamera,
                        errorText: session.phoneWebcamError,
                        accessibilityID: "phoneWebcamPip",
                        containerSize: geo.size,
                        offset: $phoneWebcamPipOffset,
                        scale: $phoneWebcamPipScale,
                        dragOrigin: $phoneWebcamPipDragOrigin,
                        scaleOrigin: $phoneWebcamPipScaleOrigin,
                        onFlip: { session.flipPhoneWebcamCamera() },
                        onClose: { session.setPhoneWebcamEnabled(false) }
                    )
                    .zIndex(10)
                }
            }
            .onAppear {
                viewportSize = geo.size
                session.setIdleTimerDisabled(session.phase == .streaming)
            }
            .onChange(of: geo.size) { _, s in viewportSize = s }
            .onChange(of: session.phase) { _, p in
                session.setIdleTimerDisabled(p == .streaming)
                // Session drop / reconnect: clear leftover pinch so the cursor
                // overlay is not left transformed off-screen forever.
                switch p {
                case .idle, .failed, .pairing, .binding, .associating, .handshaking, .reconnecting:
                    // Crash / drop often lands on .reconnecting without tearing the
                    // viewer down — clear leftover pinch/pan or the glyph stays
                    // transformed off-screen while taps still hit the Mac.
                    if isPinching { finishHostPinch() }
                    pinchScale = 1
                    pinchAnchorScale = 1
                    panOffset = .zero
                    session.suspendRemotePointer(false)
                case .streaming, .openingDesktop:
                    session.suspendRemotePointer(false)
                    if isPinching { finishHostPinch() }
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // Full-screen desktop — hide Hosts/Sessions/Keys/Settings tab bar (same as terminal).
        // UIKit hide is required: HostList's RestoreTabBarWhenVisible used to fight
        // SwiftUI-only `.toolbar(.hidden)` and bring the bar back on every refresh.
        .toolbar(.hidden, for: .tabBar)
        .background(HideTabBarWhenVisible())
        .toolbar {
            // Principal (not topBarLeading): a forced-width leading title was overlapping
            // the keyboard/more buttons; allowsHitTesting(false) then sent taps through
            // into the desktop surface — More looked dead and the bar looked empty.
            DesktopNavTitleToolbar(
                name: session.currentPaired?.name ?? String(localized: "Desktop"),
                statusLine: session.navStatusLine,
                showStatus: session.phase == .streaming || session.phase == .openingDesktop,
                maxWidth: max(
                    180,
                    (viewportSize.width > 1 ? viewportSize.width : UIScreen.main.bounds.width) - 44 - 110 - 20
                )
            )
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    keyboardFocused.toggle()
                } label: {
                    Image(systemName: keyboardFocused ? "keyboard.chevron.compact.down" : "keyboard")
                }
                .accessibilityLabel(String(localized: "Virtual Keyboard"))

                Button {
                    showMoreMenu = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(String(localized: "More"))
                .accessibilityIdentifier("desktopMoreButton")
            }
        }
        // Edge-swipe back fights trackpad / pan gestures and drops the session mid-control.
        .background(DisableInteractivePopGesture())
        .navigationBarBackButtonHidden(false)
        .focusable()
        .onKeyPress { press in
            handleHardwareKey(press)
        }
        // Hidden TerminalView + stock TerminalAccessory (same as SSH). No composition strip.
        .background {
            DesktopSoftKeyboard(
                isFocused: $keyboardFocused,
                onText: { text in
                    session.sendKey(text: text, down: true, modifiers: 0)
                    session.sendKey(text: text, down: false, modifiers: 0)
                },
                onKeyCode: { code, mods in
                    session.sendKey(keyCode: code, down: true, modifiers: mods)
                    session.sendKey(keyCode: code, down: false, modifiers: mods)
                }
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .sheet(isPresented: $showMoreMenu) {
            DesktopMoreMenuSheet(
                session: session,
                onPaste: { session.pushLocalClipboard(); showMoreMenu = false },
                onKeyframe: { session.requestKeyframe(); showMoreMenu = false },
                onToggleMouse: {
                    session.setInputMode(game: !session.gameMouseMode)
                    showMoreMenu = false
                },
                onTogglePrivacy: {
                    session.setPrivacyBlank(!session.privacyBlank)
                    showMoreMenu = false
                },
                onToggleAudio: {
                    session.setAudioMuted(!session.audioMuted)
                },
                onToggleCamera: {
                    if session.cameraOn {
                        session.setRemoteCameraEnabled(false)
                    } else {
                        session.setRemoteCameraEnabled(true)
                        showMoreMenu = false // reveal PiP immediately
                    }
                },
                onTogglePhoneWebcam: {
                    if session.phoneWebcamOn {
                        session.setPhoneWebcamEnabled(false)
                    } else {
                        session.setPhoneWebcamEnabled(true)
                        showMoreMenu = false
                    }
                },
                onQuality: { q in
                    session.setVideoQuality(q)
                    showMoreMenu = false
                },
                onDisplays: { showMoreMenu = false; showDisplays = true },
                onFiles: { showMoreMenu = false; showFiles = true },
                onUpload: { showMoreMenu = false; importerPresented = true },
                onRetryP2P: { session.retryLANOrP2P(); showMoreMenu = false },
                onWOL: { showMoreMenu = false; showWOL = true },
                onDisconnect: {
                    showMoreMenu = false
                    session.disconnect(userInitiated: true)
                    dismiss()
                },
                onClose: { showMoreMenu = false }
            )
        }
        .sheet(isPresented: $showFiles) {
            DesktopFilesSheet(session: session)
        }
        .sheet(isPresented: $showDisplays) {
            NavigationStack {
                List(session.displays) { d in
                    Button {
                        // Dismiss after kickoff so the viewer can show
                        // "Switching display…" (needs frameImage cleared).
                        session.selectDisplay(d.displayID)
                        showDisplays = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.name)
                                Text("\(d.width)×\(d.height)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if d.displayID == session.selectedDisplayID {
                                Image(systemName: "checkmark")
                            }
                            if d.primary {
                                Text(String(localized: "Primary"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(session.phase == .openingDesktop)
                }
                .navigationTitle(String(localized: "Displays"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Done")) { showDisplays = false }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(String(localized: "Refresh")) { session.refreshDisplays() }
                    }
                }
                .onAppear { session.refreshDisplays() }
            }
        }
        .alert(String(localized: "Wake on LAN"), isPresented: $showWOL) {
            TextField("AA:BB:CC:DD:EE:FF", text: $wolMAC)
            Button(String(localized: "Cancel"), role: .cancel) {}
                Button(String(localized: "Wake")) {
                session.wakeOnLAN(mac: wolMAC)
            }
        } message: {
            Text(String(localized: "Send a magic packet via the Agent."))
        }
        .fileImporter(isPresented: $importerPresented, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    try? await session.uploadLocalFile(url: url)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: session.enterBackground()
            case .active: session.enterForeground()
            default: break
            }
        }
        .onChange(of: session.lastDownloadURL) { _, url in
            if let url { shareURL = url }
        }
        .sheet(item: Binding(
            get: { shareURL.map(IdentifiableURL.init) },
            set: { shareURL = $0?.url }
        )) { item in
            ShareSheet(items: [item.url])
        }
        .onDisappear {
            if isPinching { finishHostPinch() }
            session.suspendRemotePointer(false)
            session.setIdleTimerDisabled(false)
        }
    }

    private func applyHostPinch(scale: CGFloat, around loc: CGPoint, in size: CGSize) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if !isPinching {
                isPinching = true
                pinchAnchorScale = max(pinchScale, 1)
                dragIsViewportPan = false
                lastFingerTranslation = .zero
                session.suspendRemotePointer(true)
            }
            let oldScale = max(pinchScale, 1)
            let next = DesktopGestureMath.pinchScale(anchor: pinchAnchorScale, gestureScale: scale)
            panOffset = panKeepingPoint(loc, oldScale: oldScale, newScale: next, oldPan: panOffset, in: size)
            pinchScale = next
        }
    }

    private func finishHostPinch() {
        if pinchScale <= 1.05 {
            pinchScale = 1
            pinchAnchorScale = 1
            panOffset = .zero
        } else {
            pinchAnchorScale = pinchScale
            if viewportSize != .zero {
                panOffset = clampedPan(panOffset, scale: pinchScale, in: viewportSize)
            }
        }
        isPinching = false
        lastFingerTranslation = .zero
        session.suspendRemotePointer(false)
    }

    /// Keep the pinch centroid on the same screen pixel while scale changes.
    private func panKeepingPoint(
        _ loc: CGPoint, oldScale: CGFloat, newScale: CGFloat, oldPan: CGSize, in size: CGSize
    ) -> CGSize {
        let cx = size.width / 2
        let cy = size.height / 2
        let os = max(oldScale, 0.01)
        let px = (loc.x - oldPan.width - cx) / os
        let py = (loc.y - oldPan.height - cy) / os
        let next = CGSize(
            width: loc.x - cx - px * newScale,
            height: loc.y - cy - py * newScale
        )
        return clampedPan(next, scale: newScale, in: size)
    }

    /// Sheets / importer cover the desktop — disable the UIKit hit target underneath.
    private var chromeBlocksDesktopInput: Bool {
        showMoreMenu || showFiles || showDisplays || showWOL || importerPresented
    }

    private var currentModifiers: Int {
        var m = 0
        if stickyShift { m |= RE2HostKey.Mod.shift }
        if stickyCtrl { m |= RE2HostKey.Mod.ctrl }
        if stickyAlt { m |= RE2HostKey.Mod.alt }
        if stickyCmd { m |= RE2HostKey.Mod.meta }
        return m
    }

    private func tapHostKey(_ code: Int) {
        let mods = currentModifiers
        session.sendKey(keyCode: code, down: true, modifiers: mods)
        session.sendKey(keyCode: code, down: false, modifiers: mods)
    }

    private func handleHardwareKey(_ press: KeyPress) -> KeyPress.Result {
        let mods: Int = {
            var m = currentModifiers
            if press.modifiers.contains(.shift) { m |= RE2HostKey.Mod.shift }
            if press.modifiers.contains(.control) { m |= RE2HostKey.Mod.ctrl }
            if press.modifiers.contains(.option) { m |= RE2HostKey.Mod.alt }
            if press.modifiers.contains(.command) { m |= RE2HostKey.Mod.meta }
            return m
        }()
        if let code = mapHardwareKey(press.key) {
            session.sendKey(keyCode: code, down: true, modifiers: mods)
            session.sendKey(keyCode: code, down: false, modifiers: mods)
            return .handled
        }
        if press.key == KeyEquivalent("\r") || press.key == KeyEquivalent("\n") {
            tapHostKey(RE2HostKey.returnKey)
            return .handled
        }
        let chars = press.characters
        if !chars.isEmpty, chars != "\u{1b}" {
            session.sendKey(text: chars, down: true, modifiers: mods)
            session.sendKey(text: chars, down: false, modifiers: mods)
            return .handled
        }
        return .ignored
    }

    private func mapHardwareKey(_ key: KeyEquivalent) -> Int? {
        switch key {
        case KeyEquivalent(Character(UnicodeScalar(0x1b)!)): return RE2HostKey.escape
        case KeyEquivalent("\t"): return RE2HostKey.tab
        case KeyEquivalent("\u{7f}"): return RE2HostKey.delete
        case .leftArrow: return RE2HostKey.left
        case .rightArrow: return RE2HostKey.right
        case .upArrow: return RE2HostKey.up
        case .downArrow: return RE2HostKey.down
        case .escape: return RE2HostKey.escape
        case .return: return RE2HostKey.returnKey
        case .space: return RE2HostKey.space
        case .delete: return RE2HostKey.delete
        case .tab: return RE2HostKey.tab
        default: return nil
        }
    }

    private func handleTap(at point: CGPoint, in size: CGSize) {
        if isPinching { finishHostPinch() }
        // Each tap = one click immediately. Two quick taps → Mac double-click
        // (title-bar zoom, etc.). Do not batch a delayed double-tap recognizer —
        // that fought the pan gesture and often never fired.
        let n = normalize(point: point, in: size)
        lastPointerNorm = n
        session.sendMouse(x: n.x, y: n.y, buttons: 1, down: true, move: true)
        session.sendMouse(x: n.x, y: n.y, buttons: 1, up: true, move: true)
    }

    private func handleRightClick(at point: CGPoint, in size: CGSize) {
        let n = normalize(point: point, in: size)
        lastPointerNorm = n
        session.sendMouse(x: n.x, y: n.y, buttons: 2, down: true, move: true)
        session.sendMouse(x: n.x, y: n.y, buttons: 2, up: true, move: true)
    }

    private func handleOneFinger(
        at point: CGPoint, translation: CGSize, state: UIGestureRecognizer.State,
        selectDrag: Bool, in size: CGSize
    ) {
        if isPinching { return }
        switch state {
        case .began:
            // Only called after leaving tap slop — clean taps never reach here.
            lastFingerTranslation = .zero
            dragIsViewportPan = pinchScale > 1.05
            panAtDragStart = panOffset
            isMouseDragging = false
            oneFingerStartNorm = normalize(point: point, in: size)
            lastPointerNorm = oneFingerStartNorm
            if selectDrag, pinchScale <= 1.05 {
                isMouseDragging = true
                session.sendMouse(
                    x: oneFingerStartNorm.x, y: oneFingerStartNorm.y,
                    buttons: 1, down: true, move: true
                )
            }
        case .changed:
            let zoomed = pinchScale > 1.05
            if zoomed {
                let next = CGSize(
                    width: panAtDragStart.width + translation.width,
                    height: panAtDragStart.height + translation.height
                )
                panOffset = clampedPan(next, scale: pinchScale, in: size)
                return
            }
            let n = normalize(point: point, in: size)
            lastPointerNorm = n
            if session.gameMouseMode {
                session.sendMouse(x: n.x, y: n.y, buttons: isMouseDragging ? 1 : 0, move: true)
                return
            }
            if lastFingerTranslation == .zero, translation != .zero {
                lastFingerTranslation = translation
                return
            }
            let delta = CGSize(
                width: translation.width - lastFingerTranslation.width,
                height: translation.height - lastFingerTranslation.height
            )
            lastFingerTranslation = translation
            guard abs(delta.width) > 0.2 || abs(delta.height) > 0.2 else { return }
            guard abs(delta.width) < 120, abs(delta.height) < 120 else { return }
            let content = videoContentSize
            let rect = fitRect(contentW: content.w, contentH: content.h, in: size)
            var dx = Double(delta.width) / max(rect.width, 1) * Double(max(session.desktopWidth, 1))
            var dy = Double(delta.height) / max(rect.height, 1) * Double(max(session.desktopHeight, 1))
            dx = min(max(dx, -100), 100)
            dy = min(max(dy, -100), 100)
            session.sendMouse(
                x: n.x, y: n.y, buttons: isMouseDragging ? 1 : 0, move: true,
                relative: true, dx: dx, dy: dy
            )
        case .ended, .cancelled, .failed:
            defer {
                lastFingerTranslation = .zero
                panAtDragStart = panOffset
                dragIsViewportPan = false
                oneFingerBeganAt = nil
            }
            let n = normalize(point: point, in: size)
            if isMouseDragging {
                session.sendMouse(x: n.x, y: n.y, buttons: 1, up: true, move: true)
                isMouseDragging = false
            }
        default:
            break
        }
    }

    /// Painted video pixels — same aspect the Image(.fit) uses (not DESKTOP_READY alone).
    private var videoContentSize: (w: CGFloat, h: CGFloat) {
        let w = CGFloat(session.frameImage?.width ?? 0)
        let h = CGFloat(session.frameImage?.height ?? 0)
        if w > 1, h > 1 { return (w, h) }
        return (CGFloat(max(session.desktopWidth, 1)), CGFloat(max(session.desktopHeight, 1)))
    }

    private func cursorScreenPoint(in size: CGSize) -> CGPoint {
        let content = videoContentSize
        let rect = fitRect(contentW: content.w, contentH: content.h, in: size)
        let localX = rect.minX + CGFloat(session.cursorX) * rect.width
        let localY = rect.minY + CGFloat(session.cursorY) * rect.height
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGPoint(
            x: center.x + (localX - center.x) * pinchScale + panOffset.width,
            y: center.y + (localY - center.y) * pinchScale + panOffset.height
        )
    }

    private var cursorGlyph: some View {
        Canvas { ctx, _ in
            let tip = CGPoint(x: 0, y: 0)
            var arrow = Path()
            arrow.move(to: tip)
            arrow.addLine(to: CGPoint(x: tip.x, y: tip.y + 16))
            arrow.addLine(to: CGPoint(x: tip.x + 4, y: tip.y + 12.5))
            arrow.addLine(to: CGPoint(x: tip.x + 7.5, y: tip.y + 20))
            arrow.addLine(to: CGPoint(x: tip.x + 10, y: tip.y + 19))
            arrow.addLine(to: CGPoint(x: tip.x + 6.2, y: tip.y + 11.2))
            arrow.addLine(to: CGPoint(x: tip.x + 13, y: tip.y + 11.2))
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(.white))
            ctx.stroke(arrow, with: .color(.black.opacity(0.85)), lineWidth: 0.8)
        }
        .frame(width: 14, height: 22)
        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
    }

    private func clampedPan(_ offset: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        let content = videoContentSize
        let rect = fitRect(contentW: content.w, contentH: content.h, in: size)
        let maxX = max(0, (rect.width * scale - size.width) / 2 + 24)
        let maxY = max(0, (rect.height * scale - size.height) / 2 + 24)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    private func normalize(point: CGPoint, in size: CGSize) -> (x: Double, y: Double) {
        let content = videoContentSize
        let rect = fitRect(contentW: content.w, contentH: content.h, in: size)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Inverse of scaleEffect(anchor: center) + offset.
        let unpanned = CGPoint(x: point.x - panOffset.width, y: point.y - panOffset.height)
        let unscaled = CGPoint(
            x: center.x + (unpanned.x - center.x) / max(pinchScale, 0.01),
            y: center.y + (unpanned.y - center.y) / max(pinchScale, 0.01)
        )
        let x = Double((unscaled.x - rect.minX) / max(rect.width, 1))
        let y = Double((unscaled.y - rect.minY) / max(rect.height, 1))
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    private func fitRect(contentW: CGFloat, contentH: CGFloat, in size: CGSize) -> CGRect {
        let scale = min(size.width / contentW, size.height / contentH)
        let w = contentW * scale
        let h = contentH * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

struct DesktopFilesSheet: View {
    @ObservedObject var session: RE2DesktopSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let err = session.fileListError {
                    Text(err).foregroundStyle(.red)
                }
                Section(String(localized: "Remote (Agent xfer)")) {
                    if !session.remotePath.isEmpty {
                        Button {
                            let parent = (session.remotePath as NSString).deletingLastPathComponent
                            session.listRemoteFiles(path: parent == "." ? "" : parent)
                        } label: {
                            Label("..", systemImage: "folder")
                        }
                    }
                    ForEach(session.remoteFiles) { entry in
                        Button {
                            if entry.isDir {
                                session.listRemoteFiles(path: entry.path)
                            } else {
                                session.pullRemoteFile(path: entry.path, name: entry.name)
                            }
                        } label: {
                            Label {
                                HStack {
                                    Text(entry.name)
                                    Spacer()
                                    if !entry.isDir, entry.size > 0 {
                                        Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: entry.isDir ? "folder.fill" : "doc")
                            }
                        }
                    }
                }
                if !session.transfers.isEmpty {
                    Section(String(localized: "Transfers")) {
                        ForEach(session.transfers) { t in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: t.direction == .upload ? "arrow.up.doc" : "arrow.down.doc")
                                    Text(t.name)
                                    Spacer()
                                    if t.finished, t.direction == .download,
                                       let url = session.localDownloadURL(named: t.name) {
                                        ShareLink(item: url) {
                                            Image(systemName: "square.and.arrow.up")
                                        }
                                    } else {
                                        Text(t.finished ? String(localized: "Done") : "\(Int(t.fraction * 100))%")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                ProgressView(value: t.fraction)
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Files"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "Refresh")) { session.listRemoteFiles(path: session.remotePath) }
                }
            }
            .onAppear { session.listRemoteFiles(path: session.remotePath) }
        }
    }
}

private struct DesktopMoreMenuSheet: View {
    @ObservedObject var session: RE2DesktopSession
    var onPaste: () -> Void
    var onKeyframe: () -> Void
    var onToggleMouse: () -> Void
    var onTogglePrivacy: () -> Void
    var onToggleAudio: () -> Void
    var onToggleCamera: () -> Void
    var onTogglePhoneWebcam: () -> Void
    var onQuality: (DesktopVideoQuality) -> Void
    var onDisplays: () -> Void
    var onFiles: () -> Void
    var onUpload: () -> Void
    var onRetryP2P: () -> Void
    var onWOL: () -> Void
    var onDisconnect: () -> Void
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    tipButton(
                        title: String(localized: "Paste to Remote"),
                        tip: String(localized: "desktop.tip.paste"),
                        action: onPaste
                    )
                    tipButton(
                        title: String(localized: "Request Keyframe"),
                        tip: String(localized: "desktop.tip.keyframe"),
                        action: onKeyframe
                    )
                    tipButton(
                        title: session.gameMouseMode
                            ? String(localized: "Switch to Trackpad Mouse")
                            : String(localized: "Switch to Absolute Mouse"),
                        tip: session.gameMouseMode
                            ? String(localized: "desktop.tip.mouse.absolute")
                            : String(localized: "desktop.tip.mouse.trackpad"),
                        action: onToggleMouse
                    )
                    tipButton(
                        title: session.privacyBlank
                            ? String(localized: "Disable Privacy Blank")
                            : String(localized: "Privacy Blank"),
                        tip: session.privacyBlank
                            ? String(localized: "desktop.tip.privacy.on")
                            : String(localized: "desktop.tip.privacy.off"),
                        action: onTogglePrivacy
                    )
                    tipButton(
                        title: session.audioMuted
                            ? String(localized: "Unmute Audio")
                            : String(localized: "Mute Audio"),
                        tip: session.audioControlsEnabled
                            ? (session.audioMuted
                                ? String(localized: "desktop.tip.audio.off")
                                : String(localized: "desktop.tip.audio.on"))
                            : String(localized: "desktop.tip.audio.noperm"),
                        action: onToggleAudio,
                        disabled: !session.audioControlsEnabled
                    )
                    tipButton(
                        title: session.cameraOn
                            ? String(localized: "Close Remote Desktop Camera")
                            : String(localized: "Open Remote Desktop Camera"),
                        tip: session.cameraControlsEnabled
                            ? (session.cameraOn
                                ? String(localized: "desktop.tip.camera.on")
                                : String(localized: "desktop.tip.camera.off"))
                            : String(localized: "desktop.tip.camera.noperm"),
                        action: onToggleCamera,
                        disabled: !session.cameraControlsEnabled
                    )
                    tipButton(
                        title: session.phoneWebcamOn
                            ? String(localized: "Stop Phone as Webcam")
                            : String(localized: "Use Phone as Webcam"),
                        tip: session.phoneWebcamOn
                            ? String(localized: "desktop.tip.phoneWebcam.on")
                            : String(localized: "desktop.tip.phoneWebcam.off"),
                        action: onTogglePhoneWebcam
                    )
                }

                Section(String(localized: "Quality") + " · " + session.videoQuality.title) {
                    ForEach(DesktopVideoQuality.allCases) { q in
                        Button {
                            onQuality(q)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(q.title)
                                    Text(q.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if let res = session.qualityResolutionLabel(for: q) {
                                        Text(res)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if session.videoQuality == q {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Section {
                    tipButton(
                        title: String(localized: "Displays…"),
                        tip: String(localized: "desktop.tip.displays"),
                        action: onDisplays
                    )
                    tipButton(
                        title: String(localized: "Files…"),
                        tip: String(localized: "desktop.tip.files"),
                        action: onFiles
                    )
                    tipButton(
                        title: String(localized: "Upload File…"),
                        tip: String(localized: "desktop.tip.upload"),
                        action: onUpload
                    )
                    tipButton(
                        title: String(localized: "Retry P2P"),
                        tip: String(localized: "desktop.tip.retryP2P"),
                        action: onRetryP2P
                    )
                    tipButton(
                        title: String(localized: "Wake on LAN…"),
                        tip: String(localized: "desktop.tip.wol"),
                        action: onWOL
                    )
                }

                Section {
                    Button(String(localized: "Disconnect"), role: .destructive, action: onDisconnect)
                }

                Section {
                    Text(String(localized: "desktop.gestures.help"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(String(localized: "More"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done"), action: onClose)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func tipButton(
        title: String, tip: String, action: @escaping () -> Void, disabled: Bool = false
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(tip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// Observes phone capture so preview frames refresh independently of the desktop session.
private struct PhoneWebcamFloatingPipHost: View {
    @ObservedObject var streamer: PhoneCameraStreamer
    var errorText: String?
    var accessibilityID: String
    var containerSize: CGSize
    @Binding var offset: CGSize
    @Binding var scale: CGFloat
    @Binding var dragOrigin: CGSize
    @Binding var scaleOrigin: CGFloat
    var onFlip: () -> Void
    var onClose: () -> Void

    var body: some View {
        FloatingCameraPipWindow(
            image: streamer.previewImage,
            title: String(localized: "Phone as Webcam"),
            accessibilityID: accessibilityID,
            placeholder: errorText,
            anchor: .bottomLeading,
            preferredAspect: 3.0 / 4.0,
            containerSize: containerSize,
            offset: $offset,
            scale: $scale,
            dragOrigin: $dragOrigin,
            scaleOrigin: $scaleOrigin,
            trailingIcon: "arrow.triangle.2.circlepath.camera.fill",
            trailingAccessibility: String(localized: "Flip Camera"),
            onTrailing: onFlip,
            onClose: onClose
        )
    }
}

/// iOS-style floating camera layer: video only, chrome overlaid on the picture.
/// Controls hidden by default; single tap shows them; idle 6s hides again.
private struct PipHitProbe: UIViewRepresentable {
    var accessibilityID: String

    func makeUIView(context: Context) -> PipHitProbeView {
        let view = PipHitProbeView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.configure(id: accessibilityID)
        return view
    }

    func updateUIView(_ uiView: PipHitProbeView, context: Context) {
        uiView.configure(id: accessibilityID)
        DispatchQueue.main.async { [weak uiView] in uiView?.syncExclusionRegion() }
    }
}

private final class PipHitProbeView: UIView {
    private var regionID = ""

    func configure(id: String) {
        guard regionID != id else {
            syncExclusionRegion()
            return
        }
        if !regionID.isEmpty { DesktopInputExclusionRegions.remove(id: regionID) }
        regionID = id
        accessibilityIdentifier = id
        syncExclusionRegion()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncExclusionRegion()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, !regionID.isEmpty {
            DesktopInputExclusionRegions.remove(id: regionID)
        } else {
            syncExclusionRegion()
        }
    }

    func syncExclusionRegion() {
        guard let window, bounds.width > 1, bounds.height > 1, !regionID.isEmpty else { return }
        DesktopInputExclusionRegions.update(
            id: regionID,
            window: window,
            rect: convert(bounds, to: window)
        )
    }
}

private struct FloatingCameraPipWindow: View {
    enum Anchor {
        case bottomTrailing
        case bottomLeading
    }

    var image: UIImage?
    var title: String
    var accessibilityID: String
    var placeholder: String?
    var anchor: Anchor
    var preferredAspect: CGFloat? = nil
    var containerSize: CGSize
    @Binding var offset: CGSize
    @Binding var scale: CGFloat
    @Binding var dragOrigin: CGSize
    @Binding var scaleOrigin: CGFloat
    var trailingIcon: String? = nil
    var trailingAccessibility: String? = nil
    var onTrailing: (() -> Void)? = nil
    var onClose: () -> Void

    @State private var controlsVisible = false
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var dragMoved = false

    private let baseMaxEdge: CGFloat = 180
    private let minScale: CGFloat = 0.7
    private let maxScale: CGFloat = 2.8
    private let corner: CGFloat = 18
    private let hideDelay: Duration = .seconds(6)

    var body: some View {
        let aspect: CGFloat = {
            if let preferredAspect { return preferredAspect }
            guard let image else { return 16.0 / 9.0 }
            return max(image.size.width, 1) / max(image.size.height, 1)
        }()
        let base = baseSize(aspect: aspect)
        let drawn = CGSize(width: base.width * scale, height: base.height * scale)

        ZStack(alignment: alignment) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            ZStack {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    } else {
                        ZStack {
                            Color.black.opacity(0.72)
                            if let placeholder, !placeholder.isEmpty {
                                Text(placeholder)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.9))
                                    .multilineTextAlignment(.center)
                                    .padding(10)
                            } else {
                                ProgressView().tint(.white)
                            }
                        }
                    }
                }
                .frame(width: drawn.width, height: drawn.height)
                .clipped()

                if controlsVisible {
                    // Dim scrim like system video PiP when chrome is up.
                    Color.black.opacity(0.18)
                        .allowsHitTesting(false)

                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            pipChromeButton(systemName: "xmark", action: onClose)
                                .accessibilityLabel(String(localized: "Close"))

                            Text(title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity)

                            if let trailingIcon, let onTrailing {
                                pipChromeButton(systemName: trailingIcon, action: {
                                    bumpControls()
                                    onTrailing()
                                })
                                .accessibilityLabel(trailingAccessibility ?? title)
                            } else {
                                Color.clear.frame(width: 30, height: 30)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 8)

                        Spacer(minLength: 0)
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: drawn.width, height: drawn.height)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.white.opacity(controlsVisible ? 0.45 : 0.22), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .background(PipHitProbe(accessibilityID: "\(accessibilityID)HitProbe"))
            .accessibilityIdentifier(accessibilityID)
            .offset(offset)
            .padding(12)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dist = hypot(value.translation.width, value.translation.height)
                        if dist > 6 { dragMoved = true }
                        guard dragMoved else { return }
                        offset = CGSize(
                            width: dragOrigin.width + value.translation.width,
                            height: dragOrigin.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        if !dragMoved {
                            toggleControls()
                        } else {
                            bumpControls()
                            offset = clampedOffset(drawn: drawn, in: containerSize)
                            dragOrigin = offset
                        }
                        dragMoved = false
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        bumpControls()
                        scale = min(max(scaleOrigin * value, minScale), maxScale)
                    }
                    .onEnded { _ in
                        scale = min(max(scale, minScale), maxScale)
                        scaleOrigin = scale
                        offset = clampedOffset(drawn: drawn, in: containerSize)
                        dragOrigin = offset
                    }
            )
            .onDisappear {
                hideControlsTask?.cancel()
            }
        }
    }

    private var alignment: Alignment {
        switch anchor {
        case .bottomTrailing: return .bottomTrailing
        case .bottomLeading: return .bottomLeading
        }
    }

    private func pipChromeButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
        .buttonStyle(.plain)
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            controlsVisible.toggle()
        }
        if controlsVisible {
            scheduleHide()
        } else {
            hideControlsTask?.cancel()
        }
    }

    private func bumpControls() {
        guard controlsVisible else { return }
        scheduleHide()
    }

    private func scheduleHide() {
        hideControlsTask?.cancel()
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: hideDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                controlsVisible = false
            }
        }
    }

    private func baseSize(aspect: CGFloat) -> CGSize {
        if aspect >= 1 {
            return CGSize(width: baseMaxEdge, height: (baseMaxEdge / aspect).rounded())
        }
        return CGSize(width: (baseMaxEdge * aspect).rounded(), height: baseMaxEdge)
    }

    private func clampedOffset(drawn: CGSize, in container: CGSize) -> CGSize {
        let pad: CGFloat = 12
        switch anchor {
        case .bottomTrailing:
            let maxX = max(0, container.width - drawn.width - pad * 2)
            let maxY = max(0, container.height - drawn.height - pad * 2)
            return CGSize(
                width: min(max(offset.width, -maxX), pad),
                height: min(max(offset.height, -maxY), pad)
            )
        case .bottomLeading:
            let maxX = max(0, container.width - drawn.width - pad * 2)
            let maxY = max(0, container.height - drawn.height - pad * 2)
            return CGSize(
                width: min(max(offset.width, -pad), maxX),
                height: min(max(offset.height, -maxY), pad)
            )
        }
    }
}

/// Desktop title + status under the nav bar title slot.
/// Uses `.principal` so trailing keyboard/more stay tappable; text stays leading-aligned
/// inside a wide title area (not a Liquid Glass leading “button”).
private struct DesktopNavTitleToolbar: ToolbarContent {
    let name: String
    let statusLine: String
    let showStatus: Bool
    /// Max text width before ellipsis (leave room for back + trailing controls).
    var maxWidth: CGFloat = 280

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if showStatus, !statusLine.isEmpty {
                        Text(statusLine)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(maxWidth: maxWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("desktopNavTitle")
        }
    }
}

/// Turns off NavigationStack swipe-back while the desktop viewer is on screen.
/// SwiftUI often leaves `.background` VCs without `navigationController`; walk parents
/// and keep re-applying — UIKit/SwiftUI periodically re-enables the pop gesture.
private struct DisableInteractivePopGesture: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        Controller()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        (uiViewController as? Controller)?.applyBlock()
    }

    private final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var blockedNav: UINavigationController?
        private weak var blockedPop: UIGestureRecognizer?
        private var popEnabledBefore: Bool?
        private weak var previousPopDelegate: UIGestureRecognizerDelegate?
        private var blockedEdgeGestures: [(UIGestureRecognizer, Bool)] = []

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyBlock()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyBlock()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyBlock()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restore()
        }

        func applyBlock() {
            guard let nav = nearestNavigationController() else { return }
            let pop = nav.interactivePopGestureRecognizer
            if blockedPop !== pop {
                restore()
                blockedNav = nav
                blockedPop = pop
                if let pop {
                    popEnabledBefore = pop.isEnabled
                    previousPopDelegate = pop.delegate
                    pop.delegate = self
                    pop.isEnabled = false
                }
                // Also mute left-edge pans on the nav view (some iOS builds keep a separate one).
                blockedEdgeGestures = []
                for g in nav.view.gestureRecognizers ?? [] {
                    if let edge = g as? UIScreenEdgePanGestureRecognizer,
                       edge.edges.contains(.left) {
                        blockedEdgeGestures.append((edge, edge.isEnabled))
                        edge.isEnabled = false
                    }
                }
            } else if let pop, pop.isEnabled {
                pop.isEnabled = false
            }
        }

        private func restore() {
            if let pop = blockedPop {
                pop.delegate = previousPopDelegate
                if let was = popEnabledBefore { pop.isEnabled = was }
            }
            for (g, was) in blockedEdgeGestures { g.isEnabled = was }
            blockedEdgeGestures = []
            blockedNav = nil
            blockedPop = nil
            popEnabledBefore = nil
            previousPopDelegate = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Never allow swipe-back while the desktop viewer is up.
            if gestureRecognizer === blockedPop { return false }
            return true
        }

        private func nearestNavigationController() -> UINavigationController? {
            var vc: UIViewController? = self
            while let cur = vc {
                if let nav = cur as? UINavigationController { return nav }
                if let nav = cur.navigationController { return nav }
                vc = cur.parent
            }
            var responder: UIResponder? = view
            while let cur = responder {
                if let nav = cur as? UINavigationController { return nav }
                if let v = cur as? UIViewController, let nav = v.navigationController { return nav }
                responder = cur.next
            }
            return nil
        }
    }
}

private struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
