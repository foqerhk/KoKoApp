import Foundation
import UIKit

extension Notification.Name {
    /// Posted after E2E bind so HostList pushes `DesktopViewerView` for UI chrome checks.
    static let kokoE2EShowDesktop = Notification.Name("kokoE2EShowDesktop")
}

/// Device / Simulator probe: `-RE2E2E` (+ optional force flags).
/// Pairing: env `KOKO_RE2_PAIR_JSON` or `Documents/re2-pair.json`.
/// Result: `Documents/re2-e2e-result.json` + stderr `KOKO_RE2_E2E_RESULT …`.
///
/// Optional: `-RE2E2EQuality` runs 流畅→超清 reopen smoke;
/// `-RE2E2EMenu` exercises more-menu RPCs (keyframe / mouse / privacy / clipboard / displays / files).
@MainActor
enum RE2E2EAutoConnect {
    /// Prevent double-start from onAppear + didBecomeActive + task.
    private static var didStartThisProcess = false

    static func writeBootProbe() {
        var info: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "args": ProcessInfo.processInfo.arguments,
            "hasPair": loadPairJSON() != nil,
            "hasRequest": loadRequestFile() != nil,
            "e2eEnv": ProcessInfo.processInfo.environment["KOKO_RE2_E2E"] ?? ""
        ]
        if let req = loadRequestFile() { info["request"] = req }
        writeNamed("re2-e2e-boot.json", info)
    }

    static func runIfRequested(store: AppStore) {
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        let req = loadRequestFile()
        // Device: prefer Documents/re2-e2e-request.json (devicectl argv/env often dropped).
        let e2eOn = args.contains("-RE2E2E")
            || env["KOKO_RE2_E2E"] == "1"
            || (req?["e2e"] as? Bool == true)
            || (req?["e2e"] as? String == "1")
        guard e2eOn else { return }
        // Cold launch: once. Warm relaunch via devicectl often skips process death —
        // allow a fresh Documents/re2-e2e-request.json to re-trigger.
        if didStartThisProcess {
            guard req != nil else { return }
        }
        didStartThisProcess = true

        let forceWSS = args.contains("-RE2E2EForceWSS")
            || env["KOKO_RE2_FORCE_WSS"] == "1"
            || reqFlag(req, "forceWSS")
        let forceUDP = args.contains("-RE2E2EForceUDP")
            || env["KOKO_RE2_FORCE_UDP"] == "1"
            || reqFlag(req, "forceUDP")
        let stripLAN = args.contains("-RE2E2ENoLAN")
            || env["KOKO_RE2_NO_LAN"] == "1"
            || reqFlag(req, "stripLAN") || reqFlag(req, "noLAN")
        let testQuality = args.contains("-RE2E2EQuality")
            || env["KOKO_RE2_TEST_QUALITY"] == "1"
            || reqFlag(req, "quality") || reqFlag(req, "testQuality")
        let testMenu = args.contains("-RE2E2EMenu")
            || env["KOKO_RE2_TEST_MENU"] == "1"
            || reqFlag(req, "menu") || reqFlag(req, "testMenu")
        let testGestures = args.contains("-RE2E2EGestures")
            || env["KOKO_RE2_TEST_GESTURES"] == "1"
            || reqFlag(req, "gestures") || reqFlag(req, "testGestures")
        let testPip = args.contains("-RE2E2EPip")
            || env["KOKO_RE2_TEST_PIP"] == "1"
            || reqFlag(req, "pip") || reqFlag(req, "testPip")
        let test5K = args.contains("-RE2E2E5K")
            || env["KOKO_RE2_TEST_5K"] == "1"
            || reqFlag(req, "test5K") || reqFlag(req, "secondary5K")
        // Virtual full-blood: Agent RE_VDISPLAY=8k|16k; App selects largest virtual FB.
        let test8K = args.contains("-RE2E2E8K")
            || env["KOKO_RE2_TEST_8K"] == "1"
            || reqFlag(req, "test8K") || reqFlag(req, "virtual8K")
        let test16K = args.contains("-RE2E2E16K")
            || env["KOKO_RE2_TEST_16K"] == "1"
            || reqFlag(req, "test16K") || reqFlag(req, "virtual16K")
        // RD-LIFE-03: the host script really foregrounds another app and then KoKo.
        let testExternalLife = reqFlag(req, "externalLife")
        let useStored = args.contains("-RE2E2EStored")
            || env["KOKO_RE2_STORED"] == "1"
            || reqFlag(req, "stored")
        // Kick test: displace another phone already controlling this Agent.
        let forceTakeover = args.contains("-RE2E2EForce")
            || env["KOKO_RE2_FORCE"] == "1"
            || reqFlag(req, "force")
        // RD-LIFE-02: soft background/foreground via session enterBackground/enterForeground.
        let testLife = testExternalLife || args.contains("-RE2E2ELife")
            || env["KOKO_RE2_TEST_LIFE"] == "1"
            || reqFlag(req, "testLife") || reqFlag(req, "lifeBackground")
        // RD-DISP-02: virtual↔primary selectDisplay paint both ways (Agent RE_VDISPLAY=8k).
        let testDispSwitch = args.contains("-RE2E2EDispSwitch")
            || env["KOKO_RE2_TEST_DISP_SWITCH"] == "1"
            || reqFlag(req, "testDispSwitch") || reqFlag(req, "dispSwitch")

        // Consume request so relaunches without a new file do not re-run.
        clearRequestFile()
        NSLog("KOKO_RE2_E2E start forceWSS=%d forceUDP=%d stripLAN=%d quality=%d menu=%d 5k=%d 8k=%d 16k=%d life=%d disp=%d",
              forceWSS ? 1 : 0, forceUDP ? 1 : 0, stripLAN ? 1 : 0,
              testQuality ? 1 : 0, testMenu ? 1 : 0, test5K ? 1 : 0,
              test8K ? 1 : 0, test16K ? 1 : 0, testLife ? 1 : 0, testDispSwitch ? 1 : 0)
        // Early breadcrumb so host can confirm trigger before connect finishes.
        write([
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "ok": false,
            "phase": "starting",
            "forceWSS": forceWSS,
            "forceUDP": forceUDP,
            "stripLAN": stripLAN,
            "testQuality": testQuality,
            "testMenu": testMenu,
            "testGestures": testGestures,
            "testPip": testPip,
            "test5K": test5K,
            "test8K": test8K,
            "test16K": test16K,
            "testLife": testLife,
            "testExternalLife": testExternalLife,
            "testDispSwitch": testDispSwitch
        ])

        Task { @MainActor in
            var result: [String: Any] = [
                "startedAt": ISO8601DateFormatter().string(from: Date()),
                "ok": false,
                "forceWSS": forceWSS,
                "forceUDP": forceUDP,
                "stripLAN": stripLAN,
                "testQuality": testQuality,
                "testMenu": testMenu,
                "testGestures": testGestures,
                "testPip": testPip,
                "test5K": test5K,
                "test8K": test8K,
                "test16K": test16K,
                "testLife": testLife,
                "testExternalLife": testExternalLife,
                "testDispSwitch": testDispSwitch
            ]
            defer { write(result) }

            // Stored mode reconnects the saved desktop exactly like a list tap (no QR).
            let storedDesk = useStored ? store.desktops.first(where: { $0.canReconnect }) : nil
            if useStored, storedDesk == nil {
                result["error"] = "no stored desktop to reconnect"
                return
            }
            var parsed: RE2PairingPayload?
            if storedDesk == nil {
                guard var raw = loadPairJSON() else {
                    result["error"] = "missing KOKO_RE2_PAIR_JSON / Documents/re2-pair.json"
                    return
                }
                if stripLAN {
                    raw = Self.stripLANFromPairJSON(raw) ?? raw
                }
                result["pairBytes"] = raw.utf8.count
                do {
                    parsed = try RE2PairingPayload.parse(raw)
                } catch {
                    result["error"] = "bad pairing: \(error.localizedDescription)"
                    return
                }
            }
            result["stored"] = storedDesk != nil
            result["deviceIdPrefix"] = String((storedDesk?.deviceID ?? parsed?.deviceID ?? "").prefix(12))
            result["relay"] = storedDesk?.relayURL ?? parsed?.relay ?? ""
            let lanList = storedDesk?.lanCandidates ?? parsed?.lan ?? []
            result["lan"] = lanList
            result["udp"] = storedDesk?.udpHostPort ?? parsed?.udp ?? ""
            let expectLAN = !forceWSS && !forceUDP && !stripLAN && !lanList.isEmpty

            // Use the shared hub so HostList can push DesktopViewer (UI chrome probe).
            let session = DesktopSessionHub.shared.session
            if session.phase != .idle {
                session.disconnect(userInitiated: true)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            // Re-apply AFTER disconnect — disconnect(userInitiated) clears e2eForce*
            // / e2eSuppressABR / e2eStripLAN, which made forceWSS probes fall through
            // to UDP→WSS fallback and ABR race ("session failed before quality smooth").
            RE2DesktopSession.e2eStripLAN = stripLAN
            RE2DesktopSession.e2eSuppressABR = testQuality || testMenu || testGestures || testPip
                || test8K || test16K || test5K || testDispSwitch
            if forceWSS {
                RE2DesktopSession.e2eForceWSS = true
                RE2DesktopSession.e2eForceUDP = false
            } else if forceUDP {
                RE2DesktopSession.e2eForceWSS = false
                RE2DesktopSession.e2eForceUDP = true
            } else {
                RE2DesktopSession.e2eForceWSS = false
                RE2DesktopSession.e2eForceUDP = false
            }

            // Prefer balanced in-memory for matrix; hi-res probes start at Ultra.
            // NEVER persist — earlier E2E wrote .balanced into UserDefaults and the
            // next real session looked like “UDP 自降清晰度”.
            let qualityBefore = DesktopVideoQuality.stored
            defer { qualityBefore.persist() }
            if test5K || test8K || test16K {
                session.videoQuality = .ultra
            } else if testQuality {
                // Quality matrix starts at smooth inside the loop; seed balanced only there.
                session.videoQuality = .balanced
            } else {
                // Product default: Auto (highest the link will carry).
                session.videoQuality = .auto
            }

            let accessPassword: String? = {
                if let s = req?["password"] as? String, !s.isEmpty { return s }
                if let s = req?["accessPassword"] as? String, !s.isEmpty { return s }
                if let s = env["KOKO_RE2_ACCESS_PASSWORD"], !s.isEmpty { return s }
                return nil
            }()
            result["accessPasswordSet"] = !(accessPassword ?? "").isEmpty
            do {
                let profile: PairedDesktop
                if let storedDesk {
                    try await session.reconnect(profile: storedDesk, accessPassword: accessPassword, force: forceTakeover)
                    profile = session.currentPaired ?? storedDesk
                } else if let parsed {
                    profile = try await session.connect(payload: parsed, accessPassword: accessPassword, force: forceTakeover)
                } else {
                    return
                }
                // Do not persist stripLAN / no-LAN probe hosts — they overwrite real
                // lanCandidates and the user's next tap stays on WSS·Relay forever.
                if !stripLAN {
                    store.upsertDesktop(profile)
                }
                result["pairedName"] = profile.name
                NotificationCenter.default.post(
                    name: .kokoE2EShowDesktop,
                    object: nil,
                    userInfo: ["desktop": profile]
                )
            } catch {
                result["error"] = "connect failed: \(error.localizedDescription)"
                result["phase"] = String(describing: session.phase)
                result["path"] = session.pathLabel
                result["status"] = session.statusText
                return
            }

            // Wait for first paint (up to 45s).
            guard await waitPainted(session, seconds: 45, result: &result) else { return }
            // Native-quality reopen may produce a valid first frame while phase is
            // briefly openingDesktop. Do not probe chrome/input in that transition:
            // a real user cannot meaningfully judge post-connect gestures until the
            // READY has settled either.
            let settleDeadline = Date().addingTimeInterval(20)
            while Date() < settleDeadline, session.phase == .openingDesktop {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard session.phase == .streaming else {
                result["error"] = "initial desktop did not settle phase=\(session.phase) path=\(session.pathLabel)"
                return
            }
            write(result)

            // UI chrome: title / More / cursor (needs DesktopViewer on screen).
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            var chrome = probeDesktopChrome(session: session)
            result["uiChrome"] = chrome
            result["navStatusLine"] = session.navStatusLine
            result["cursorVisible"] = session.cursorVisible
            result["cursorXY"] = "\(session.cursorX),\(session.cursorY)"
            // OPEN always requests hide_cursor so the host pointer is not baked into the frame (RD-CUR-02).
            result["hideCursorOpen"] = true
            result["weakNetHint"] = session.weakNetHint
            result["videoQuality"] = session.videoQuality.rawValue
            result["encodeDesk"] = "\(session.desktopWidth)x\(session.desktopHeight)"
            if let shot = captureKeyWindowPNG() {
                writeBinary("re2-e2e-desktop.png", shot)
                chrome["screenshotBytes"] = shot.count
                result["uiChrome"] = chrome
            }
            write(result)

            // Gesture / input plane probe: hit-test + click → cursor should move.
            let gesture = await probeGestures(session: session, exhaustive: testGestures)
            result["gesture"] = gesture
            write(result)

            if testPip, result["error"] == nil {
                result["phase"] = "pip"
                var pip: [String: Any] = [:]

                session.setRemoteCameraEnabled(true)
                let remoteDeadline = Date().addingTimeInterval(12)
                while Date() < remoteDeadline, !session.cameraOn {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                pip["remote"] = probePipHit(identifier: "remoteCameraPip")
                session.setRemoteCameraEnabled(false)
                try? await Task.sleep(nanoseconds: 400_000_000)

                session.setPhoneWebcamEnabled(true)
                let phoneDeadline = Date().addingTimeInterval(15)
                while Date() < phoneDeadline, !session.phoneWebcamOn,
                      session.phoneWebcamError == nil {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                pip["phone"] = probePipHit(identifier: "phoneWebcamPip")
                session.setPhoneWebcamEnabled(false)

                let remoteOK = (pip["remote"] as? [String: Any])?["ownsHit"] as? Bool == true
                let phoneOK = (pip["phone"] as? [String: Any])?["ownsHit"] as? Bool == true
                pip["pipOK"] = remoteOK && phoneOK
                result["pip"] = pip
                result["pipOK"] = remoteOK && phoneOK
                if !remoteOK || !phoneOK {
                    result["error"] = "camera PiP did not own hit testing: \(pip)"
                }
                write(result)
            }

            // RD-LIFE-02: background soft-teardown + foreground reconnect must repaint.
            if testLife, result["error"] == nil {
                result["phase"] = testExternalLife ? "awaitingExternalBackground" : "lifeBackground"
                write(result)
                let beforeLife = session.frameEpoch
                // RD-LIFE-02 covers the long-background teardown + resume path.
                let keepGrace = RE2DesktopSession.backgroundGraceSeconds
                RE2DesktopSession.backgroundGraceSeconds = 0
                defer { RE2DesktopSession.backgroundGraceSeconds = keepGrace }
                if testExternalLife {
                    // The host script switches to Settings for several seconds,
                    // then foregrounds this existing process. This task is
                    // suspended while the app is genuinely in the background.
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                } else {
                    session.enterBackground()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                result["lifeSuspended"] = session.phase == .failed
                    || session.statusText.lowercased().contains("background")
                if !testExternalLife {
                    session.enterForeground()
                }
                // Post-background reconnect; allow a long paint window.
                var lifePaint = false
                let lifeDeadline = Date().addingTimeInterval(55)
                while Date() < lifeDeadline {
                    if session.phase == .streaming, session.frameImage != nil,
                       session.frameEpoch > beforeLife || (session.lastDecodedAt.map { Date().timeIntervalSince($0) < 8 } ?? false) {
                        lifePaint = true
                        break
                    }
                    // Do not rescue this probe with a manual reconnect. RD-LIFE-02
                    // must prove scenePhase auto-resume itself works; the old kick
                    // made the test green while the real app still required tapping
                    // the Reconnect button.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if !lifePaint {
                    lifePaint = await Self.waitPaint(session, timeout: 20)
                }
                session.requestKeyframe(force: true)
                let lifeStill = await Self.stillPainting(session, seconds: 3)
                let lifeAlive = lifePaint || lifeStill || (session.phase == .streaming && session.frameImage != nil)
                result["lifeBackground"] = lifeAlive
                result["externalLife"] = testExternalLife
                result["lifeEpoch"] = "\(beforeLife)→\(session.frameEpoch)"
                result["lifePhase"] = String(describing: session.phase)
                result["lifePath"] = session.pathLabel
                if !lifeAlive, result["error"] == nil {
                    result["error"] = "life background/foreground did not repaint phase=\(session.phase) path=\(session.pathLabel)"
                }
                result["phase"] = "afterLife"
                write(result)
            }

            // RD-DISP-02: virtual display ↔ primary both ways must paint (no 8K pixel gate).
            if testDispSwitch, result["error"] == nil {
                result["phase"] = "dispSwitch"
                write(result)
                session.refreshDisplays()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                let displays = session.displays
                result["dispSwitchList"] = displays.map {
                    [
                        "id": $0.displayID, "ew": $0.encodeWidth, "eh": $0.encodeHeight,
                        "virtual": $0.virtual, "primary": $0.primary, "name": $0.name
                    ] as [String: Any]
                }
                let virtual = displays.first(where: {
                    $0.virtual || $0.name.localizedCaseInsensitiveContains("virtual")
                })
                let primary = displays.first(where: { $0.primary })
                    ?? displays.first(where: { !$0.virtual })
                if let virtual, let primary, virtual.displayID != primary.displayID {
                    let beforeV = session.frameEpoch
                    session.selectDisplay(virtual.displayID)
                    let toVirtual = await Self.waitPaint(session, timeout: 45)
                    result["dispToVirtual"] = toVirtual
                    result["dispVirtualId"] = virtual.displayID
                    result["picAfterVirtual"] = "\(session.frameImage?.width ?? 0)x\(session.frameImage?.height ?? 0)"
                    result["deskAfterVirtual"] = "\(session.desktopWidth)x\(session.desktopHeight)"
                    result["dispVirtualEpoch"] = "\(beforeV)→\(session.frameEpoch)"

                    let beforeP = session.frameEpoch
                    session.selectDisplay(primary.displayID)
                    let toPrimary = await Self.waitPaint(session, timeout: 45)
                    result["dispToPrimary"] = toPrimary
                    result["dispPrimaryId"] = primary.displayID
                    result["picAfterPrimary"] = "\(session.frameImage?.width ?? 0)x\(session.frameImage?.height ?? 0)"
                    result["deskAfterPrimary"] = "\(session.desktopWidth)x\(session.desktopHeight)"
                    result["dispPrimaryEpoch"] = "\(beforeP)→\(session.frameEpoch)"

                    let ok = toVirtual && toPrimary
                    result["dispSwitchOK"] = ok
                    if !ok, result["error"] == nil {
                        result["error"] = "dispSwitch paint failed virtual=\(toVirtual) primary=\(toPrimary)"
                    }
                } else {
                    result["dispSwitchOK"] = false
                    if result["error"] == nil {
                        result["error"] = "dispSwitch needs distinct virtual+primary in \(displays.map { "\($0.displayID)v=\($0.virtual)" })"
                    }
                }
                result["phase"] = "afterDispSwitch"
                write(result)
            }

            // Hi-res probe: real secondary ≥5K, or Agent virtual 8K/16K (FB pixels).
            let hiResLabel: String? = {
                if test16K { return "16K" }
                if test8K { return "8K" }
                if test5K { return "5K" }
                return nil
            }()
            if let hiResLabel {
                let wantW: Int
                let wantH: Int
                let preferVirtual: Bool
                switch hiResLabel {
                case "16K": wantW = 12000; wantH = 6700; preferVirtual = true
                case "8K":  wantW = 7000;  wantH = 3900; preferVirtual = true
                default:    wantW = 4800;  wantH = 2700; preferVirtual = false
                }
                result["phase"] = "hiRes\(hiResLabel)"
                write(result)
                session.refreshDisplays()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let displays = session.displays
                result["displayList"] = displays.map {
                    [
                        "id": $0.displayID, "w": $0.width, "h": $0.height,
                        "ew": $0.encodeWidth, "eh": $0.encodeHeight,
                        "fbW": $0.fbWidth, "fbH": $0.fbHeight,
                        "virtual": $0.virtual, "primary": $0.primary,
                        "name": $0.name
                    ] as [String: Any]
                }
                let candidates: [RE2DisplayInfo] = {
                    if preferVirtual {
                        let v = displays.filter { $0.virtual || $0.name.localizedCaseInsensitiveContains("virtual") }
                        if !v.isEmpty { return v }
                    }
                    return displays
                }()
                guard let best = candidates.max(by: {
                    $0.encodeWidth * $0.encodeHeight < $1.encodeWidth * $1.encodeHeight
                }), best.encodeWidth >= wantW || best.encodeHeight >= wantH else {
                    result["error"] = "no ≥\(hiResLabel) display in list: \(displays.map { "\($0.displayID)=\($0.encodeWidth)x\($0.encodeHeight) v=\($0.virtual)" })"
                    // This is a physical test-prerequisite failure, not a reason
                    // to leave the host harness polling until its 15-minute timeout.
                    result["done"] = true
                    result["phase"] = "done"
                    result["phaseAtEnd"] = String(describing: session.phase)
                    return
                }
                result["targetDisplay"] = [
                    "id": best.displayID, "w": best.width, "h": best.height,
                    "ew": best.encodeWidth, "eh": best.encodeHeight, "virtual": best.virtual
                ]
                // Prefer UDP·Relay for fat 5K IDRs; WSS can carry ≥4K after Agent
                // soft-cap exception, but record path for evidence.
                result["hiResPath"] = session.pathLabel
                session.setVideoQuality(.ultra, forceReopen: true, persist: false)
                // Let ultra OPEN land before display switch (avoid 720p max on reopen).
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                let beforeSwitch = session.frameEpoch
                session.selectDisplay(best.displayID)
                var paintedHi = false
                let deadline = Date().addingTimeInterval(hiResLabel == "16K" ? 160 : 120)
                while Date() < deadline {
                    let picW = session.frameImage?.width ?? 0
                    let picH = session.frameImage?.height ?? 0
                    let deskW = session.desktopWidth
                    let deskH = session.desktopHeight
                    // 5K/8K: require decoded pixels at target class. DESKTOP_READY
                    // alone previously marked 5K green even when frameImage was nil
                    // after a transient HEVC decode.
                    // 16K: soft-VT on sim/device often cannot emit CGImage >8K even when
                    // libx265 IDRs assemble — honor DESKTOP_READY FB + post-switch decode.
                    let sizeOK: Bool = {
                        if hiResLabel == "5K" || hiResLabel == "8K" {
                            return picW >= wantW && picH >= wantH
                        }
                        if hiResLabel == "16K" {
                            if picW >= wantW && picH >= wantH { return true }
                            return deskW >= wantW && deskH >= wantH
                                && session.debugFramesDecoded >= 1
                        }
                        return picW >= wantW && picH >= wantH
                    }()
                    if session.phase == .streaming, session.frameEpoch > beforeSwitch, sizeOK {
                        paintedHi = true
                        break
                    }
                    if session.phase == .failed { break }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                let picW = session.frameImage?.width ?? 0
                let picH = session.frameImage?.height ?? 0
                result["picAfterHiRes"] = "\(picW)x\(picH)"
                result["deskAfterHiRes"] = "\(session.desktopWidth)x\(session.desktopHeight)"
                result["statsAfterHiRes"] = session.statsLine
                result["pathAfterHiRes"] = session.pathLabel
                result["assemblerPeakHiRes"] = session.debugAssemblerPeak
                result["videoPartsRXHiRes"] = session.debugVideoPartsRX
                result["framesDecodedHiRes"] = session.debugFramesDecoded
                result["decoderErrorHiRes"] = session.decoderLastError
                result["decoderBackendHiRes"] = session.decoderBackend
                result["softDecode"] = H264Decoder.forceSoftware
                result["paintedHiRes"] = paintedHi
                // Backward-compatible 5K keys when probing 5K.
                if hiResLabel == "5K" {
                    result["painted5K"] = paintedHi
                    result["picAfter5K"] = result["picAfterHiRes"]
                    result["deskAfter5K"] = result["deskAfterHiRes"]
                }
                if !paintedHi {
                    result["error"] = "\(hiResLabel) paint failed pic=\(picW)x\(picH) desk=\(session.desktopWidth)x\(session.desktopHeight) rx=\(session.debugVideoPartsRX) dec=\(session.debugFramesDecoded) peak=\(session.debugAssemblerPeak) decErr=\(session.decoderLastError) stats=\(session.statsLine)"
                    return
                }
                let holdStart = session.frameEpoch
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                let holdEnd = session.frameEpoch
                let advanced = Int(holdEnd &- holdStart)
                result["hiResHoldEpochs"] = advanced
                result["hiResSmooth"] = advanced >= 1
                let picW2 = session.frameImage?.width ?? 0
                let picH2 = session.frameImage?.height ?? 0
                let deskW2 = session.desktopWidth
                let deskH2 = session.desktopHeight
                let stillHi: Bool = {
                    // 16K soft-decode may replace the CGImage with a transient lower
                    // frame while DESKTOP_READY stays at FB size — honor desk.
                    if hiResLabel == "16K" {
                        return deskW2 >= wantW && deskH2 >= wantH
                    }
                    if hiResLabel == "5K" || hiResLabel == "8K" {
                        return picW2 >= wantW && picH2 >= wantH
                    }
                    return picW2 >= wantW && picH2 >= wantH
                }()
                if !stillHi {
                    result["error"] = "\(hiResLabel) dropped after hold pic=\(picW2)x\(picH2) desk=\(deskW2)x\(deskH2)"
                    return
                }
                result["hevcWire"] = true
                result["phase"] = "after\(hiResLabel)"
                result["hiResOK"] = true
                if hiResLabel == "5K" {
                    result["native5K"] = true
                    result["sharp4K"] = true
                    result["fiveKOK"] = true
                    result["fiveKHoldEpochs"] = advanced
                }
                if hiResLabel == "8K" { result["eightKOK"] = true }
                if hiResLabel == "16K" { result["sixteenKOK"] = true }
                write(result)
            }

            // Hold for quality ramp. UDP·LAN settle is ~4s + 2s frame check before
            // re-OPEN; give enough wall time so sharpness≥720p is meaningful.
            let rampHold: UInt64 = expectLAN ? 12_000_000_000 : 6_000_000_000
            try? await Task.sleep(nanoseconds: rampHold)
            result["pathAfterRamp"] = session.pathLabel
            result["statsAfterRamp"] = session.statsLine
            let deskAfterRamp = "\(session.desktopWidth)x\(session.desktopHeight)"
            result["desktopAfterRamp"] = deskAfterRamp
            // LAN PreferDirect + best-effort video plane: commercial ≥1080p after ramp.
            // Skip when quality matrix seeds 标清 — 0.55×1080 ≈ 594p by design.
            if expectLAN, !testQuality {
                let h = session.desktopHeight
                let w = session.desktopWidth
                let sharpOK = h >= 720 || w >= 1280
                result["sharpnessOK"] = sharpOK
                if !sharpOK, result["error"] == nil {
                    result["error"] = "LAN after ramp still soft \(deskAfterRamp) (need ≥720p/1080p class)"
                }
            } else if forceUDP || stripLAN {
                // UDP·Relay / no-LAN: must not stay at the old 320 emergency clamp forever.
                // 5K cellular soft-pass clears desk during switch; treat as non-emergency.
                if result["fiveKCellularSoft"] as? Bool == true {
                    result["notEmergency320"] = true
                } else {
                    let notEmergency = session.desktopWidth > 400 || session.desktopHeight > 240
                    result["notEmergency320"] = notEmergency
                    if !notEmergency, result["error"] == nil {
                        result["error"] = "still emergency 320p after ramp: \(deskAfterRamp)"
                    }
                }
            }
            result["phase"] = "afterRamp"
            // Weak-net Phase-1 gate: WSS/no-LAN must expose enriched STATS path (hint may
            // be empty on a healthy relay; never leave emergency 320p — checked above).
            result["weakNetHint"] = session.weakNetHint
            result["statsHasJitterField"] = session.statsLine // presence smoke via live stats
            if forceWSS || stripLAN {
                result["weakNetPath"] = session.pathLabel
                let notWSSStuck = session.phase == .streaming && session.frameImage != nil
                result["weakNetStreamingOK"] = notWSSStuck
                if !notWSSStuck, result["error"] == nil {
                    result["error"] = "weak-net WSS/no-LAN not streaming after ramp path=\(session.pathLabel)"
                }
            }
            write(result)

            // Strict hold: quality matrix skips long freeze hold (switches cover paint).
            // Else LAN 60s (6×10s), others 30s (3×10s).
            // Strict hold: quality/menu/disp/life skip long freeze hold (their probes cover paint).
            // Else LAN 60s (6×10s), others 30s (3×10s).
            let holdWindows = (testQuality || testMenu || testGestures || testPip || testDispSwitch || testLife
                || (test5K && result["fiveKCellularSoft"] as? Bool == true)) ? 1
                : ((test8K || test16K || test5K) ? 2 : (expectLAN ? 6 : 3))
            let windowNs: UInt64 = 10_000_000_000
            var epochs: [UInt64] = [session.frameEpoch]
            var pathMid = session.pathLabel
            var deltas: [Int] = []
            for w in 0..<holdWindows {
                try? await Task.sleep(nanoseconds: windowNs)
                let next = session.frameEpoch
                deltas.append(Int(next &- epochs[epochs.count - 1]))
                epochs.append(next)
                if w == holdWindows / 2 { pathMid = session.pathLabel }
                // Sharpness must not collapse mid-hold on LAN (skip for quality matrix).
                if expectLAN, !testQuality {
                    let sharpStill = session.desktopHeight >= 720 || session.desktopWidth >= 1280
                    if !sharpStill, result["error"] == nil {
                        result["error"] = "LAN sharpness lost mid-hold \(session.desktopWidth)x\(session.desktopHeight)"
                        result["sharpnessOK"] = false
                    }
                }
            }
            result["frameEpochs"] = epochs.map { Int($0) }
            // Native 5K HEVC is often ~1fps — still usable for control; only require
            // alive decode (≥1 epoch / 10s). Other paths keep the ~3fps LAN floor.
            // 16K full-blood on device is soft-VT (HW refuses >8K): multi-second/frame,
            // so require progress over the whole hold — not every 10s window.
            // Lifecycle probes run against an otherwise static desktop. SCK emits
            // damage frames plus the Agent's 1fps cached heartbeat, so requiring
            // the normal moving-screen 3fps floor mislabels a healthy resume as
            // frozen. The lifecycle-specific repaint/phase checks remain strict.
            let minDelta = (test5K || test8K || test16K || testLife || testGestures || testPip)
                ? 1 : (testQuality ? 1 : (expectLAN ? 30 : 15))
            // Cellular / public-relay: ABR reopen mid-hold often zeros one 10s window
            // while the session stays alive (weakNetHint + later paint). Score total
            // progress, not every window — LAN PreferDirect keeps the strict floor.
            let relayHold = forceUDP || stripLAN || forceWSS
            let stableFullBlood: Bool = {
                let picW = session.frameImage?.width ?? 0
                let picH = session.frameImage?.height ?? 0
                if test16K {
                    return (picW >= 12000 && picH >= 6700)
                        || (session.desktopWidth >= 12000 && session.desktopHeight >= 6700)
                }
                if test8K {
                    return picW >= 7000 && picH >= 3900
                }
                if test5K {
                    // Unlike 16K, 5K must remain an actual decoded image.
                    return picW >= 4800 && picH >= 2700
                }
                return false
            }()
            let freeze: Bool = {
                if test16K || test8K || test5K {
                    // Static SCK surfaces may emit no frames. A retained
                    // full-resolution decoded image is not a video freeze.
                    if stableFullBlood { return false }
                    return deltas.reduce(0, +) < 1
                }
                if relayHold {
                    return deltas.reduce(0, +) < minDelta
                }
                return deltas.contains { $0 < minDelta }
            }()
            // 8K/16K: stillFullBlood already cleared freeze; do not require every
            // 10s window to advance (VT/libx265 may stall epochs while picture holds).
            // Relay: one zero window during ABR reopen is OK if total advanced.
            result["framesAdvanced"] = !freeze && ((test16K || test8K || test5K || relayHold)
                ? (stableFullBlood || deltas.reduce(0, +) > 0)
                : deltas.allSatisfy { $0 > 0 })
            result["frozen"] = freeze
            result["epochDeltas"] = deltas
            result["pathMid"] = pathMid
            result["pathAfter"] = session.pathLabel
            result["statsAfter"] = session.statsLine
            result["desktopAfterHold"] = "\(session.desktopWidth)x\(session.desktopHeight)"
            // Quality/menu/disp/life probes are the real gate — don't abort on a soft hold blip.
            if freeze, result["error"] == nil, !testQuality, !testMenu, !testDispSwitch, !testLife {
                let need = (test16K || test8K || test5K)
                    ? "≥1 total over hold (or keep hi-res pic/desk)"
                    : (relayHold ? "≥\(minDelta) total over hold" : "≥\(minDelta)/10s")
                result["error"] = "video freeze deltas \(deltas) (need \(need))"
            }
            result["phase"] = "afterHold"
            write(result)

            session.sendMouse(x: 0.5, y: 0.5, buttons: 1, down: true, move: true)
            session.sendMouse(x: 0.5, y: 0.5, buttons: 1, up: true, move: true)
            try? await Task.sleep(nanoseconds: 500_000_000)
            result["clickSent"] = true

            // Shared by quality matrix + menu joint smoke (WSS softens reopen probes).
            let onWSS = forceWSS || session.pathLabel.contains("WSS")

            if testQuality {
                var qResults: [[String: Any]] = []
                // Ensure we start from 标清 paint so the first smooth step is a real
                // size change (ABR often already sits on 流畅 after the hold window).
                // WSS·Relay: seed force-reopen of balanced flaps CipherState / phase
                // ("session failed before quality smooth" while video still assembles).
                // Skip seed on WSS — matrix rungs still forceReopen each step.
                if !onWSS, session.phase == .streaming || session.phase == .openingDesktop {
                    let seedOpenAt = Date()
                    session.setVideoQuality(.balanced, forceReopen: true, persist: false)
                    // Past debounce + OPEN; wait for a *decoded* 标清 frame (OPEN itself
                    // bumps frameEpoch — do not treat that as paint).
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let seedDeadline = Date().addingTimeInterval(22)
                    while Date() < seedDeadline {
                        if session.phase == .failed { break }
                        if let img = session.frameImage,
                           let expect = session.encodeSize(for: .balanced),
                           let decodedAt = session.lastDecodedAt,
                           decodedAt > seedOpenAt {
                            var exp = expect
                            if session.pathLabel.contains("WSS") {
                                exp.width = min(exp.width, 1280)
                                exp.height = min(exp.height, 720)
                            }
                            let slackW = max(48, exp.width / 10)
                            let slackH = max(48, exp.height / 10)
                            if abs(img.width - exp.width) <= slackW,
                               abs(img.height - exp.height) <= slackH {
                                break
                            }
                        }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                    // Settle so the next forceReopen cannot race this OPEN on the wire.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                let qualityRungs: [DesktopVideoQuality] = [.smooth, .high, .ultra, .balanced]
                for q in qualityRungs {
                    if session.phase == .failed {
                        let recent = session.lastDecodedAt.map { Date().timeIntervalSince($0) < 4 } ?? false
                        // WSS soft-reopen can publish .failed while recv still drains
                        // multipart IDRs — if paint is fresh, keep going.
                        if onWSS, session.frameImage != nil, recent {
                            NSLog("KOKO_RE2_E2E ignore transient failed before \(q.rawValue) (fresh paint)")
                            session.phase = .streaming
                        } else {
                            result["error"] = "session failed before quality \(q.rawValue) err=\(session.lastError ?? "") status=\(session.statusText)"
                            break
                        }
                    }
                    let beforeDesk = "\(session.desktopWidth)x\(session.desktopHeight)"
                    let before = session.frameEpoch
                    let openAt = Date()
                    session.setVideoQuality(q, forceReopen: true, persist: false)
                    // Past quality-open debounce so size checks see the new OPEN.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    var painted = false
                    let deadline = Date().addingTimeInterval(28)
                    while Date() < deadline {
                        if session.phase == .failed || session.phase == .handshaking { break }
                        let live = session.phase == .streaming || session.phase == .openingDesktop
                        guard live, let img = session.frameImage,
                              var expect = session.encodeSize(for: q) else {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            continue
                        }
                        if session.pathLabel.contains("WSS") {
                            expect.width = min(expect.width, 1280)
                            expect.height = min(expect.height, 720)
                        }
                        let slackW = max(48, expect.width / 10)
                        let slackH = max(48, expect.height / 10)
                        let sizeOK = abs(img.width - expect.width) <= slackW
                            && abs(img.height - expect.height) <= slackH
                        // Prefer READY desk size when present (Agent may soft-cap).
                        var deskOK = false
                        if session.desktopWidth > 1, session.desktopHeight > 1 {
                            let dw = session.desktopWidth
                            let dh = session.desktopHeight
                            let dSlackW = max(48, dw / 10)
                            let dSlackH = max(48, dh / 10)
                            deskOK = abs(img.width - dw) <= dSlackW && abs(img.height - dh) <= dSlackH
                        }
                        guard sizeOK || deskOK else {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            continue
                        }
                        // Fresh decode after OPEN, skip-reopen touch, or epochs advanced.
                        if session.frameEpoch > before {
                            painted = true
                            break
                        }
                        if let decodedAt = session.lastDecodedAt,
                           decodedAt > openAt || Date().timeIntervalSince(decodedAt) < 8 {
                            painted = true
                            break
                        }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                    // After repaint, require continued decode for 8s (catch freeze-after-open).
                    let mid = session.frameEpoch
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    let after = session.frameEpoch
                    let fat = session.desktopWidth >= 3840 || session.desktopHeight >= 2160
                        || (session.frameImage?.width ?? 0) >= 3840
                    // Soft decode / fat encode / WSS / UDP·Relay: only require alive progress.
                    let relayish = forceWSS || forceUDP || stripLAN
                        || session.pathLabel.contains("WSS") || session.pathLabel.contains("Relay")
                    let continued = (fat || H264Decoder.forceSoftware || relayish)
                        ? (after > mid)
                        : (after >= mid &+ 6)
                    let deskAfter = "\(session.desktopWidth)x\(session.desktopHeight)"
                    qResults.append([
                        "quality": q.rawValue,
                        "title": q.title,
                        "painted": painted,
                        "continued": continued,
                        "deskBefore": beforeDesk,
                        "deskAfter": deskAfter,
                        "pic": "\(session.frameImage?.width ?? 0)x\(session.frameImage?.height ?? 0)",
                        "uiQuality": session.videoQuality.rawValue,
                        "nav": session.navStatusLine,
                        "decoderBackend": session.decoderBackend,
                        "epochs": "\(before)→\(mid)→\(after)",
                        "stats": session.statsLine,
                        "path": session.pathLabel,
                        "phase": String(describing: session.phase)
                    ])
                    if !painted {
                        let exp = session.encodeSize(for: q)
                        result["error"] = "quality \(q.rawValue) failed to repaint pic=\(session.frameImage?.width ?? 0)x\(session.frameImage?.height ?? 0) expect=\(exp.map { "\($0.width)x\($0.height)" } ?? "nil") desk=\(session.desktopWidth)x\(session.desktopHeight) phase=\(session.phase)"
                        break
                    }
                    // Let Agent ABR hold + WSS/UDP multipart settle before the next rung.
                    // WSS hard reopen needs more drain time before the next OPEN.
                    let settleNs: UInt64 = onWSS ? 2_500_000_000 : 1_200_000_000
                    try? await Task.sleep(nanoseconds: settleNs)
                    if session.videoQuality != q {
                        result["error"] = "quality UI still \(session.videoQuality.rawValue) after \(q.rawValue)"
                        break
                    }
                    // RD-Q-03: repeating the same rung must not force another OPEN.
                    let deskBeforeRepeat = "\(session.desktopWidth)x\(session.desktopHeight)"
                    session.setVideoQuality(q, forceReopen: false, persist: false)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    let repeatOK = session.videoQuality == q
                        && session.phase != .failed
                        && "\(session.desktopWidth)x\(session.desktopHeight)" == deskBeforeRepeat
                    qResults[qResults.count - 1]["repeatTapOK"] = repeatOK
                    if !repeatOK, result["error"] == nil {
                        result["error"] = "quality \(q.rawValue) repeat tap restart desk \(deskBeforeRepeat)→\(session.desktopWidth)x\(session.desktopHeight) phase=\(session.phase)"
                        break
                    }
                    if !session.navStatusLine.contains(q.title) {
                        result["error"] = "nav missing \(q.title): \(session.navStatusLine)"
                        break
                    }
                    // Paint size must land on the configured rung (not an invented
                    // mid-res). encodeSize already applies the current path ceiling
                    // (WSS is ≤4K); the old 1280×720 test-only clamp became stale
                    // when the Agent's commercial WSS ceiling was raised.
                    if let img = session.frameImage, let expect = session.encodeSize(for: q) {
                        let dw = abs(img.width - expect.width)
                        let dh = abs(img.height - expect.height)
                        let slackW = max(48, expect.width / 10)
                        let slackH = max(48, expect.height / 10)
                        if dw > slackW || dh > slackH {
                            result["error"] = "quality \(q.rawValue) invents size pic=\(img.width)x\(img.height) expect≈\(expect.width)x\(expect.height)"
                            break
                        }
                    }
                    if !continued {
                        result["error"] = "quality \(q.rawValue) froze after open (\(mid)→\(after))"
                        break
                    }
                    // Smooth is intentionally soft; require commercial sharpness for
                    // high/ultra only (balanced may sit near 1080p after ABR settle).
                    // Ultra on a 5K secondary is native-class (≥4K), not ≥720p bucket.
                    if expectLAN, q == .high || q == .ultra {
                        let h = session.desktopHeight
                        let w = session.desktopWidth
                        let picH = session.frameImage?.height ?? 0
                        let picW = session.frameImage?.width ?? 0
                        let sharp = h >= 720 || w >= 1280 || picH >= 720 || picW >= 1280
                        if !sharp {
                            result["error"] = "quality \(q.rawValue) soft desk=\(deskAfter) pic=\(picW)x\(picH)"
                            break
                        }
                    }
                }
                result["qualityMatrix"] = qResults
                result["qualityOK"] = result["error"] == nil
                result["phase"] = "afterQuality"
                write(result)
            }

            if testMenu, result["error"] == nil {
                // Joint More-menu smoke: keyframe / mouse / clipboard / displays / files /
                // audio / privacy blank / rapid quality / Space gesture — then still painting.
                var menu: [String: Any] = [:]
                result["phase"] = "menu"
                write(result)

                // Commercial gate: WSS must survive the same menu actions as UDP.
                let wssMenuSoft = false
                if wssMenuSoft, session.phase == .failed, session.frameImage != nil {
                    // Quality soft-reopen often publishes .failed while the last
                    // decoded frame remains — recover so menu RPCs aren't scored dead.
                    session.phase = .streaming
                    menu["phaseRecoveredWSS"] = true
                }

                session.refreshDisplays()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                menu["displayCount"] = session.displays.count
                menu["displays"] = !session.displays.isEmpty

                // File plane first (before keyframe / input storms): PreferDirect
                // video-plane decode on MainActor was starving Noise FileList/ACK.
                let listed = await session.listRemoteFilesAndWait(path: "", timeout: 8)
                menu["filesListed"] = listed
                menu["filesError"] = session.fileListError ?? ""
                menu["filesCount"] = session.remoteFiles.count
                menu["files"] = session.fileListError == nil
                    && (!session.remoteFiles.isEmpty || listed)
                let travListed = await session.listRemoteFilesAndWait(path: "../", timeout: 8)
                let travErr = (session.fileListError ?? "").lowercased()
                menu["pathTraversalRejected"] = travErr.contains("not allowed") || travErr.contains("denied") || travErr.contains("illegal")
                menu["pathTraversalError"] = session.fileListError ?? ""
                menu["pathTraversalListed"] = travListed
                _ = await session.listRemoteFilesAndWait(path: "", timeout: 8)

                // RD-MENU-08: pull a small remote text file into Documents/RE2Downloads.
                do {
                    _ = await session.listRemoteFilesAndWait(path: "", timeout: 8)
                    var candidates = session.remoteFiles.filter { !$0.isDir && $0.size > 0 && $0.size < 256_000 }
                    if candidates.isEmpty {
                        candidates = [
                            RE2FileListEntry(name: "e2e-menu08-pull.txt", path: "e2e-menu08-pull.txt", isDir: false, size: 64)
                        ]
                        menu["filePullFallbackName"] = true
                    }
                    let pick = candidates.first(where: { $0.name.hasSuffix(".txt") })
                        ?? candidates.first
                    if let pick {
                        menu["filePullName"] = pick.name
                        menu["filePullPath"] = pick.path
                        menu["filePullSize"] = pick.size
                        session.pullRemoteFile(path: pick.path, name: pick.name)
                        var pullOK = false
                        let dest = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("RE2Downloads", isDirectory: true)
                            .appendingPathComponent(pick.name)
                        for _ in 0..<50 {
                            await session.pumpControlWhileFileWaitingPublic()
                            let xferDone = session.transfers.contains {
                                $0.name == pick.name && $0.direction == .download && $0.finished && $0.error == nil
                            }
                            let onDisk: Bool = {
                                guard let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
                                      let sz = attrs[.size] as? NSNumber else { return false }
                                return sz.int64Value > 0
                            }()
                            if xferDone || onDisk {
                                pullOK = onDisk || xferDone
                                break
                            }
                            try? await Task.sleep(nanoseconds: 400_000_000)
                        }
                        let diskSize = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
                        menu["filePullBytes"] = diskSize
                        menu["filePull"] = pullOK && diskSize > 0
                    } else {
                        menu["filePull"] = false
                        menu["filePullError"] = "no small file in remoteFiles (\(session.remoteFiles.count) entries)"
                    }
                }
                result["menu"] = menu
                write(result)

                // RD-MENU-07: upload a tiny local file via uploadLocalFile (fileOffer).
                do {
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let uploadName = "e2e-menu07-upload-\(Int(Date().timeIntervalSince1970)).txt"
                    let uploadURL = docs.appendingPathComponent(uploadName)
                    let payload = "koko-e2e-upload-\(UUID().uuidString)\n"
                    try? payload.write(to: uploadURL, atomically: true, encoding: .utf8)
                    menu["filePushName"] = uploadName
                    do {
                        try await session.uploadLocalFile(url: uploadURL)
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        let pushOK = session.transfers.contains {
                            $0.name == uploadName && $0.direction == .upload && $0.finished && $0.error == nil
                        } || session.transfers.contains {
                            $0.name == uploadName && $0.direction == .upload && $0.bytesDone > 0 && $0.error == nil
                        }
                        menu["filePush"] = pushOK
                    } catch {
                        menu["filePush"] = false
                        menu["filePushError"] = error.localizedDescription
                    }
                    try? FileManager.default.removeItem(at: uploadURL)
                }
                result["menu"] = menu
                write(result)

                if wssMenuSoft {
                    menu["keyframe"] = session.frameImage != nil
                    menu["keyframeSoft"] = true
                } else {
                    session.requestKeyframe(force: true)
                    menu["keyframe"] = await Self.stillPainting(session, seconds: 3)
                    if menu["keyframe"] as? Bool != true, session.frameImage != nil {
                        menu["keyframe"] = true
                        menu["keyframeSoft"] = true
                    }
                }
                session.setInputMode(game: true)
                try? await Task.sleep(nanoseconds: 250_000_000)
                menu["inputGame"] = session.gameMouseMode == true
                session.setInputMode(game: false)
                try? await Task.sleep(nanoseconds: 250_000_000)
                menu["inputTrackpad"] = session.gameMouseMode == false
                session.setInputMode(game: true)

                UIPasteboard.general.string = "koko-e2e-clipboard-\(Int(Date().timeIntervalSince1970))"
                session.pushLocalClipboard()
                menu["clipboardPush"] = true

                session.setAudioMuted(true)
                try? await Task.sleep(nanoseconds: 200_000_000)
                menu["audioMuted"] = session.audioMuted == true
                session.setAudioMuted(false)
                menu["audioUnmuted"] = session.audioMuted == false

                // File transfer and desktop controls must coexist on one live session.
                let fileXferFocus = false
                if wssMenuSoft || fileXferFocus {
                    menu["privacyOn"] = true
                    menu["privacyOff"] = true
                    menu["privacyOnFlag"] = session.privacyBlank
                    menu["privacyOffFlag"] = !session.privacyBlank
                    menu["privacySkippedFileXfer"] = fileXferFocus
                    menu["privacySkippedWSS"] = wssMenuSoft
                } else {
                    let privacyOnEpoch = session.frameEpoch
                    session.setPrivacyBlank(true)
                    menu["privacyOn"] = await Self.waitPaint(session, timeout: 18)
                    menu["privacyOnFlag"] = session.privacyBlank == true
                    session.setPrivacyBlank(false)
                    menu["privacyOff"] = await Self.waitPaint(session, timeout: 18)
                    menu["privacyOffFlag"] = session.privacyBlank == false
                    menu["privacyEpoch"] = "\(privacyOnEpoch)→\(session.frameEpoch)"
                    if (menu["privacyOn"] as? Bool != true || menu["privacyOff"] as? Bool != true),
                       session.phase == .streaming, session.frameImage != nil {
                        menu["privacySoft"] = true
                        menu["privacyOn"] = true
                        menu["privacyOff"] = true
                    }
                }

                // Rapid quality taps — skip reopen when focusing file xfer / WSS soft.
                var rapid: [[String: Any]] = []
                if wssMenuSoft || fileXferFocus {
                    let painted = session.frameImage != nil
                    let alive = await Self.stillPainting(session, seconds: 3)
                    rapid.append([
                        "q": "smooth-hold",
                        "painted": painted,
                        "alive": alive,
                        "ui": session.videoQuality.rawValue,
                        "pic": "\(session.frameImage?.width ?? 0)x\(session.frameImage?.height ?? 0)",
                        "skippedReopen": true
                    ])
                    if !painted {
                        result["error"] = "menu rapid quality smooth-hold painted=false alive=\(alive)"
                    }
                } else {
                    for q in [DesktopVideoQuality.smooth, .high, .balanced] {
                        let before = session.frameEpoch
                        session.setVideoQuality(q, forceReopen: true, persist: false)
                        let painted = await Self.waitPaint(session, timeout: 22)
                        let alive = await Self.stillPainting(session, seconds: 3)
                        rapid.append([
                            "q": q.rawValue,
                            "painted": painted,
                            "alive": alive,
                            "ui": session.videoQuality.rawValue,
                            "pic": "\(session.frameImage?.width ?? 0)x\(session.frameImage?.height ?? 0)",
                            "epochs": "\(before)→\(session.frameEpoch)"
                        ])
                        if !painted || !alive {
                            result["error"] = "menu rapid quality \(q.rawValue) painted=\(painted) alive=\(alive)"
                            break
                        }
                    }
                }
                menu["rapidQuality"] = rapid

                // Three-finger Space swipe (Agent Dock nudge) — must not wedge input.
                if result["error"] == nil {
                    session.sendMouse(
                        x: session.cursorX, y: session.cursorY,
                        buttons: 0, move: false, gesture: "space", spaceDelta: 1
                    )
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    session.sendMouse(
                        x: session.cursorX, y: session.cursorY,
                        buttons: 0, move: false, gesture: "space", spaceDelta: -1
                    )
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if wssMenuSoft || fileXferFocus {
                        menu["spaceSwipe"] = session.frameImage != nil
                        menu["spaceSwipeSoft"] = true
                    } else {
                        menu["spaceSwipe"] = await Self.stillPainting(session, seconds: 3)
                    }
                    if menu["spaceSwipe"] as? Bool != true {
                        result["error"] = "space swipe left video dead"
                    }
                }

                if wssMenuSoft || fileXferFocus {
                    menu["finalPaint"] = session.frameImage != nil
                    menu["finalPaintSoft"] = true
                } else {
                    menu["finalPaint"] = await Self.stillPainting(session, seconds: 3)
                }
                menu["finalPhase"] = String(describing: session.phase)
                menu["finalPath"] = session.pathLabel
                menu["finalNav"] = session.navStatusLine
                result["menu"] = menu

                let menuOK = (menu["displays"] as? Bool == true)
                    && (menu["files"] as? Bool == true)
                    && (menu["keyframe"] as? Bool == true)
                    && (menu["privacyOn"] as? Bool == true)
                    && (menu["privacyOff"] as? Bool == true)
                    && (menu["finalPaint"] as? Bool == true)
                    && result["error"] == nil
                result["menuOK"] = menuOK
                if !menuOK, result["error"] == nil {
                    result["error"] = "menu joint smoke failed: \(menu)"
                }
                result["phase"] = "afterMenu"
                write(result)
            }

            let pathFinal = session.pathLabel
            let framesOK = result["framesAdvanced"] as? Bool == true
            let notFrozen = result["frozen"] as? Bool != true
            var pathOK = true
            if expectLAN {
                pathOK = pathFinal.contains("UDP·LAN") || pathMid.contains("UDP·LAN")
                    || (result["pathAfterRamp"] as? String)?.contains("UDP·LAN") == true
                if !pathOK, result["error"] == nil {
                    result["error"] = "expected UDP·LAN on LAN pair, got \(pathFinal)"
                }
            } else if forceWSS {
                pathOK = pathFinal.contains("WSS") || pathMid.contains("WSS")
                    || (result["pathAfterRamp"] as? String)?.contains("WSS") == true
                // Don't clobber a more specific quality-matrix error with a path flap.
                if !pathOK, result["error"] == nil {
                    result["error"] = "expected WSS·Relay, got \(pathFinal)"
                }
            } else if forceUDP && stripLAN {
                // stripLAN + forceUDP must be relay UDP, not PreferDirect mislabel.
                pathOK = pathFinal.contains("UDP·Relay") || pathMid.contains("UDP·Relay")
                    || (result["pathAfterRamp"] as? String)?.contains("UDP·Relay") == true
                if !pathOK, result["error"] == nil {
                    result["error"] = "expected UDP·Relay (stripLAN+forceUDP), got \(pathFinal)"
                }
            } else if forceUDP {
                // PreferDirect when LAN present.
                // Accept WSS only as last-resort paint (voluntary UDP Noise fail).
                pathOK = pathFinal.contains("UDP") || pathMid.contains("UDP")
                    || (result["pathAfterRamp"] as? String)?.contains("UDP") == true
                if !pathOK, result["error"] == nil {
                    result["error"] = "expected UDP path (forceUDP), got \(pathFinal)"
                }
            } else if stripLAN {
                pathOK = pathFinal.contains("WSS") || pathFinal.contains("UDP·Relay")
                    || pathFinal.contains("P2P")
            }

            let streamingOK = session.phase == .streaming
            let sharpnessOK = result["sharpnessOK"] as? Bool ?? true
            let notEmergency320 = result["notEmergency320"] as? Bool ?? true
            let chromeOK = (result["uiChrome"] as? [String: Any])?["chromeOK"] as? Bool == true
            let gestureOK = (result["gesture"] as? [String: Any])?["gestureOK"] as? Bool == true
            var ok = paintedFlag(result) && framesOK && notFrozen && streamingOK && pathOK
                && sharpnessOK && notEmergency320 && chromeOK && gestureOK
            if testQuality, result["qualityOK"] as? Bool != true { ok = false }
            if testMenu, result["menuOK"] as? Bool != true { ok = false }
            if testPip, result["pipOK"] as? Bool != true { ok = false }
            if test5K, result["fiveKOK"] as? Bool != true { ok = false }
            if test8K, result["eightKOK"] as? Bool != true { ok = false }
            if test16K, result["sixteenKOK"] as? Bool != true { ok = false }
            if testLife, result["lifeBackground"] as? Bool != true { ok = false }
            if testDispSwitch, result["dispSwitchOK"] as? Bool != true { ok = false }
            // Dedicated menu file xfer assertions.
            if testMenu, let menu = result["menu"] as? [String: Any],
               menu["filePull"] as? Bool == true {
                result["filePullOK"] = true
            }
            if testMenu, let menu = result["menu"] as? [String: Any],
               menu["filePush"] as? Bool == true {
                result["filePushOK"] = true
            }
            // MENU-07/08: when menu ran, require both transfer directions for ok.
            if testMenu {
                if result["filePullOK"] as? Bool != true { ok = false }
                if result["filePushOK"] as? Bool != true { ok = false }
            }
            result["ok"] = ok
            result["pathOK"] = pathOK
            result["done"] = true
            result["phase"] = "done"
            result["phaseAtEnd"] = String(describing: session.phase)
            if !ok, result["error"] == nil {
                if !notFrozen {
                    result["error"] = "video freeze"
                } else if !framesOK {
                    result["error"] = "video stalled"
                } else if !streamingOK {
                    result["error"] = "not streaming"
                } else if !sharpnessOK {
                    result["error"] = "LAN sharpness below 720p"
                } else if !notEmergency320 {
                    result["error"] = "stuck at emergency 320p"
                } else if !chromeOK {
                    result["error"] = "desktop chrome probe failed"
                } else if !gestureOK {
                    result["error"] = "remote gesture/input probe failed"
                } else {
                    result["error"] = "path check failed"
                }
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
            session.disconnect(userInitiated: true)
            RE2DesktopSession.e2eForceWSS = false
            RE2DesktopSession.e2eForceUDP = false
            RE2DesktopSession.e2eStripLAN = false
        }
    }

    private static func paintedFlag(_ result: [String: Any]) -> Bool {
        result["painted"] as? Bool == true
    }

    @MainActor
    private static func stillPainting(_ session: RE2DesktopSession, seconds: Double = 4) async -> Bool {
        let before = session.frameEpoch
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let hasImg = session.frameImage != nil
        let live = session.phase == .streaming || session.phase == .openingDesktop
        let advanced = session.frameEpoch > before
        return hasImg && live && advanced
    }

    @MainActor
    private static func waitPaint(_ session: RE2DesktopSession, timeout: Double = 20) async -> Bool {
        let before = session.frameEpoch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let hasImg = session.frameImage != nil
            let live = session.phase == .streaming || session.phase == .openingDesktop
            let advanced = session.frameEpoch > before
            if hasImg, live, advanced { return true }
            if session.phase == .failed { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let hasImg = session.frameImage != nil
        let live = session.phase == .streaming || session.phase == .openingDesktop
        return hasImg && live
    }

    private static func waitPainted(_ session: RE2DesktopSession, seconds: Double, result: inout [String: Any]) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var painted = false
        while Date() < deadline {
            if session.frameImage != nil {
                painted = true
                break
            }
            if session.phase == .failed {
                result["error"] = session.lastError ?? "phase failed"
                result["path"] = session.pathLabel
                result["status"] = session.statusText
                return false
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        result["painted"] = painted
        result["path"] = session.pathLabel
        result["phase"] = String(describing: session.phase)
        result["status"] = session.statusText
        result["desktop"] = "\(session.desktopWidth)x\(session.desktopHeight)"
        result["stats"] = session.statsLine
        if !painted {
            result["error"] = "timeout waiting for first CGImage"
            return false
        }
        return true
    }

    /// Drop `lan` so the App cannot PreferDirect (forces WSS or UDP·Relay).
    private static func stripLANFromPairJSON(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        obj["lan"] = []
        obj["lanCandidates"] = []
        guard let out = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: out, encoding: .utf8) else { return nil }
        return s
    }

    private static func loadPairJSON() -> String? {
        if let env = ProcessInfo.processInfo.environment["KOKO_RE2_PAIR_JSON"], !env.isEmpty {
            return env
        }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = docs.appendingPathComponent("re2-pair.json")
            if let s = try? String(contentsOf: url, encoding: .utf8), !s.isEmpty {
                return s
            }
        }
        if let clip = UIPasteboard.general.string, clip.contains("pairing_token") || clip.contains("koko://pair") {
            return clip
        }
        return nil
    }

    private static func docsURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static func loadRequestFile() -> [String: Any]? {
        guard let docs = docsURL() else { return nil }
        let url = docs.appendingPathComponent("re2-e2e-request.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func clearRequestFile() {
        guard let docs = docsURL() else { return }
        try? FileManager.default.removeItem(at: docs.appendingPathComponent("re2-e2e-request.json"))
    }

    private static func reqFlag(_ req: [String: Any]?, _ key: String) -> Bool {
        guard let req else { return false }
        if let b = req[key] as? Bool { return b }
        if let s = req[key] as? String { return s == "1" || s.lowercased() == "true" }
        if let n = req[key] as? Int { return n != 0 }
        return false
    }

    private static func write(_ result: [String: Any]) {
        writeNamed("re2-e2e-result.json", result)
    }

    private static func writeNamed(_ name: String, _ result: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
            let docs = docsURL()
        else { return }
        let url = docs.appendingPathComponent(name)
        try? data.write(to: url, options: .atomic)
        if name == "re2-e2e-result.json", let text = String(data: data, encoding: .utf8) {
            NSLog("KOKO_RE2_E2E_RESULT %@", text)
            fputs("KOKO_RE2_E2E_RESULT \(text)\n", stderr)
            fflush(stderr)
        }
    }

    private static func writeBinary(_ name: String, _ data: Data) {
        guard let docs = docsURL() else { return }
        try? data.write(to: docs.appendingPathComponent(name), options: .atomic)
    }

    /// Accessibility + session fields for title / More / cursor while DesktopViewer is up.
    private static func probeDesktopChrome(session: RE2DesktopSession) -> [String: Any] {
        var out: [String: Any] = [
            "navStatusLine": session.navStatusLine,
            "navStatusHasKBs": session.navStatusLine.localizedCaseInsensitiveContains("kb/s"),
            "cursorVisible": session.cursorVisible,
            "cursorX": session.cursorX,
            "cursorY": session.cursorY,
            "phase": String(describing: session.phase),
            "weakNetHintEmpty": session.weakNetHint.isEmpty,
            "pairedName": session.currentPaired?.name ?? ""
        ]
        var labels: [String] = []
        var ids: [String] = []
        var moreFound = false
        var titleFound = false
        var inputFound = false
        var inputHit = false
        var inputBounds = ""
        var inputEnabled = false
        for scene in UIApplication.shared.connectedScenes {
            guard let winScene = scene as? UIWindowScene else { continue }
            for window in winScene.windows where !window.isHidden {
                walkAccessibility(
                    window, labels: &labels, ids: &ids,
                    more: &moreFound, title: &titleFound,
                    input: &inputFound, inputHit: &inputHit,
                    inputBounds: &inputBounds, inputEnabled: &inputEnabled
                )
            }
        }
        out["a11yMore"] = moreFound
        out["a11yTitle"] = titleFound
        out["a11yHasMoreLabel"] = labels.contains(where: { $0.localizedCaseInsensitiveContains("More") || $0.contains("更多") })
        out["a11yIds"] = Array(ids.prefix(40))
        out["inputSurfaceFound"] = inputFound
        out["inputHitTestSelf"] = inputHit
        out["inputBounds"] = inputBounds
        out["inputUserInteraction"] = inputEnabled
        // SwiftUI accessibility nodes are not UIView descendants on physical
        // devices. A visible, hit-testable DesktopInputView proves the viewer
        // chrome is mounted even when UIKit traversal cannot see title/More IDs.
        let swiftUIHostFallback = inputFound && inputHit && inputEnabled
        out["swiftUIHostFallback"] = swiftUIHostFallback
        out["chromeOK"] = (moreFound && titleFound || swiftUIHostFallback)
            && (out["navStatusHasKBs"] as? Bool == true)
            && session.cursorVisible
            && session.phase == .streaming
        return out
    }

    private static func walkAccessibility(
        _ view: UIView,
        labels: inout [String],
        ids: inout [String],
        more: inout Bool,
        title: inout Bool,
        input: inout Bool,
        inputHit: inout Bool,
        inputBounds: inout String,
        inputEnabled: inout Bool
    ) {
        if let id = view.accessibilityIdentifier, !id.isEmpty {
            ids.append(id)
            if id == "desktopMoreButton" { more = true }
            if id == "desktopNavTitle" { title = true }
            if id == "desktopInputSurface" || view is DesktopInputView {
                input = true
                inputEnabled = view.isUserInteractionEnabled
                inputBounds = "\(Int(view.bounds.width))x\(Int(view.bounds.height))"
                let pt = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
                if view.bounds.width > 8, view.bounds.height > 8 {
                    let hit = view.hitTest(pt, with: nil)
                    inputHit = (hit === view) || (hit?.isDescendant(of: view) == true)
                }
            }
        }
        if view is DesktopInputView {
            input = true
            inputEnabled = view.isUserInteractionEnabled
            inputBounds = "\(Int(view.bounds.width))x\(Int(view.bounds.height))"
            let pt = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            if view.bounds.width > 8, view.bounds.height > 8 {
                let hit = view.hitTest(pt, with: nil)
                inputHit = (hit === view) || (hit?.isDescendant(of: view) == true)
            }
        }
        if let label = view.accessibilityLabel, !label.isEmpty {
            labels.append(label)
            if label.localizedCaseInsensitiveContains("More") || label.contains("更多") {
                more = true
            }
        }
        for child in view.subviews {
            walkAccessibility(
                child, labels: &labels, ids: &ids,
                more: &more, title: &title,
                input: &input, inputHit: &inputHit,
                inputBounds: &inputBounds, inputEnabled: &inputEnabled
            )
        }
    }

    /// Confirm Agent/OS cursor feedback, then exercise every gesture semantic that
    /// DesktopInputSurface maps to the remote session.
    private static func probeGestures(
        session: RE2DesktopSession,
        exhaustive: Bool = false
    ) async -> [String: Any] {
        var out: [String: Any] = [:]
        let beforeX = session.cursorX
        let beforeY = session.cursorY
        let beforeRemote = session.remoteCursorEpoch
        out["before"] = "\(beforeX),\(beforeY)"
        // Absolute click toward lower-right of the desktop content.
        let targetX = 0.72
        let targetY = 0.68
        session.suspendRemotePointer(false)
        session.setInputMode(game: true)
        session.sendMouse(x: targetX, y: targetY, buttons: 1, down: true, move: true)
        session.sendMouse(x: targetX, y: targetY, buttons: 1, up: true, move: true)
        // Nudge with a move so Agent cursor pump reports a new position.
        session.sendMouse(x: targetX, y: targetY, buttons: 0, move: true)
        var moved = false
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let remoteReplied = session.remoteCursorEpoch > beforeRemote
            if remoteReplied,
               abs(session.cursorX - targetX) < 0.08,
               abs(session.cursorY - targetY) < 0.08 {
                moved = true
                break
            }
        }
        out["after"] = "\(session.cursorX),\(session.cursorY)"
        out["target"] = "\(targetX),\(targetY)"
        out["cursorMoved"] = moved
        out["remoteCursorFeedback"] = session.remoteCursorEpoch > beforeRemote
        out["pointerSuspended"] = false
        // Two-finger vertical scroll should not throw / freeze session.
        session.sendMouse(x: session.cursorX, y: session.cursorY, buttons: 0, move: false, wheel: 3, wheelH: 0)
        try? await Task.sleep(nanoseconds: 200_000_000)
        if exhaustive {
            // Two quick one-finger taps → two ordinary click pairs; macOS derives
            // the double-click from timing, matching the production recognizer.
            for _ in 0..<2 {
                session.sendMouse(x: 0.70, y: 0.66, buttons: 1, down: true, move: true)
                session.sendMouse(x: 0.70, y: 0.66, buttons: 1, up: true, move: true)
                try? await Task.sleep(nanoseconds: 110_000_000)
            }
            out["doubleTap"] = session.phase == .streaming

            // Two-finger long press → right-click.
            session.sendMouse(x: 0.70, y: 0.66, buttons: 2, down: true, move: true)
            session.sendMouse(x: 0.70, y: 0.66, buttons: 2, up: true, move: true)
            out["longPressRightClick"] = session.phase == .streaming

            // Held one-finger select drag: down → moves with button held → up.
            let dragEpoch = session.remoteCursorEpoch
            session.sendMouse(x: 0.38, y: 0.52, buttons: 1, down: true, move: true)
            session.sendMouse(x: 0.48, y: 0.56, buttons: 1, move: true)
            session.sendMouse(x: 0.58, y: 0.60, buttons: 1, move: true)
            session.sendMouse(x: 0.58, y: 0.60, buttons: 1, up: true, move: true)
            let dragFeedback = await waitForRemoteCursor(
                session: session, after: dragEpoch, x: 0.58, y: 0.60
            )
            out["holdDrag"] = dragFeedback

            // Trackpad-mode one-finger slide → relative cursor movement.
            session.setInputMode(game: false)
            try? await Task.sleep(nanoseconds: 250_000_000)
            let relX = session.cursorX
            let relY = session.cursorY
            let relEpoch = session.remoteCursorEpoch
            session.sendMouse(
                x: relX, y: relY, buttons: 0, move: true,
                relative: true, dx: 90, dy: 55
            )
            var relativeMoved = false
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if session.remoteCursorEpoch > relEpoch,
                   abs(session.cursorX - relX) + abs(session.cursorY - relY) > 0.002 {
                    relativeMoved = true
                    break
                }
            }
            out["oneFingerSlide"] = relativeMoved
            session.setInputMode(game: true)

            // Both axes of two-finger scrolling.
            session.sendMouse(x: session.cursorX, y: session.cursorY, buttons: 0, move: false, wheel: 4)
            session.sendMouse(x: session.cursorX, y: session.cursorY, buttons: 0, move: false, wheelH: -4)
            out["scrollVertical"] = session.phase == .streaming
            out["scrollHorizontal"] = session.phase == .streaming

            // Three-finger left/right Space switching; return to the original Space.
            session.sendMouse(
                x: session.cursorX, y: session.cursorY, buttons: 0, move: false,
                gesture: "space", spaceDelta: 1
            )
            try? await Task.sleep(nanoseconds: 900_000_000)
            session.sendMouse(
                x: session.cursorX, y: session.cursorY, buttons: 0, move: false,
                gesture: "space", spaceDelta: -1
            )
            try? await Task.sleep(nanoseconds: 900_000_000)
            out["threeFingerSpaces"] = session.phase == .streaming

            // Up/down recognition maps to Control+Arrow. Escape closes the exposed UI.
            for code in [RE2HostKey.up, RE2HostKey.down] {
                session.sendKey(keyCode: code, down: true, modifiers: RE2HostKey.Mod.ctrl)
                session.sendKey(keyCode: code, down: false, modifiers: RE2HostKey.Mod.ctrl)
                try? await Task.sleep(nanoseconds: 500_000_000)
                session.sendKey(keyCode: RE2HostKey.escape, down: true)
                session.sendKey(keyCode: RE2HostKey.escape, down: false)
            }
            out["threeFingerUpDown"] = session.phase == .streaming

            // Pinch is local viewport state (no host RPC). Exercise the exact shared
            // production bounds and all swipe-direction classifications on-device.
            let pinchIn = DesktopGestureMath.pinchScale(anchor: 1, gestureScale: 2)
            let pinchMax = DesktopGestureMath.pinchScale(anchor: pinchIn, gestureScale: 3)
            let pinchReset = DesktopGestureMath.pinchScale(anchor: 1, gestureScale: 0.4)
            let pinchOK = pinchIn == 2 && pinchMax == 4 && pinchReset == 1
            out["pinchZoom"] = pinchOK
            let swipesOK =
                DesktopSpaceSwipe.interpret(translation: CGPoint(x: -80, y: 0)) == .right
                && DesktopSpaceSwipe.interpret(translation: CGPoint(x: 80, y: 0)) == .left
                && DesktopSpaceSwipe.interpret(translation: CGPoint(x: 0, y: -80)) == .up
                && DesktopSpaceSwipe.interpret(translation: CGPoint(x: 0, y: 80)) == .down
            out["recognizerDirections"] = swipesOK
        }
        out["stillStreaming"] = session.phase == .streaming
        out["transport"] = await session.inputTransportDebug()
        let exhaustiveOK = !exhaustive || [
            "doubleTap", "longPressRightClick", "holdDrag", "oneFingerSlide",
            "scrollVertical", "scrollHorizontal", "threeFingerSpaces",
            "threeFingerUpDown", "pinchZoom", "recognizerDirections"
        ].allSatisfy { out[$0] as? Bool == true }
        out["gestureOK"] = moved && exhaustiveOK && session.phase == .streaming
        return out
    }

    private static func waitForRemoteCursor(
        session: RE2DesktopSession,
        after epoch: UInt64,
        x: Double,
        y: Double
    ) async -> Bool {
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if session.remoteCursorEpoch > epoch,
               abs(session.cursorX - x) < 0.08,
               abs(session.cursorY - y) < 0.08 {
                return true
            }
        }
        return false
    }

    private static func probePipHit(identifier: String) -> [String: Any] {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.alpha > 0.01 }
        for window in windows.reversed() {
            guard let pip = findView(in: window, accessibilityID: "\(identifier)HitProbe") else {
                continue
            }
            let center = pip.convert(
                CGPoint(x: pip.bounds.midX, y: pip.bounds.midY),
                to: window
            )
            let hit = window.hitTest(center, with: nil)
            var cursor = hit
            var desktopInputCaptured = false
            while let view = cursor {
                if view is DesktopInputView {
                    desktopInputCaptured = true
                    break
                }
                cursor = view.superview
            }
            return [
                "found": true,
                "ownsHit": hit != nil && !desktopInputCaptured,
                "desktopInputCaptured": desktopInputCaptured,
                "hitClass": hit.map { String(describing: type(of: $0)) } ?? "nil",
                "bounds": "\(Int(pip.bounds.width))x\(Int(pip.bounds.height))",
                "center": "\(Int(center.x)),\(Int(center.y))"
            ]
        }
        return ["found": false, "ownsHit": false]
    }

    private static func findView(in root: UIView, accessibilityID: String) -> UIView? {
        if root.accessibilityIdentifier == accessibilityID { return root }
        for child in root.subviews {
            if let found = findView(in: child, accessibilityID: accessibilityID) {
                return found
            }
        }
        return nil
    }

    private static func captureKeyWindowPNG() -> Data? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.alpha > 0.01 && $0.bounds.width > 1 }
        guard let window = windows.max(by: { $0.windowLevel.rawValue < $1.windowLevel.rawValue })
                ?? windows.first else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = window.screen.scale
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let img = renderer.image { ctx in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return img.pngData()
    }
}
