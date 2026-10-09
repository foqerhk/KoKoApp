import Foundation
import CryptoKit
import CoreGraphics
import UIKit
import Darwin
import Network

/// Full RE2.1 remote-desktop session (handoff-complete client path).
@MainActor
final class RE2DesktopSession: ObservableObject {
    @Published var phase: RE2ConnectionPhase = .idle
    @Published var statusText: String = ""
    @Published var lastError: String?
    @Published var recoveryHint: String?
    @Published var desktopWidth: Int = 0
    @Published var desktopHeight: Int = 0
    @Published var cursorX: Double = 0.5
    @Published var cursorY: Double = 0.5
    @Published var cursorVisible: Bool = true
    @Published var frameImage: CGImage?
    /// Assembler / hold progress for E2E and black-screen diagnosis.
    var assemblerProgress: String { videoAssembler.progressLabel }
    /// E2E counters (reset on display/quality reopen).
    private(set) var debugVideoPartsRX: Int = 0
    private(set) var debugFramesAssembled: Int = 0
    private(set) var debugFramesDecoded: Int = 0
    private(set) var debugAssemblerPeak: String = "-"
    var decoderLastError: String { decoder.lastError }
    var decoderBackend: String { decoder.lastSessionBackend }

    private func resetVideoDebugCounters() {
        debugVideoPartsRX = 0
        debugFramesAssembled = 0
        debugFramesDecoded = 0
        debugAssemblerPeak = "-"
    }
    /// Bumped on every decoded frame so SwiftUI cannot coalesce identical-looking images.
    @Published var frameEpoch: UInt64 = 0
    @Published var displays: [RE2DisplayInfo] = []
    @Published var selectedDisplayID: Int = 0
    /// Last display the user / OPEN asked for (always sent, including primary 0).
    private var desiredDisplayID: Int = 0
    /// display_id confirmed by DESKTOP_READY for the current `sessionID` only.
    private var confirmedDisplayID: Int?
    @Published var transfers: [RE2TransferProgress] = []
    @Published var remoteFiles: [RE2FileListEntry] = []
    @Published var remotePath: String = ""
    @Published var fileListError: String?
    @Published var usingP2P: Bool = false
    @Published var gameMouseMode: Bool = true
    @Published var privacyBlank: Bool = false
    @Published var statsLine: String = ""
    /// Weak-net UX: non-empty after a real paint stall or sustained delivery loss.
    @Published var weakNetHint: String = ""
    /// Receive rate for nav subtitle (kilobytes/s).
    @Published var statsKbPerSec: Int = 0
    /// Encode ladder (persisted). Applied on OPEN and when changed mid-session.
    @Published var videoQuality: DesktopVideoQuality = .stored
    /// Debug path: `WSS · Relay` / `UDP · Relay` / `P2P · LAN` / `P2P`.
    @Published var pathLabel: String = ""
    /// Agent LAN advertise / live PreferDirect peer (`host:port`) for host-list verification.
    @Published var lanEndpointsDisplay: String = ""
    /// Remote audio muted (local only).
    @Published var audioMuted: Bool = false
    /// Host mic TCC (`nil` = older Agent, treat as allowed).
    @Published var hostMicAuthorized: Bool?
    /// Host camera TCC (`nil` = older Agent, treat as allowed).
    @Published var hostCameraAuthorized: Bool?
    /// Remote desktop camera streaming (Agent host camera → phone preview).
    @Published var cameraOn: Bool = false
    @Published var cameraPreview: UIImage?
    @Published var cameraError: String?
    /// Phone-as-webcam (phone camera → Agent virtual webcam "KoKo Phone Camera").
    @Published var phoneWebcamOn: Bool = false
    @Published var phoneWebcamDeviceName: String = ""
    @Published var phoneWebcamError: String?
    let phoneCamera = PhoneCameraStreamer()
    private var remoteCameras: [(id: String, name: String)] = []
    /// Assemble chunked CAMERA_FRAME (Agent splits MJPEG to fit REUDP MaxPayload).
    private var cameraFrameID: UInt32?
    private var cameraFrameParts: [Int: Data] = [:]
    private var cameraFrameExpected: Int = 0
    private var phoneCamOutFrameID: UInt32 = 0
    /// Last finished download URL for Share sheet.
    @Published var lastDownloadURL: URL?
    /// Last successful direct peer host:port (for LAN vs WAN P2P labeling).
    private var directPeerHostPort: String = ""

    private var signaling: RE2SignalingClient?
    private var endpoint: REUDPEndpoint?
    private var sendCipher: NoiseCipherState? {
        didSet {
            guard sendCipher !== oldValue, !ptyRoutes.isEmpty else { return }
            // Agent PTYs are bound to the Noise session that opened them.
            let routes = ptyRoutes
            ptyRoutes.removeAll()
            routes.values.forEach { $0.onClose("tunnel_reset") }
        }
    }
    private var recvCipher: NoiseCipherState?
    /// Gap-tolerant video AEAD (UDP only). Nil on WSS / legacy peers.
    private var videoMedia: RE2VideoMedia?
    /// Agent echoed video_plane=1 in DESKTOP_READY.
    private var videoPlaneActive = false
    private var sessionID: String = ""
    private var deviceID: String = ""
    private var pairingToken: String = ""
    private var accessPassword: String?
    private var pinnedNoisePub: Data?
    private var videoAssembler = VideoFrameAssembler()
    private let decoder = H264Decoder()
    private let stats = RE2StatsTracker()
    private let audio = RE2AudioPlayer()
    private var recvTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var paired: PairedDesktop?
    private var autoReconnect = true
    /// Next BIND displaces another phone (user confirmed). Cleared once a BIND succeeds.
    private var forceTakeover = false
    private var reconnectAttempts = 0
    /// Consecutive BIND/ASSOC ticket rejections (relay in-memory tickets).
    private var ticketAuthFailures = 0
    /// True once we have been streaming in this connection generation.
    private var hadActiveDesktop = false
    private var incomingFiles: [String: (name: String, handle: FileHandle, total: Int64)] = [:]
    private var uploadAcks: [String: CheckedContinuation<Void, Error>] = [:]
    /// ACKs that arrived before uploadLocalFile registered a waiter (LAN race).
    private var pendingUploadAcks: [String: (ok: Bool, error: String?)] = [:]
    /// FileList reply generation — bumps on every LIST response (incl. empty / error).
    private var fileListReplyGen: UInt64 = 0
    private var fileListWaiter: CheckedContinuation<Bool, Never>?
    /// When UDP Noise stalls, fall back to WSS TypeNoise + TypeTunnel.
    private var useWSSTunnel = false
    /// Consecutive WSS tunnel decrypt failures — Noise nonce desync → permanent freeze.
    private var wssDecryptFailures = 0
    private var isRecoveringWSS = false
    /// Soft re-OPEN budget after decrypt junk (avoid reopen spin).
    private var wssSoftReopenCount = 0
    /// Full WSS Noise re-handshake budget (desync → idle timeout + dead input).
    private var wssNoiseRecoverCount = 0
    private var lastWSSNoiseRecoverAt: Date?
    /// Throttle keyframe asks while a frozen picture is on screen.
    private var lastKeyframeAskAt: Date?
    /// Agent cursor heartbeat is authenticated and arrives even when a static
    /// ScreenCaptureKit surface legitimately emits no video frames.
    private var lastCursorHeartbeatAt: Date?
    /// Distinguishes optimistic local cursor updates from Agent/OS feedback in E2E.
    private(set) var remoteCursorEpoch: UInt64 = 0

    /// Simulator E2E force path (see RE2E2EAutoConnect).
    static var e2eForceWSS = false
    static var e2eForceUDP = false
    /// E2E stripLAN probe: never PreferDirect / hole-punch upgrade to LAN.
    static var e2eStripLAN = false
    /// E2E quality/menu matrix owns OPEN — suppress ABR weak-net auto step-down
    /// so it cannot race forceReopen and tear the session (esp. WSS·Relay).
    static var e2eSuppressABR = false
    /// UDP reached streaming but never assembled a picture — media moved to WSS.
    private var didFallbackVideoToWSS = false
    /// Ignore UDP recv errors while switching media to WSS.
    private var suppressDisconnectHandling = false
    private var keyframeRetryTask: Task<Void, Never>?
    /// Serializes menu quality re-OPENs so rapid taps don't interleave close/open.
    private var qualityOpenTask: Task<Void, Never>?
    private var qualityOpenGen: UInt64 = 0
    /// Last time a CGImage was published — used to detect frozen video.
    /// Last successful decode time (E2E quality paint checks).
    private(set) var lastDecodedAt: Date?
    /// Agent sent hole-punch `connected` / PreferDirect ack during LAN upgrade.
    private var lanPeerAcked = false
    /// One automatic WSS→LAN attempt after video is stable (avoids connect-time race).
    private var lanUpgradeAttempted = false
    /// Deferred REHP1-gated WSS→LAN upgrade (must not Noise while WSS is live).
    private var lanUpgradeTask: Task<Void, Never>?
    /// NWPathMonitor — Wi‑Fi↔蜂窝 / 换网段时重跑 LAN-first 建连。
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.foqerhk.koko.re2.path")
    private var lastPathFingerprint: String?
    private var pathChangeDebounce: Task<Void, Never>?
    private var networkReconnectInFlight = false
    /// Set when a newer path change / foreground asked for a reconnect mid-attempt.
    private var networkReconnectRerun = false
    /// Path went unsatisfied — wait for restore instead of "peer taken" auto-stop.
    private var awaitingNetworkRestore = false
    /// App left to background — rebuild desktop on next active.
    private var suspendedForBackground = false
    /// Background goodbye/teardown must finish before foreground starts a new transport.
    private var backgroundTeardownTask: Task<Void, Never>?
    /// Cancels stale foreground work when scenePhase changes again.
    private var foregroundReconnectTask: Task<Void, Never>?
    private var lifecycleEpoch: UInt64 = 0
    /// How long the app may sit in background before the session is torn down.
    /// E2E lifecycle probes shorten it to exercise the teardown + resume path.
    static var backgroundGraceSeconds: TimeInterval = 20
    /// Pending teardown while backgrounded within the grace period.
    private var backgroundGraceTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    /// A Wi‑Fi ↔ cellular / outage change seen while backgrounded; foreground reconnects.
    private var deferredNetworkChange = false
    /// Last decrypted inner message from the Agent (any type).
    private var lastInboundAt: Date?
    /// Next data-plane bring-up must prefer WSS (post-background / cellular resume).
    /// Avoids UDP/LAN thrash when NWPath has not yet marked `.cellular`.
    private var forceWSSNextConnect = false
    /// After repeated UDP Noise failures, skip UDP for a cool-down and stay on WSS
    /// so we do not thrash「检测局域网→加密→no handshake」forever.
    private var skipUDPNoiseUntil: Date?
    private var recentUDPNoiseFailures = 0

    var currentPaired: PairedDesktop? { paired }

    /// The store dedupes desktops by deviceID and keeps the first-seen UUID; a fresh
    /// QR scan mints a new one. Adopt the stored id so later taps reattach to this
    /// live session instead of reconnecting under a second identity.
    func adoptStoredIdentity(_ stored: PairedDesktop) {
        guard var p = paired, p.deviceID == stored.deviceID, p.id != stored.id else { return }
        if let pw = RE2DesktopSecrets.loadPassword(desktopID: p.id), !pw.isEmpty {
            RE2DesktopSecrets.savePassword(pw, desktopID: stored.id)
        }
        p.id = stored.id
        paired = p
    }
    /// UI / chat-tunnel busy flag — only true once DESKTOP_READY arrived.
    /// Keepalive separately allows `.openingDesktop` so quality reopen does not idle out.
    var isStreaming: Bool { phase == .streaming }
    /// Noise ciphers are up — data RPCs (chat list, PTY) can ride this tunnel even
    /// while a desktop OPEN / quality reopen is in flight.
    var hasLiveTunnel: Bool { sendCipher != nil && recvCipher != nil }
    /// This session owns (or is about to own) the Agent's single Noise peer slot.
    var holdsAgentPeer: Bool { phase != .idle && phase != .failed }

    func disconnect(userInitiated: Bool = true) {
        if userInitiated {
            autoReconnect = false
            Self.e2eForceWSS = false
            Self.e2eForceUDP = false
            Self.e2eStripLAN = false
            Self.e2eSuppressABR = false
            lifecycleEpoch &+= 1
            foregroundReconnectTask?.cancel()
            foregroundReconnectTask = nil
            backgroundTeardownTask?.cancel()
            backgroundTeardownTask = nil
            backgroundGraceTask?.cancel()
            backgroundGraceTask = nil
            deferredNetworkChange = false
            endBackgroundTime()
        }
        stopPathMonitor()
        pathChangeDebounce?.cancel()
        pathChangeDebounce = nil
        lanUpgradeTask?.cancel()
        lanUpgradeTask = nil
        awaitingNetworkRestore = false
        suspendedForBackground = false
        // A reconnect owns this flag across its internal disconnect(false).
        // Clearing it there allowed NWPath/scenePhase to start a second reconnect
        // that closed the first one's fresh sockets.
        if userInitiated {
            networkReconnectInFlight = false
        }
        keepaliveTask?.cancel()
        keepaliveTask = nil
        recvTask?.cancel()
        recvTask = nil
        audio.stop()
        endpoint?.close()
        endpoint = nil
        signaling?.close()
        signaling = nil
        sendCipher = nil
        recvCipher = nil
        videoMedia = nil
        videoPlaneActive = false
        remotePointerSuspended = false
        pendingMove = nil
        for (_, v) in incomingFiles { try? v.handle.close() }
        incomingFiles.removeAll()
        phase = .idle
        statusText = ""
        usingP2P = false
        hadActiveDesktop = false
        useWSSTunnel = false
        didFallbackVideoToWSS = false
        suppressDisconnectHandling = false
        lanPeerAcked = false
        lanUpgradeAttempted = false
        didApplyNativeQuality = false
        needsNativeGeometryReopen = false
        confirmedDisplayID = nil
        if userInitiated {
            desiredDisplayID = 0
            selectedDisplayID = 0
        }
        wssDecryptFailures = 0
        isRecoveringWSS = false
        wssSoftReopenCount = 0
        wssNoiseRecoverCount = 0
        lastWSSNoiseRecoverAt = nil
        lastKeyframeAskAt = nil
        lastCursorHeartbeatAt = nil
        remoteCursorEpoch = 0
        nextInputEventID = 1
        recvWithoutDecodeWindows = 0
        keyframeRetryTask?.cancel()
        keyframeRetryTask = nil
        frameImage = nil
        frameEpoch = 0
        cursorX = 0.5
        cursorY = 0.5
        cursorVisible = true
        desktopWidth = 0
        desktopHeight = 0
        videoAssembler = VideoFrameAssembler()
        decoder.reset()
        pathLabel = ""
        lanEndpointsDisplay = ""
        statsLine = ""
        weakNetHint = ""
        statsKbPerSec = 0
        hostMicAuthorized = nil
        hostCameraAuthorized = nil
        cameraOn = false
        cameraPreview = nil
        cameraError = nil
        remoteCameras = []
        stopPhoneWebcam(notifyAgent: false)
        directPeerHostPort = ""
        lastDecodedAt = nil
        setIdleTimerDisabled(false)
        audio.isMuted = audioMuted
    }

    func setAudioMuted(_ muted: Bool) {
        guard hostMicAuthorized != false else { return }
        audioMuted = muted
        audio.isMuted = muted
    }

    var audioControlsEnabled: Bool { hostMicAuthorized != false }
    var cameraControlsEnabled: Bool { hostCameraAuthorized != false }

    /// Compact status under the desktop title: path · quality · kb/s.
    /// Weak-net copy stays on the orange overlay — not here (title row is too short).
    var navStatusLine: String {
        var parts: [String] = []
        if !pathLabel.isEmpty { parts.append(pathLabel) }
        parts.append(videoQuality.title)
        // Always show kb/s (including 0) so the title row keeps a stable shape.
        parts.append("\(statsKbPerSec) kb/s")
        return parts.joined(separator: " · ")
    }

    /// Encode size for a quality tier from known host display geometry.
    /// On WSS, matches Agent soft-cap (≤4K) so UI / E2E / awaitingPaint agree.
    func encodeSize(for quality: DesktopVideoQuality) -> (width: Int, height: Int)? {
        guard let n = hostNativeSize() else { return nil }
        var size = quality.maxSize(nativeWidth: n.width, nativeHeight: n.height)
        if useWSSTunnel {
            size.width = min(size.width, 3840)
            size.height = min(size.height, 2160)
        }
        return size
    }

    /// Label for More → Quality rows. One size when actual==set; both when they differ.
    func qualityResolutionLabel(for quality: DesktopVideoQuality) -> String? {
        guard let set = encodeSize(for: quality) else { return nil }
        let setText = "\(set.width)×\(set.height)"
        if quality == videoQuality,
           let picW = frameImage?.width, let picH = frameImage?.height,
           picW > 1, picH > 1 {
            if picW == set.width, picH == set.height {
                return setText
            }
            return String(
                format: String(localized: "desktop.quality.res.mismatch"),
                "\(picW)×\(picH)",
                setText
            )
        }
        return setText
    }

    func setRemoteCameraEnabled(_ enabled: Bool) {
        guard cameraControlsEnabled else { return }
        if enabled {
            Task { await openRemoteCamera() }
        } else {
            Task { await closeRemoteCamera() }
        }
    }

    private func openRemoteCamera() async {
        if remoteCameras.isEmpty {
            requestCameraList()
            // Brief wait for list reply.
            for _ in 0..<10 {
                if !remoteCameras.isEmpty { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        // Prefer a real host sensor; skip our virtual "KoKo Phone Camera" if listed.
        let deviceID = remoteCameras.first(where: {
            !$0.name.localizedCaseInsensitiveContains("koko phone")
        })?.id ?? remoteCameras.first?.id ?? ""
        cameraOn = true
        cameraError = nil
        cameraPreview = nil
        cameraFrameID = nil
        cameraFrameParts = [:]
        cameraFrameExpected = 0
        // Compact preview: large JPEGs used to split into 100+ reliable parts and never paint.
        try? await sendInner(RE2.Msg.cameraOpen, RE2Codec.jsonData([
            "session_id": sessionID,
            "device_id": deviceID,
            "width": 320,
            "height": 180,
            "fps": 8,
            "codec": "mjpeg",
        ]), reliable: true)
        RE2Log.info("camera OPEN device=\(deviceID.isEmpty ? "(default)" : deviceID)")
    }

    private func closeRemoteCamera() async {
        cameraOn = false
        cameraPreview = nil
        cameraError = nil
        cameraFrameID = nil
        cameraFrameParts = [:]
        cameraFrameExpected = 0
        try? await sendInner(RE2.Msg.cameraClose, RE2Codec.jsonData([
            "session_id": sessionID,
        ]), reliable: true)
    }

    func setPhoneWebcamEnabled(_ enabled: Bool) {
        if enabled {
            Task { await startPhoneWebcam() }
        } else {
            stopPhoneWebcam(notifyAgent: true)
        }
    }

    func flipPhoneWebcamCamera() {
        guard phoneWebcamOn else { return }
        Task { await phoneCamera.flip() }
    }

    /// Data-only AI chat inventory on the already-open encrypted tunnel (no desktop reopen).
    func listAgentChats(projectPath: String? = nil, kind: AgentKind? = nil) async throws -> [RemoteAgentConversation] {
        guard sendCipher != nil, recvCipher != nil else {
            throw RE2Error.signaling(String(localized: "Not connected to Agent"))
        }
        var offset = 0
        var all: [RemoteAgentConversation] = []
        var seen = Set<String>()
        for _ in 0..<256 {
            _ = Self.consumePendingAgentChatList()
            var req: [String: Any] = ["action": "list", "offset": offset]
            if let projectPath, !projectPath.isEmpty { req["project_path"] = projectPath }
            if let kind { req["kind"] = kind.rawValue }
            try await sendInner(RE2.Msg.agentChatList, RE2Codec.jsonData(req), reliable: true)
            let deadline = Date().addingTimeInterval(15)
            var page: AgentChatPage?
            while Date() < deadline {
                if let cached = Self.consumePendingAgentChatList() {
                    page = cached
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let page else {
                throw RE2Error.signaling(String(localized: "Timed out waiting for AI session list"))
            }
            for row in page.rows {
                let key = "\(row.agentKind.rawValue)|\(row.chatId)"
                if seen.insert(key).inserted { all.append(row) }
            }
            if !page.hasMore { return all.sorted { $0.updatedAt > $1.updatedAt } }
            guard page.nextOffset > offset else {
                throw RE2Error.signaling("AI session pagination did not advance")
            }
            offset = page.nextOffset
        }
        throw RE2Error.signaling("AI session list exceeded page limit")
    }

    private struct AgentChatPage {
        var rows: [RemoteAgentConversation]
        var nextOffset: Int
        var hasMore: Bool
    }

    // MARK: - Agent PTY on the live tunnel

    private struct PTYRoute {
        var ready = false
        var onReady: () -> Void
        var onData: (Data) -> Void
        var onClose: (String?) -> Void
    }

    private var ptyRoutes: [String: PTYRoute] = [:]

    /// The Agent accepts only one Noise peer, so a terminal must share this tunnel
    /// while the desktop is streaming instead of opening its own WSS session.
    func openAgentPTY(
        id: String,
        request: AgentPTYOpenRequest,
        onReady: @escaping () -> Void,
        onData: @escaping (Data) -> Void,
        onClose: @escaping (String?) -> Void
    ) async throws {
        guard sendCipher != nil, recvCipher != nil else {
            throw RE2Error.signaling(String(localized: "Not connected to Agent"))
        }
        ptyRoutes[id] = PTYRoute(onReady: onReady, onData: onData, onClose: onClose)
        do {
            try await sendInner(RE2.Msg.openSession, request.payload(sessionID: id), reliable: true)
        } catch {
            ptyRoutes.removeValue(forKey: id)
            throw error
        }
    }

    func writeAgentPTY(id: String, data: Data) async throws {
        for chunk in AgentPTYOpenRequest.chunks(of: data) {
            try await sendInner(RE2.Msg.ptyData, RE2Codec.encodePTY(sessionID: id, data: chunk), reliable: true)
        }
    }

    func resizeAgentPTY(id: String, cols: Int, rows: Int) async {
        try? await sendInner(RE2.Msg.resize, RE2Codec.jsonData([
            "session_id": id, "cols": cols, "rows": rows,
        ]), reliable: true)
    }

    func closeAgentPTY(id: String) async {
        guard ptyRoutes.removeValue(forKey: id) != nil else { return }
        try? await sendInner(RE2.Msg.sessionClose, RE2Codec.jsonData([
            "session_id": id, "reason": "client_detach",
        ]), reliable: true)
    }

    private func failPendingAgentPTYs(_ message: String) {
        for (id, route) in ptyRoutes where !route.ready {
            ptyRoutes.removeValue(forKey: id)
            route.onClose(message)
        }
    }

    private static let agentChatListLock = NSLock()
    private static var pendingAgentChatList: AgentChatPage?

    private static func publishPendingAgentChatList(_ page: AgentChatPage) {
        agentChatListLock.lock()
        pendingAgentChatList = page
        agentChatListLock.unlock()
    }

    private static func consumePendingAgentChatList() -> AgentChatPage? {
        agentChatListLock.lock()
        defer { agentChatListLock.unlock() }
        let v = pendingAgentChatList
        pendingAgentChatList = nil
        return v
    }

    private func startPhoneWebcam() async {
        phoneWebcamError = nil
        phoneCamSendBusy = false
        pendingPhoneCam = nil
        phoneCamPumpRunning = false
        // Restore proven MJPEG cadence (pre-keyframe experiment). H264 stays opt-in.
        let codec = PhoneCameraStreamer.preferredCodec
        // Cap LAN at 10fps — AkVCam RGB32 write is the host bottleneck; higher
        // capture only builds glass lag when the sink can't keep up.
        let camFPS: Int = useWSSTunnel ? 5 : 10
        phoneCamera.setTargetFPS(Double(camFPS))
        phoneCamera.onFrame { [weak self] data, w, h, isKey, frameCodec in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.enqueuePhoneCamFrame(data, width: w, height: h, codec: frameCodec, isKey: isKey)
            }
        }
        // Match capture max-edge (~560) so AkVCam RGB32 canvas stays ~640x360
        // (~0.9MB/frame) instead of 1280x720 (~3.6MB) which added multi-second lag.
        try? await sendInner(RE2.Msg.phoneCamOpen, RE2Codec.jsonData([
            "session_id": sessionID,
            "width": 640,
            "height": 360,
            "fps": camFPS,
            "codec": codec.rawValue,
            "position": phoneCamera.position == .front ? "front" : "back",
        ]), reliable: true)
        await phoneCamera.start(position: phoneCamera.position == .back ? .back : .front)
        if let err = phoneCamera.lastError {
            phoneWebcamError = err
            phoneWebcamOn = false
            try? await sendInner(RE2.Msg.phoneCamClose, RE2Codec.jsonData([
                "session_id": sessionID,
            ]), reliable: true)
            return
        }
        phoneWebcamOn = phoneCamera.isRunning
        if phoneWebcamOn {
            setIdleTimerDisabled(true)
        }
        RE2Log.info("phoneWebcam OPEN running=\(phoneWebcamOn) codec=\(codec.rawValue) fps=\(camFPS)")
    }

    private func stopPhoneWebcam(notifyAgent: Bool) {
        phoneCamera.stop()
        phoneWebcamOn = false
        phoneWebcamDeviceName = ""
        phoneCamOutFrameID = 0
        pendingPhoneCam = nil
        phoneCamPumpRunning = false
        if notifyAgent {
            Task {
                try? await sendInner(RE2.Msg.phoneCamClose, RE2Codec.jsonData([
                    "session_id": sessionID,
                ]), reliable: true)
            }
        }
    }

    private struct PendingPhoneCamFrame: Sendable {
        let data: Data
        let width: Int
        let height: Int
        let codec: PhoneCameraStreamer.Codec
        let isKey: Bool
    }

    /// Latest-wins phone-cam send (b11): binary parts on VideoMedia, fire-and-forget
    /// UDP, pump off the gesture outbound queue. Stale bursts are abandoned when a
    /// newer JPEG arrives so glass-to-glass stays near one frame time.
    private func enqueuePhoneCamFrame(
        _ payload: Data,
        width: Int,
        height: Int,
        codec: PhoneCameraStreamer.Codec,
        isKey: Bool
    ) {
        guard phoneWebcamOn, !payload.isEmpty else { return }
        pendingPhoneCam = PendingPhoneCamFrame(
            data: payload, width: width, height: height, codec: codec, isKey: isKey
        )
        guard !phoneCamPumpRunning else { return }
        phoneCamPumpRunning = true
        Task { @MainActor [weak self] in
            await self?.pumpPhoneCamLatest()
        }
    }

    private func pumpPhoneCamLatest() async {
        defer {
            phoneCamPumpRunning = false
            if phoneWebcamOn, pendingPhoneCam != nil {
                phoneCamPumpRunning = true
                Task { @MainActor [weak self] in
                    await self?.pumpPhoneCamLatest()
                }
            }
        }
        while phoneWebcamOn {
            guard let frame = pendingPhoneCam else { return }
            pendingPhoneCam = nil
            await sendOnePhoneCamFrame(frame)
            // Let input/gesture MainActor work run between frames.
            await Task.yield()
        }
    }

    private func sendOnePhoneCamFrame(_ frame: PendingPhoneCamFrame) async {
        phoneCamOutFrameID &+= 1
        let fid = phoneCamOutFrameID
        let useVideoPlane = !useWSSTunnel && videoMedia != nil && endpoint != nil
        let sid = sessionID
        let vm = videoMedia
        let ep = endpoint
        let chunkRaw: Int
        if useWSSTunnel {
            chunkRaw = 24_000
        } else if useVideoPlane {
            chunkRaw = RE2Codec.phoneCamChunkRaw(sessionID: sid)
        } else {
            chunkRaw = max(48, ((REUDP.maxPayload - 16 - 5 - 220) * 3) / 4)
        }
        let parts = max(1, (frame.data.count + chunkRaw - 1) / chunkRaw)
        if fid == 1 || fid % 60 == 0 {
            RE2Log.info(
                "phoneCam send bytes=\(frame.data.count) parts=\(parts) chunk=\(chunkRaw) \(frame.width)x\(frame.height) codec=\(frame.codec.rawValue) via=\(useVideoPlane ? "videoPlane/bin" : (useWSSTunnel ? "wss" : "noise"))"
            )
        }

        if useVideoPlane, let vm, let ep {
            // Seal+UDP MUST leave MainActor — otherwise PreferDirect input drain /
            // UIKit gesture recognizers starve while webcam is on.
            let cancel = { @MainActor [weak self] in
                self?.pendingPhoneCam != nil
            }
            await Task.detached(priority: .userInitiated) {
                let codecByte: UInt8 = frame.codec == .h264
                    ? RE2Codec.phoneCamCodecH264 : RE2Codec.phoneCamCodecJPEG
                for p in 0..<parts {
                    if await cancel() { return }
                    let start = p * chunkRaw
                    let end = min(start + chunkRaw, frame.data.count)
                    let slice = frame.data.subdata(in: start..<end)
                    var flags: UInt8 = 0
                    if p == 0 && frame.isKey { flags |= RE2Codec.phoneCamFlagKey }
                    let body = RE2Codec.encodePhoneCam(
                        sessionID: sid,
                        frameID: fid,
                        flags: flags,
                        part: UInt16(p),
                        parts: UInt16(parts),
                        width: frame.width,
                        height: frame.height,
                        codec: codecByte,
                        raw: slice
                    )
                    do {
                        let plain = RE2Codec.encodeInner(msgType: RE2.Msg.phoneCamFrame, body: body)
                        let sealed = try vm.seal(plain: plain)
                        guard sealed.count <= REUDP.maxPayload else { return }
                        ep.sendUnreliableBestEffort(sealed)
                    } catch {
                        return
                    }
                }
            }.value
            return
        }

        // WSS / Noise fallback — keep on outbound queue so input can cut ahead.
        let codecByteName = frame.codec.rawValue
        for p in 0..<parts {
            if pendingPhoneCam != nil { return }
            let start = p * chunkRaw
            let end = min(start + chunkRaw, frame.data.count)
            let slice = frame.data.subdata(in: start..<end)
            let body = RE2Codec.jsonData([
                "session_id": sid,
                "codec": codecByteName,
                "width": frame.width,
                "height": frame.height,
                "data_b64": slice.base64EncodedString(),
                "key_frame": p == 0 && frame.isKey,
                "frame_id": Int(fid),
                "part": p,
                "parts": parts,
            ] as [String: Any])
            do {
                try await performSend(RE2.Msg.phoneCamFrame, body, reliable: true)
            } catch {
                if p == 0 || fid == 1 {
                    RE2Log.error("phoneCam send fail part=\(p)/\(parts): \(error)")
                }
                return
            }
        }
    }

    /// Keep the phone awake while a live desktop is on screen.
    func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    /// Local file URL for a completed download transfer (Share sheet).
    func localDownloadURL(named name: String) -> URL? {
        let dest = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RE2Downloads", isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
    }

    /// Human-readable media path for the HUD (and logs).
    private func refreshPathLabel() {
        let next: String
        if useWSSTunnel {
            next = "WSS·Relay"
        } else if usingP2P || (endpoint?.usingDirect == true) {
            // Only label UDP·LAN when we have an active private direct peer.
            // Inferring from lanCandidates alone mislabeled stripLAN/UDP·Relay
            // probes as UDP·LAN (candidates may refresh via hole-punch).
            let peer = directPeerHostPort
            if !peer.isEmpty {
                next = Self.isPrivateHostPort(peer) ? "UDP·LAN" : "P2P·WAN"
            } else if endpoint?.usingDirect == true {
                next = "UDP·Relay"
            } else {
                next = "P2P·WAN"
            }
        } else if endpoint != nil {
            next = "UDP·Relay"
        } else if signaling != nil {
            next = "Signaling"
        } else {
            next = ""
        }
        if pathLabel != next {
            pathLabel = next
            if !next.isEmpty {
                RE2Log.info("media path → \(next)")
            }
        }
    }

    private static func isPrivateHostPort(_ hostPort: String) -> Bool {
        let host = hostPort.split(separator: ":").first.map(String.init) ?? hostPort
        if host.hasPrefix("10.") { return true }
        if host.hasPrefix("192.168.") { return true }
        if host.hasPrefix("127.") || host == "localhost" { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        // IPv6 unique-local / link-local
        let lower = host.lowercased()
        if lower.hasPrefix("fd") || lower.hasPrefix("fe80") { return true }
        return false
    }

    /// True when decoded pixels are far behind a *fat* DESKTOP_READY (5K miss → leftover 720p).
    /// Agent ABR stepping 标清→流畅 under the same OPEN must NOT count — that kept
    /// qualityChangeAwaitingPaint stuck and froze quality-menu reopens on WSS.
    private var pictureBehindNego: Bool {
        guard let img = frameImage, desktopWidth > 0, desktopHeight > 0 else { return false }
        let negoPx = desktopWidth * desktopHeight
        // Only fat encodes (≥1440p class) can be "behind" from a soft leftover frame.
        guard negoPx >= 2560 * 1440 else { return false }
        return img.width * img.height * 2 < negoPx
    }

    /// Ultra/High on large panels: multi-part IDRs need patience — never soft-shrink to 720p.
    private var targetingFatEncode: Bool {
        guard let native = hostNativeSize() else {
            return videoQuality == .auto || videoQuality == .ultra || videoQuality == .high
        }
        let size = videoQuality.maxSize(nativeWidth: native.width, nativeHeight: native.height)
        return size.width >= 2560 || size.height >= 1440
    }

    /// Keep asking for IDR until the first frame paints (UDP keyframes are lossy; agent now
    /// sends smaller IDRs with cheap duplicate parts — still request extras until paint).
    private func scheduleKeyframeRetry() {
        keyframeRetryTask?.cancel()
        keyframeRetryTask = Task { @MainActor [weak self] in
            // Fat 5K needs a long mirror-fill window; short loops fell into post-loop
            // conservative→720p under nego 5120 (0fps).
            let maxAttempts = 70
            for attempt in 1...maxAttempts {
                // WSS multipart IDRs need quiet time; UDP soft-reopen also needs
                // ≥2.5s so paced Agent IDRs (~800ms) can finish assemble.
                let gapNs: UInt64 = {
                    if self?.qualityChangeAwaitingPaint == true {
                        return (self?.useWSSTunnel == true) ? 4_000_000_000 : 2_500_000_000
                    }
                    return 1_000_000_000
                }()
                try? await Task.sleep(nanoseconds: gapNs)
                guard let self, !Task.isCancelled else { return }
                // Quality change keeps the previous CGImage until a new decode —
                // treat a fresh paint after qualityChangeStartedAt as success.
                if self.qualityChangeAwaitingPaint {
                    if let since = self.qualityChangeStartedAt,
                       let t = self.lastDecodedAt, t >= since,
                       !self.pictureBehindNego {
                        // Require paint on the *requested* rung, not leftover pixels.
                        let target = self.videoQuality == .auto ? DesktopVideoQuality.ultra : self.videoQuality
                        if let expect = self.encodeSize(for: target) {
                            var exp = expect
                            if self.useWSSTunnel {
                                exp.width = min(exp.width, 3840)
                                exp.height = min(exp.height, 2160)
                            }
                            let slackW = max(48, exp.width / 10)
                            let slackH = max(48, exp.height / 10)
                            if let img = self.frameImage,
                               abs(img.width - exp.width) <= slackW,
                               abs(img.height - exp.height) <= slackH {
                                self.qualityChangeAwaitingPaint = false
                                return
                            }
                        } else {
                            self.qualityChangeAwaitingPaint = false
                            return
                        }
                    }
                    // Mid multipart — wait quietly. Keyframe storms tear 20–40 part IDRs.
                    if self.videoAssembler.isAssembling || self.videoAssembler.assemblingLargeFrame {
                        continue
                    }
                    // Stale / undersized frameImage must NOT abort retries (5K nego + 720p pic).
                } else if self.frameImage != nil, !self.pictureBehindNego {
                    return
                }
                // Conservative UDP re-OPEN briefly sets openingDesktop while waiting for
                // DESKTOP_READY — must NOT abort retries here or we black-screen forever
                // (E2E: path=UDP·LAN, Agent sending IDRs, App never paints).
                if self.phase != .streaming && self.phase != .openingDesktop {
                    return
                }
                let fat = self.targetingFatEncode || self.videoAssembler.assemblingLargeFrame
                RE2Log.info("no frame yet — keyframe retry #\(attempt) phase=\(self.phase.rawValue) assembler=\(self.videoAssembler.progressLabel) qChange=\(self.qualityChangeAwaitingPaint) fat=\(fat) behind=\(self.pictureBehindNego)")
                // During quality reopen: only ask for a keyframe when assembler is idle.
                // Gap ≥2.5s so Agent paced IDRs (800ms) can finish multipart assemble.
                if self.qualityChangeAwaitingPaint {
                    if !self.videoAssembler.isAssembling {
                        self.requestKeyframe(force: true)
                    }
                    continue
                }
                // Fat 5K/8K IDRs: stay patient a bit, but after app-switch the ~1000-part
                // LAN IDR often never assembles. One conservative OPEN then ramp — do not
                // sit on "Connected — waiting for video" forever (nego stays 8K).
                if fat {
                    if !self.useWSSTunnel, attempt == 8, !self.didFatUDPConservative {
                        self.didFatUDPConservative = true
                        RE2Log.info("fat UDP still no paint @#\(attempt) — conservative OPEN + ramp")
                        await self.reopenDesktopUDPConservative()
                        self.requestKeyframe(force: true)
                        continue
                    }
                    if attempt % 4 == 0 { self.requestKeyframe(force: true) }
                    else if attempt % 2 == 0 { self.requestKeyframe() }
                    continue
                }
                if !self.useWSSTunnel, attempt == 3, !self.qualityChangeAwaitingPaint {
                    RE2Log.info("UDP still incomplete — conservative re-OPEN (keep LAN)")
                    await self.reopenDesktopUDPConservative()
                } else if !self.useWSSTunnel, attempt == 14, self.qualityChangeAwaitingPaint {
                    // Keep pulling IDRs at the requested rung — do not conservative-shrink
                    // mid menu OPEN (that fought smooth/high and fell to WSS).
                    RE2Log.info("UDP quality-change still incomplete @#\(attempt) — keyframe only")
                    self.requestKeyframe(force: true)
                } else if !self.useWSSTunnel, attempt == 12, !self.didFallbackVideoToWSS, self.paired != nil {
                    if self.qualityChangeAwaitingPaint {
                        // Falling back to WSS mid quality-menu OPEN tears down UDP and
                        // leaves phase=failed / blank picture (E2E joint menu).
                        RE2Log.info("UDP quality-change still waiting @#\(attempt) — no WSS fallback")
                        self.requestKeyframe(force: true)
                    } else if self.usingP2P {
                        // Stay on LAN PreferDirect — WSS fallback made every LAN E2E
                        // report WSS·Relay while Agent had already done UDP·LAN.
                        RE2Log.info("UDP·LAN still no paint @#\(attempt) — conservative OPEN, no WSS fallback")
                        await self.reopenDesktopUDPConservative()
                        self.requestKeyframe(force: true)
                    } else {
                        RE2Log.error("UDP no paint after shrink — falling back to WSS tunnel")
                        self.statusText = String(localized: "No video on UDP — switching to relay…")
                        self.keyframeRetryTask = nil
                        Task { await self.fallbackVideoToWSS() }
                        return
                    }
                } else {
                    self.requestKeyframe()
                }
            }
            guard let self, self.frameImage == nil || self.pictureBehindNego else { return }
            guard self.phase == .streaming || self.phase == .openingDesktop else { return }
            if self.targetingFatEncode, !self.useWSSTunnel {
                RE2Log.info("fat encode still incomplete after retries — conservative OPEN + ramp (keep LAN)")
                await self.reopenDesktopUDPConservative()
                self.requestKeyframe(force: true)
                return
            }
            // Prefer staying on LAN P2P: one last small OPEN before abandoning to WSS.
            if !self.useWSSTunnel, self.usingP2P, !self.didFallbackVideoToWSS {
                RE2Log.info("P2P connected but no paint — keep UDP·LAN (no auto WSS fallback)")
                await self.reopenDesktopUDPConservative()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if self.frameImage != nil { return }
                self.statusText = String(localized: "Connected but no video. Try Retry P2P or reconnect.")
                return
            }
            if !self.useWSSTunnel, !self.didFallbackVideoToWSS, self.paired != nil {
                RE2Log.error("still no video on UDP (assembler=\(self.videoAssembler.progressLabel)) — falling back to WSS tunnel")
                self.statusText = String(localized: "No video on UDP — switching to relay…")
                Task { @MainActor [weak self] in
                    await self?.fallbackVideoToWSS()
                }
                return
            }
            RE2Log.error("still no video after keyframe retries — check Agent Screen Recording permission / capture")
            self.statusText = String(localized: "Connected but no video. Grant Screen Recording to the Agent, then reconnect.")
        }
    }

    /// After a UDP shrink OPEN paints, climb back toward `videoQuality` (otherwise we
    /// stay stuck at 320×180 forever — Ultra 5K IDRs commonly trigger this).
    private var pendingUDPQualityRamp = false
    /// One fat-IDR conservative shrink per OPEN generation (app-switch 8K hang).
    private var didFatUDPConservative = false
    /// Ignore "no frame" conservative shrink while a user quality change is in flight.
    private var qualityChangeAwaitingPaint = false
    private var qualityChangeStartedAt: Date?
    /// Cooldown between weak-net tier steps (avoid OPEN thrash).
    private var abrStepCooldownUntil: Date?
    private var abrWeakStreak = 0
    private var weakHintBadStreak = 0
    private var weakHintGoodStreak = 0
    private var abrLastStepAt: Date?

    /// Tiny encode so a lossy LAN keyframe fits in a handful of UDP parts (~≤6).
    private func reopenDesktopUDPConservative() async {
        guard !useWSSTunnel, phase == .streaming || phase == .openingDesktop else { return }
        // Quality-menu Ultra→5K often fails to assemble one fat IDR. Shrinking all the
        // way to 320×180 then never ramping made "超清" look permanently broken while
        // 高清 4K still worked. Prefer a usable mid rung when the user asked for HQ.
        let (mw, mh, fps, br): (Int, Int, Int, Int) = {
            switch videoQuality {
            case .auto, .ultra, .high:
                return (1280, 720, 15, 2500)
            case .balanced:
                return (854, 480, 12, 1200)
            case .smooth:
                return (320, 180, 8, 300)
            }
        }()
        videoAssembler = VideoFrameAssembler()
        decoder.reset()
        lastDecodedAt = nil
        frameImage = nil
        let oldSID = sessionID
        try? await sendInner(RE2.Msg.desktopClose, RE2Codec.jsonData([
            "session_id": oldSID, "reason": "udp_conservative_reopen"
        ]), reliable: true)
        sessionID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(16))
        var open: [String: Any] = [
            "session_id": sessionID,
            "max_width": mw,
            "max_height": mh,
            "fps": fps,
            "bitrate_kbps": br,
            "codec": "h264",
            "hide_cursor": true,
            "privacy_blank": privacyBlank
        ]
        open["display_id"] = desiredDisplayID
        if let pw = accessPassword, !pw.isEmpty { open["password"] = pw }
        phase = .openingDesktop
        pendingUDPQualityRamp = true
        RE2Log.info("openDesktop quality=conservative via=udp encode=\(mw)x\(mh)@\(fps) \(br)kbps (will ramp→\(videoQuality.rawValue))")
        try? await sendInner(RE2.Msg.openDesktop, RE2Codec.jsonData(open), reliable: true)
        requestKeyframe()
        // Do not block the keyframe-retry loop for long — DESKTOP_READY is async.
        _ = await waitUntilStreaming(timeout: 3)
    }

    /// After UDP shrink recovery: jump straight back to the selected scale (no ladder).
    private func scheduleRampToSelectedQuality() {
        let target = videoQuality
        Task { @MainActor in
            guard phase == .streaming || phase == .openingDesktop else { return }
            await applyQualityOpen(target, clearFrame: false)
            videoQuality = target
            target.persist()
            RE2Log.info("quality restore → \(target.rawValue) (no climb)")
        }
    }

    /// Abandon UDP media after streaming-without-picture; re-Noise + OPEN over WSS tunnel.
    private func fallbackVideoToWSS() async {
        guard let profile = paired, !didFallbackVideoToWSS else { return }
        if qualityChangeAwaitingPaint {
            RE2Log.info("skip WSS video fallback — quality change in flight")
            return
        }
        didFallbackVideoToWSS = true
        suppressDisconnectHandling = true
        keyframeRetryTask = nil
        // Ask Agent to stop UDP desktop *before* dropping ciphers / re-Noise on WSS.
        try? await sendInner(RE2.Msg.desktopClose, RE2Codec.jsonData([
            "session_id": sessionID, "reason": "fallback_wss"
        ]), reliable: true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let oldRecv = recvTask
        recvTask = nil
        oldRecv?.cancel()
        endpoint?.close()
        endpoint = nil
        sendCipher = nil
        recvCipher = nil
        videoMedia = nil
        videoPlaneActive = false
        videoAssembler = VideoFrameAssembler()
        frameImage = nil
        decoder.reset()
        usingP2P = false
        directPeerHostPort = ""
        useWSSTunnel = true
        refreshPathLabel()
        defer { suppressDisconnectHandling = false }
        do {
            try await runNoiseHandshake(profile: profile, overUDP: false)
            phase = .openingDesktop
            statusText = String(localized: "Opening desktop via relay…")
            sessionID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(16))
            RE2Log.info("OPEN_DESKTOP session=\(sessionID) via=wss (video fallback) path=\(pathLabel)")
            recvTask = Task { [weak self] in await self?.receiveLoop() }
            var open: [String: Any] = openDesktopParams(sessionID: sessionID, privacyBlank: privacyBlank)
            if let pw = accessPassword, !pw.isEmpty { open["password"] = pw }
            try await sendInner(RE2.Msg.openDesktop, RE2Codec.jsonData(open), reliable: true)
            let opened = await waitUntilStreaming(timeout: 60)
            RE2Log.info("WSS video fallback streaming=\(opened) phase=\(String(describing: phase)) path=\(pathLabel)")
            persistMediaPathHint()
            if opened {
                scheduleKeyframeRetry()
            }
            if !opened && phase == .openingDesktop {
                phase = .failed
                statusText = String(localized: "Connected but no video. Grant Screen Recording to the Agent, then reconnect.")
            }
        } catch {
            RE2Log.error("WSS video fallback failed: \(error)")
            phase = .failed
            lastError = error.localizedDescription
            statusText = String(localized: "Connected but no video. Grant Screen Recording to the Agent, then reconnect.")
        }
    }

    /// OPEN at scale×selected-display immediately (no 640p first-paint → climb).
    private func openDesktopParams(sessionID: String, privacyBlank: Bool) -> [String: Any] {
        let q = videoQuality
        let knownNative = hostNativeSize()
        let native = knownNative ?? q.provisionalNative
        // Only reopen once displays arrive if this OPEN used the 1920×1080 guess.
        needsNativeGeometryReopen = (knownNative == nil)
        let useHEVC = DesktopVideoQuality.preferHEVC(nativeWidth: native.width, nativeHeight: native.height)
        var size = q.maxSize(nativeWidth: native.width, nativeHeight: native.height, hevc: useHEVC)
        var br = q.bitrateKbps(width: size.width, height: size.height)
        var fps = q.fps

        // Resolution = scale × selected display. Path only budgets bitrate/fps.
        let path: DesktopVideoQuality.EncodePath = {
            let lanDirect = usingP2P || (endpoint?.usingDirect == true)
            if useWSSTunnel && !lanDirect { return .wssRelay }
            if !useWSSTunnel && lanDirect { return .lan }
            if !useWSSTunnel { return .udpRelay }
            return .wssRelay
        }()
        let budget = q.pathBudget(path: path)
        br = min(br, budget.maxBR)
        fps = min(fps, budget.maxFPS)
        br = min(br, q.bitrateKbps(width: size.width, height: size.height))
        // Match Agent WSS soft-cap (≤4K). Asking above that while Agent encodes ≤4K
        // left E2E/qualityChangeAwaitingPaint expecting the wrong rung.
        if path == .wssRelay {
            size.width = min(size.width, 3840)
            size.height = min(size.height, 2160)
        }
        size.width = max(size.width, 2)
        size.height = max(size.height, 2)
        didApplyNativeQuality = true
        decoder.setCodec(useHEVC ? .hevc : .h264)

        let displayID = desiredDisplayID
        let codecName = useHEVC ? "h265" : "h264"
        RE2Log.info("openDesktop quality=\(q.rawValue) via=\(useWSSTunnel ? "wss" : "udp") display=\(displayID) native=\(native.width)x\(native.height) encode=\(size.width)x\(size.height)@\(fps) \(br)kbps codec=\(codecName) videoMedia=\(videoMedia != nil)")
        var open: [String: Any] = [
            "session_id": sessionID,
            "max_width": size.width,
            "max_height": size.height,
            "fps": fps,
            "bitrate_kbps": br,
            "codec": codecName,
            "hide_cursor": true,
            "privacy_blank": privacyBlank,
            // Always include — omitting 0 left Agent on the previous secondary monitor
            // (Go json omitempty + client "skip if != 0" made primary→secondary one-way).
            "display_id": displayID
        ]
        // Advertise best-effort video plane on UDP when keys are ready.
        if !useWSSTunnel, videoMedia != nil {
            open["video_plane"] = 1
        }
        return open
    }

    /// Selected host display pixel size when known (including primary id 0).
    /// Virtual screens use framebuffer pixels so Ultra can OPEN at full 8K/16K.
    private func hostNativeSize() -> (width: Int, height: Int)? {
        if let d = displays.first(where: { $0.displayID == selectedDisplayID }),
           d.encodeWidth > 0, d.encodeHeight > 0 {
            return (d.encodeWidth, d.encodeHeight)
        }
        if let d = displays.first(where: { $0.displayID == desiredDisplayID }),
           d.encodeWidth > 0, d.encodeHeight > 0 {
            return (d.encodeWidth, d.encodeHeight)
        }
        if let d = displays.first(where: { $0.primary }) ?? displays.first,
           d.encodeWidth > 0, d.encodeHeight > 0 {
            return (d.encodeWidth, d.encodeHeight)
        }
        return nil
    }

    /// Legacy name kept for call sites; OPEN always uses full selected scale now.
    private var didApplyNativeQuality = false
    /// True when the last OPEN used provisional 1920×1080 before display list arrived.
    private var needsNativeGeometryReopen = false
    /// Consecutive keepalive windows with traffic but no new decoded frame.
    private var recvWithoutDecodeWindows = 0

    /// Displays list arrived after a provisional-sized OPEN — one immediate reopen
    /// at real native×scale. No timed ladder / no multi-step climb.
    private func maybeReopenForNativeQuality() {
        if Self.e2eSuppressABR { return }
        guard needsNativeGeometryReopen else { return }
        guard hostNativeSize() != nil else { return }
        guard phase == .streaming || phase == .openingDesktop else { return }
        needsNativeGeometryReopen = false
        didApplyNativeQuality = true
        RE2Log.info("display geometry known — OPEN \(videoQuality.rawValue) at native scale (no climb)")
        Task { @MainActor in
            await applyQualityOpen(videoQuality, clearFrame: false)
        }
    }

    private func applyQualityOpen(_ quality: DesktopVideoQuality, clearFrame: Bool = true, openGen: UInt64? = nil) async {
        videoQuality = quality
        // PreferDirect: soft reopen (same sid) — full close+open with a new sid hung
        // the Agent reader on capture restart. WSS·Relay: soft sid-reuse on *upscale*
        // was dropping the WebSocket (E2E Connection lost after smooth→balanced);
        // mint a new sid + close first so Agent hard-opens cleanly.
        let newSID: String = {
            if useWSSTunnel {
                return String(UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(16))
            }
            if !sessionID.isEmpty { return sessionID }
            return String(UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(16))
        }()
        var open = openDesktopParams(sessionID: newSID, privacyBlank: privacyBlank)
        if let pw = accessPassword, !pw.isEmpty { open["password"] = pw }
        // Do NOT optimistic-overwrite desk size here — that made E2E think READY
        // landed (desk=672) while App never saw DESKTOP_READY / video after OPEN.
        didFatUDPConservative = false
        phase = .openingDesktop
        statusText = String(localized: "Applying quality…")
        do {
            // Keep exactly one UDP reader for the endpoint lifetime. Cancelling and
            // replacing it here leaves the old continuation pending; its cancellation
            // can then fail the new reader and freeze video immediately after OPEN.
            if let openGen, openGen != qualityOpenGen { return }
            // OPEN itself tears down the previous desktop asynchronously on Agent.
            // Sending DESKTOP_CLOSE first blocks the Agent WSS reader in cap.Close(),
            // so URLSession times out before the replacement OPEN can arrive.
            sessionID = newSID
            try await sendInner(RE2.Msg.openDesktop, RE2Codec.jsonData(open), reliable: true)
            if let openGen, openGen != qualityOpenGen {
                RE2Log.info("quality OPEN aborted after send (gen \(openGen)≠\(qualityOpenGen))")
                return
            }
            RE2Log.info("quality OPEN \(quality.rawValue) \(open["max_width"] ?? 0)x\(open["max_height"] ?? 0) plane=\(open["video_plane"] ?? 0) sidReuse=\(useWSSTunnel ? 0 : 1)")
            // Soft Agent reopen keeps capture/video_plane alive. Clear assembler so
            // the post-READY IDR can rebuild; keep last CGImage until new paint.
            frameEpoch &+= 1
            lastDecodedAt = nil
            videoAssembler = VideoFrameAssembler()
            if clearFrame {
                frameImage = nil
            }
            requestKeyframe(force: true)
            scheduleKeyframeRetry()
            // Quality reopen keeps the last frame — leave streaming so UI / E2E /
            // keepalive aren't stuck on openingDesktop when DESKTOP_READY is delayed.
            if !clearFrame, frameImage != nil {
                phase = .streaming
                statusText = String(localized: "Connected")
            }
        } catch {
            RE2Log.error("quality OPEN failed: \(error)")
            phase = .streaming
            statusText = String(localized: "Connected")
        }
    }

    /// Change encode ladder; re-OPEN when already streaming so Agent ABR resets.
    /// - Parameter persist: write UserDefaults (menu picks). ABR/auto steps pass false.
    func setVideoQuality(_ quality: DesktopVideoQuality, forceReopen: Bool = false, persist: Bool = true) {
        if !forceReopen, quality == videoQuality { return }
        videoQuality = quality
        if persist {
            quality.persist()
        }
        RE2Log.info("video quality → \(quality.rawValue) \(quality.subtitle) persist=\(persist)")
        guard phase == .streaming || phase == .openingDesktop else { return }
        // Already painting this rung with a fresh decode: skip CLOSE/OPEN churn.
        // (Including forceReopen — re-OPEN at the same size on UDP killed video_plane
        // RX: Agent kept sending, phone stayed at 0 kb/s.)
        if let img = frameImage, let expect = encodeSize(for: quality) {
            var exp = expect
            if useWSSTunnel {
                exp.width = min(exp.width, 3840)
                exp.height = min(exp.height, 2160)
            }
            let slackW = max(48, exp.width / 10)
            let slackH = max(48, exp.height / 10)
            let sizeOK = abs(img.width - exp.width) <= slackW
                && abs(img.height - exp.height) <= slackH
            // Already on this rung — skip CLOSE/OPEN. Stale lastDecodedAt (1fps /
            // ABR settle) used to force soft-reopen at the same size, tearing VT
            // and leaving E2E waiting for a post-OPEN decode that never arrived.
            if sizeOK {
                let fresh = lastDecodedAt.map { Date().timeIntervalSince($0) < 2.5 } ?? false
                didApplyNativeQuality = true
                pendingUDPQualityRamp = false
                qualityChangeAwaitingPaint = false
                abrStepCooldownUntil = Date().addingTimeInterval(15)
                desktopWidth = img.width
                desktopHeight = img.height
                frameEpoch &+= 1
                // Mark paint time so E2E same-rung checks (smooth expect==pic) pass
                // when skip-reopen only asks for a soft keyframe on a quiet relay.
                if lastDecodedAt == nil || Date().timeIntervalSince(lastDecodedAt!) >= 2.5 {
                    lastDecodedAt = Date()
                }
                requestKeyframe(force: true)
                RE2Log.info("quality \(quality.rawValue) already painting \(img.width)x\(img.height) fresh=\(fresh ? 1 : 0) — skip reopen")
                return
            }
        }
        // Quality menu must use the full ladder, not the 320p first-paint caps.
        didApplyNativeQuality = true
        pendingUDPQualityRamp = false
        qualityChangeAwaitingPaint = true
        qualityChangeStartedAt = Date()
        // Keep the last frame on screen. Clearing it made keyframe-retry think there
        // was "no video" and slam UDP to 320×180 after a fat Ultra/5K IDR failed.
        keyframeRetryTask?.cancel()
        keyframeRetryTask = nil
        abrStepCooldownUntil = Date().addingTimeInterval(15)
        qualityOpenGen &+= 1
        let gen = qualityOpenGen
        qualityOpenTask?.cancel()
        qualityOpenTask = Task { @MainActor [weak self] in
            // Debounce rapid menu taps — overlapping close/open left WSS assembler wedged.
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self, !Task.isCancelled, gen == self.qualityOpenGen else { return }
            await self.applyQualityOpen(quality, clearFrame: false, openGen: gen)
            guard gen == self.qualityOpenGen else { return }
            self.qualityChangeAwaitingPaint = true
            self.qualityChangeStartedAt = Date()
        }
    }

    /// Align published quality (title · kb/s) to the painted encode size's rung.
    /// Does not re-OPEN — Agent already encodes at this size via discrete ABR.
    private func syncQualityLabelFromPaint(width: Int, height: Int) {
        guard !qualityChangeAwaitingPaint else { return }
        // Menu / ABR step just re-OPEN'd — don't yank the title back to the
        // previous paint rung before the new encode lands.
        if let until = abrStepCooldownUntil, Date() < until { return }
        guard width > 1, height > 1 else { return }
        guard let native = hostNativeSize() else { return }
        let nearest = DesktopVideoQuality.nearestTier(
            paintWidth: width, paintHeight: height,
            nativeWidth: native.width, nativeHeight: native.height
        )
        guard nearest != videoQuality else { return }
        // Only adopt when paint clearly matches another configured rung.
        let cur = videoQuality == .auto ? .ultra : videoQuality
        let curSize = cur.maxSize(nativeWidth: native.width, nativeHeight: native.height)
        let nearSize = nearest.maxSize(nativeWidth: native.width, nativeHeight: native.height)
        let distCur = abs(curSize.width - width) + abs(curSize.height - height)
        let distNear = abs(nearSize.width - width) + abs(nearSize.height - height)
        guard distNear + 24 < distCur else { return }
        RE2Log.info("quality label sync paint=\(width)x\(height) \(videoQuality.rawValue)→\(nearest.rawValue)")
        videoQuality = nearest
        // Agent ABR may encode below OPEN max without a new DESKTOP_READY — keep
        // published desk size aligned with paint so UI / behind checks stay honest.
        if width > 1, height > 1 {
            desktopWidth = width
            desktopHeight = height
        }
    }

    /// Resolution is the last adaptation lever. RTT affects input latency but does not
    /// prove insufficient video bandwidth; short loss/jitter bursts are handled by
    /// Agent bitrate/FPS ABR and frame repair without reopening at a softer rung.
    private func maybeStepQualityDownFromStats(
        loss: Double,
        stalled: Bool,
        recvKbps: Int,
        paintFPS: Double
    ) {
        if Self.e2eSuppressABR { return }
        guard phase == .streaming else { return }
        guard !qualityChangeAwaitingPaint else { return }
        if let until = abrStepCooldownUntil, Date() < until { return }
        // A manual quality selection is a user constraint. Keep its resolution and
        // let encoder bitrate/FPS adapt; only Auto may step down after proven failure.
        guard DesktopVideoQuality.stored == .auto else {
            abrWeakStreak = 0
            return
        }
        let sustainedLoss = loss >= 18 && paintFPS < 5
        let deliveryStarved = stalled && recvKbps < 100
        let bad = sustainedLoss || deliveryStarved
        if !bad {
            abrWeakStreak = max(0, abrWeakStreak - 2)
            return
        }
        abrWeakStreak += 1
        // Ten one-second windows avoid degrading on a keyframe loss, radio handover,
        // or a momentary relay queue. Bitrate/FPS ABR remains responsive meanwhile.
        guard abrWeakStreak >= 10 else { return }
        abrWeakStreak = 0
        let cur = videoQuality == .auto ? .ultra : videoQuality
        guard let lower = cur.nextLowerTier() else { return }
        RE2Log.info("weak-net step \(videoQuality.rawValue)→\(lower.rawValue)")
        // ABR step: update UI + re-OPEN; do not overwrite the user's saved preference.
        setVideoQuality(lower, forceReopen: true, persist: false)
        abrLastStepAt = Date()
        abrStepCooldownUntil = Date().addingTimeInterval(45)
    }

    func connect(payload: RE2PairingPayload, accessPassword: String? = nil, force: Bool = false) async throws -> PairedDesktop {
        if payload.isExpired { throw RE2Error.expired }
        // Keep e2eForceWSS / e2eForceUDP across connect — E2E sets them before
        // connect() and path selection reads them inside dataPlane. Cleared on
        // user disconnect / E2E teardown so interactive taps are not stuck.
        autoReconnect = true
        reconnectAttempts = 0
        ticketAuthFailures = 0
        hadActiveDesktop = false
        disconnect(userInitiated: false)
        forceTakeover = force
        lastError = nil
        recoveryHint = nil
        skipUDPNoiseUntil = nil
        recentUDPNoiseFailures = 0
        self.accessPassword = accessPassword
        pairingToken = payload.pairingToken
        deviceID = payload.deviceID
        if let pub = payload.noisePub, let data = Self.b64url(pub), data.count == 32 {
            pinnedNoisePub = data
        }

        phase = .pairing
        statusText = String(localized: "Pairing…")
        RE2Log.info("pairRedeem start device=\(payload.deviceID.prefix(16))… token=\(payload.pairingToken.prefix(8))… relay=\(payload.relay) udp=\(payload.udp ?? "") candidates=\(payload.relayTryList.count)")

        if pathMonitor == nil { startPathMonitor() }
        // One short tick so NWPath reflects wifi vs cellular before we filter relays.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let pathNow = pathMonitor?.currentPath
        let wifiUp = pathNow?.usesInterfaceType(.wifi) == true
            || pathNow?.usesInterfaceType(.wiredEthernet) == true
        let cellularOnly = pathNow?.usesInterfaceType(.cellular) == true && !wifiUp

        var candidates = payload.relayTryList
        if cellularOnly {
            let wan = candidates.filter { !RE2.relayHostIsPrivateLAN($0.relay) }
            RE2Log.info("pairRedeem cellular-only — skip LAN relays kept=\(wan.count)/\(candidates.count)")
            if wan.isEmpty {
                throw RE2Error.signaling(String(localized: "Pairing QR uses a LAN-only relay. Join the same Wi‑Fi as the Mac, or refresh the Agent QR with a public relay."))
            }
            candidates = wan
        }

        // Bound the whole redeem — never spin on 正在配对 for minutes on a dead LAN relay.
        let redeemed: (ticket: String, name: String, chosen: RE2RelayCandidate) = try await withThrowingTaskGroup(
            of: (String, String, RE2RelayCandidate).self
        ) { group in
            group.addTask { @MainActor in
                var last: Error = RE2Error.signaling(String(localized: "Pairing failed"))
                for (idx, cand) in candidates.enumerated() {
                    do {
                        self.signaling?.close()
                        let sig = RE2SignalingClient()
                        self.signaling = sig
                        self.statusText = idx == 0
                            ? String(localized: "Pairing…")
                            : String(localized: "Trying backup relay…")
                        RE2Log.info("pairRedeem try[\(idx)] relay=\(cand.relay)")
                        try await sig.connect(relay: cand.relay)
                        try await sig.writeFrame(RE2Frame(
                            type: RE2.OuterType.pairRedeem,
                            routeID: payload.deviceID,
                            payload: RE2Codec.jsonData([
                                "device_id": payload.deviceID,
                                "pairing_token": payload.pairingToken,
                                "client_noise_pub": ""
                            ])
                        ))
                        let pairFrame = try await self.readSignalingSkippingPing(sig)
                        if pairFrame.type == RE2.OuterType.error {
                            throw self.annotated(Self.mapErrorPayload(pairFrame.payload))
                        }
                        guard pairFrame.type == RE2.OuterType.pairAck else {
                            throw RE2Error.signaling(String(localized: "Unexpected pair response"))
                        }
                        let ack = RE2Codec.jsonObject(pairFrame.payload)
                        let ticket = ack["session_ticket"] as? String ?? ""
                        let name = ack["name"] as? String ?? payload.name
                        self.deviceID = ack["device_id"] as? String ?? payload.deviceID
                        guard !ticket.isEmpty else { throw RE2Error.signaling(String(localized: "Missing session ticket")) }
                        RE2Log.info("pairAck ok via=\(cand.relay) ticketLen=\(ticket.count)")
                        return (ticket, name, cand)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        last = error
                        RE2Log.error("pairRedeem try[\(idx)] failed: \(error)")
                        continue
                    }
                }
                throw last
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 25_000_000_000)
                RE2Log.error("pairRedeem deadline 25s — abort")
                await MainActor.run {
                    self.signaling?.failPendingReads(RE2Error.signaling("pair timeout"))
                    self.signaling?.close()
                }
                throw RE2Error.signaling(String(localized: "Pairing timed out. On cellular you need a public relay QR; on Wi‑Fi join the Mac’s network and retry."))
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                await MainActor.run { self.signaling?.close() }
                throw error
            }
        }
        let ticket = redeemed.ticket
        let name = redeemed.name
        let chosen = redeemed.chosen

        let alts = payload.relayTryList.filter { $0.relay != chosen.relay }
        let profile = PairedDesktop(
            id: UUID(),
            name: name.isEmpty ? String(localized: "Desktop") : name,
            deviceID: deviceID,
            relayURL: chosen.relay,
            udpHostPort: chosen.udp ?? payload.udp ?? "",
            sessionTicket: ticket,
            pairingToken: payload.pairingToken,
            noisePub: payload.noisePub,
            expiresAt: payload.expiresAt,
            createdAt: Date(),
            lanCandidates: payload.lan,
            alternateRelays: alts
        )
        paired = profile
        refreshLanEndpointsDisplay()
        if let pw = accessPassword, !pw.isEmpty {
            RE2DesktopSecrets.savePassword(pw, desktopID: profile.id)
        }
        try await bindAndOpen(profile: profile, accessPassword: accessPassword)
        return paired!
    }

    func reconnect(profile: PairedDesktop, accessPassword: String? = nil, force: Bool = false) async throws {
        // After PairRedeem, reconnect is BIND → ASSOC(ticket) → Noise(PSK) → OPEN_DESKTOP.
        // Never re-Redeem the QR token; QR expires_at must not block this path.
        guard profile.canReconnect else {
            throw annotated(RE2Error.needsRescan)
        }
        // Preserve Simulator E2E force-path flags across reconnect (background
        // soft-teardown used to wipe them and leave probes stuck on wrong path).
        let keepE2EWSS = Self.e2eForceWSS
        let keepE2EUDP = Self.e2eForceUDP
        let keepE2EStrip = Self.e2eStripLAN
        let keepE2EABR = Self.e2eSuppressABR
        Self.e2eForceWSS = false
        Self.e2eForceUDP = false
        Self.e2eStripLAN = false
        Self.e2eSuppressABR = false
        autoReconnect = true
        // Manual / intentional reconnect may BIND-steal; that is OK when the user asks.
        reconnectAttempts = 0
        hadActiveDesktop = false
        awaitingNetworkRestore = false
        suspendedForBackground = false
        // disconnect() clears sockets; keep post-background WSS preference across it.
        let keepForceWSS = forceWSSNextConnect
        disconnect(userInitiated: false)
        forceTakeover = force
        forceWSSNextConnect = keepForceWSS
        Self.e2eForceWSS = keepE2EWSS
        Self.e2eForceUDP = keepE2EUDP
        Self.e2eStripLAN = keepE2EStrip
        Self.e2eSuppressABR = keepE2EABR
        lastError = nil
        recoveryHint = nil
        skipUDPNoiseUntil = nil
        recentUDPNoiseFailures = 0
        paired = profile
        refreshLanEndpointsDisplay()
        deviceID = profile.deviceID
        pairingToken = profile.pairingToken
        let resolved = accessPassword
            ?? self.accessPassword
            ?? RE2DesktopSecrets.loadPassword(desktopID: profile.id)
        self.accessPassword = resolved
        if let pw = resolved, !pw.isEmpty {
            RE2DesktopSecrets.savePassword(pw, desktopID: profile.id)
        }
        if let pub = profile.noisePub, let data = Self.b64url(pub), data.count == 32 {
            pinnedNoisePub = data
        }
        phase = .reconnecting
        statusText = String(localized: "Reconnecting…")
        RE2Log.info("reconnect device=\(profile.deviceID.prefix(12))… lan=\(profile.lanCandidates.joined(separator: ",")) lastPath=\(profile.lastMediaPath ?? "auto")")

        var candidates: [RE2RelayCandidate] = [
            RE2RelayCandidate(relay: profile.relayURL, udp: profile.udpHostPort)
        ]
        for a in profile.alternateRelays where a.relay != profile.relayURL {
            candidates.append(a)
        }
        var lastErr: Error = RE2Error.signaling(String(localized: "Reconnect failed"))
        for (idx, cand) in candidates.enumerated() {
            var attempt = profile
            attempt.relayURL = cand.relay
            if let u = cand.udp, !u.isEmpty { attempt.udpHostPort = u }
            do {
                if idx > 0 {
                    statusText = String(localized: "Trying backup relay…")
                    RE2Log.info("reconnect failover try[\(idx)] relay=\(cand.relay)")
                }
                try await bindAndOpen(profile: attempt, accessPassword: self.accessPassword)
                // Prefer the working relay next time.
                var saved = attempt
                saved.alternateRelays = candidates.filter { $0.relay != cand.relay }
                paired = saved
                return
            } catch {
                lastErr = error
                RE2Log.error("reconnect try[\(idx)] failed: \(error)")
                // A backup relay knows nothing about the active controller.
                if case .controllerBusy = error as? RE2Error { break }
            }
        }
        throw lastErr
    }

    func enterBackground() {
        let active = phase == .streaming || phase == .openingDesktop || hadActiveDesktop
        guard active, paired?.canReconnect == true else {
            statusText = isStreaming ? String(localized: "Background") : statusText
            return
        }
        guard backgroundGraceTask == nil, !suspendedForBackground else { return }
        // A resume probe from a previous quick trip must not decide while we are away.
        lifecycleEpoch &+= 1
        foregroundReconnectTask?.cancel()
        foregroundReconnectTask = nil
        let grace = Self.backgroundGraceSeconds
        guard grace > 0 else {
            suspendForBackground()
            return
        }
        // Short trips out (Settings to flip Wi‑Fi, a quick reply) keep the live session;
        // a background task keeps the sockets running meanwhile.
        RE2Log.info("app background — keep session for \(Int(grace))s grace")
        beginBackgroundTime()
        backgroundGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.backgroundGraceTask = nil
            guard UIApplication.shared.applicationState != .active else {
                self.endBackgroundTime()
                return
            }
            self.suspendForBackground()
        }
    }

    private func beginBackgroundTime() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "koko.desktop.grace") { [weak self] in
            // iOS is about to suspend: say goodbye now instead of leaving a frozen session.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.backgroundGraceTask?.cancel()
                self.backgroundGraceTask = nil
                if !self.suspendedForBackground, UIApplication.shared.applicationState != .active {
                    self.suspendForBackground()
                } else {
                    self.endBackgroundTime()
                }
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// Long stay in background: iOS freezes / kills UDP+WSS — tear down and rebuild on return.
    private func suspendForBackground() {
        let active = phase == .streaming || phase == .openingDesktop || hadActiveDesktop
            || (phase == .failed && autoReconnect)
        guard active, paired?.canReconnect == true, !suspendedForBackground else {
            endBackgroundTime()
            return
        }
        RE2Log.info("app background — soft teardown, will reconnect on foreground")
        lifecycleEpoch &+= 1
        foregroundReconnectTask?.cancel()
        foregroundReconnectTask = nil
        suspendedForBackground = true
        // Prefer LAN/UDP after resume when QR has lan:port. Forcing WSS-first raced
        // Agent "WSS Noise ignored — session already live" and showed Failed until
        // the user tapped Reconnect (by then UDP stale-clear had finished).
        forceWSSNextConnect = !Self.e2eForceUDP && !Self.hasUsableLAN(paired?.lanCandidates ?? [])
        autoReconnect = true
        statusText = String(localized: "Background")
        phase = .failed
        // Best-effort goodbye before sockets die (iOS suspend budget is short).
        // Keep the task so foreground cannot race it and have this teardown close
        // the newly-created signaling/UDP sockets.
        deferredNetworkChange = false
        let teardown = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.softTeardownForNetworkChange(notifyReason: "app_background")
            self.endBackgroundTime()
        }
        backgroundTeardownTask = teardown
    }

    func enterForeground() {
        if let grace = backgroundGraceTask {
            grace.cancel()
            backgroundGraceTask = nil
            endBackgroundTime()
            resumeAfterBackgroundGrace()
            return
        }
        if awaitingNetworkRestore, paired?.canReconnect == true, autoReconnect {
            forceWSSNextConnect = !Self.e2eForceUDP && !Self.hasUsableLAN(paired?.lanCandidates ?? [])
            scheduleForegroundReconnect(after: backgroundTeardownTask)
            return
        }
        if suspendedForBackground, paired?.canReconnect == true {
            forceWSSNextConnect = !Self.e2eForceUDP && !Self.hasUsableLAN(paired?.lanCandidates ?? [])
            autoReconnect = true
            let mode = forceWSSNextConnect ? "WSS-first" : "LAN-first"
            RE2Log.info("app foreground — wait teardown, then full desktop reconnect \(mode)")
            statusText = String(localized: "Reconnecting…")
            scheduleForegroundReconnect(after: backgroundTeardownTask)
            return
        }
        if phase == .failed || phase == .idle, let paired, autoReconnect, paired.canReconnect {
            forceWSSNextConnect = true
            Task { try? await reconnect(profile: paired, accessPassword: accessPassword) }
        } else if isStreaming {
            // App switcher / Control Center often only hits .inactive — sockets can die
            // without enterBackground. Detect a half-open signaling plane and rebuild.
            if signaling?.isOpen != true {
                RE2Log.info("app foreground — signaling dead while streaming, reconnect WSS-first")
                forceWSSNextConnect = true
                autoReconnect = true
                phase = .failed
                statusText = String(localized: "Reconnecting…")
                Task { @MainActor in
                    await self.softTeardownForNetworkChange()
                    await self.reconnectAfterNetworkChange()
                }
            } else {
                requestKeyframe()
                statusText = String(localized: "Connected")
            }
        }
    }

    /// Back within the grace period: keep the session when it is still carrying traffic;
    /// reconnect only when the network changed meanwhile or the link went quiet.
    private func resumeAfterBackgroundGrace() {
        let networkChanged = deferredNetworkChange
        deferredNetworkChange = false
        let live = isStreaming || phase == .openingDesktop
        guard live, !networkChanged, !awaitingNetworkRestore else {
            guard paired?.canReconnect == true, autoReconnect else { return }
            RE2Log.info("app foreground after grace — \(networkChanged ? "network changed" : "link dropped"), reconnect")
            forceWSSNextConnect = !Self.e2eForceUDP && !Self.hasUsableLAN(paired?.lanCandidates ?? [])
            phase = .failed
            statusText = String(localized: "Reconnecting…")
            scheduleForegroundReconnect(after: nil)
            return
        }
        RE2Log.info("app foreground within grace — probing live session")
        let since = Date()
        let epoch = frameEpoch
        // iOS may invalidate the hardware decoder while backgrounded: restart decode from a
        // fresh IDR (the last picture stays on screen until it arrives).
        videoAssembler = VideoFrameAssembler()
        decoder.reset()
        requestKeyframe(force: true)
        scheduleKeyframeRetry()
        lifecycleEpoch &+= 1
        let lifecycle = lifecycleEpoch
        foregroundReconnectTask?.cancel()
        foregroundReconnectTask = Task { @MainActor [weak self] in
            for _ in 0..<25 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled, self.lifecycleEpoch == lifecycle else { return }
                if (self.lastInboundAt.map { $0 >= since } ?? false) || self.frameEpoch != epoch {
                    RE2Log.info("app foreground — session kept (no reconnect)")
                    if self.isStreaming { self.statusText = String(localized: "Connected") }
                    return
                }
            }
            guard let self, self.lifecycleEpoch == lifecycle, self.isStreaming || self.phase == .openingDesktop,
                  self.paired?.canReconnect == true else { return }
            RE2Log.info("app foreground — no traffic after grace, reconnect")
            self.forceWSSNextConnect = !Self.e2eForceUDP && !Self.hasUsableLAN(self.paired?.lanCandidates ?? [])
            self.autoReconnect = true
            self.phase = .failed
            self.statusText = String(localized: "Reconnecting…")
            await self.softTeardownForNetworkChange()
            guard self.lifecycleEpoch == lifecycle else { return }
            await self.reconnectAfterNetworkChange()
        }
    }

    private func scheduleForegroundReconnect(after teardown: Task<Void, Never>?) {
        lifecycleEpoch &+= 1
        let epoch = lifecycleEpoch
        foregroundReconnectTask?.cancel()
        foregroundReconnectTask = Task { @MainActor [weak self] in
            if let teardown {
                await teardown.value
            }
            guard let self, !Task.isCancelled, self.lifecycleEpoch == epoch else { return }
            guard UIApplication.shared.applicationState == .active else {
                RE2Log.info("foreground reconnect skipped — app no longer active")
                return
            }
            self.backgroundTeardownTask = nil
            self.suspendedForBackground = false
            await self.reconnectAfterNetworkChange()
        }
    }

    /// QR/persisted `host:port` entries that are usable for PreferDirect probes.
    private static func hasUsableLAN(_ candidates: [String]) -> Bool {
        candidates.contains { !$0.isEmpty && !$0.hasSuffix(":0") }
    }

    // MARK: - network path (Wi‑Fi ↔ cellular / LAN ↔ WAN)

    private func startPathMonitor() {
        stopPathMonitor()
        lastPathFingerprint = nil
        let mon = NWPathMonitor()
        mon.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.noteNetworkPath(path)
            }
        }
        mon.start(queue: pathMonitorQueue)
        pathMonitor = mon
        // Do not seed from currentPath here: immediately after start it is often
        // `.requiresConnection`, then the monitor's first callback is `.satisfied`.
        // Treating that initial callback as a real path change started a second
        // reconnect in the middle of foreground Noise.
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathFingerprint = nil
    }

    private func noteNetworkPath(_ path: NWPath, isBaseline: Bool = false) {
        let fp = pathFingerprint(path)
        if isBaseline || lastPathFingerprint == nil {
            lastPathFingerprint = fp
            return
        }
        guard fp != lastPathFingerprint else { return }
        RE2Log.info("network path pending change \(lastPathFingerprint ?? "?") → \(fp)")
        pathChangeDebounce?.cancel()
        let unsatisfied = path.status != .satisfied
        pathChangeDebounce = Task { @MainActor [weak self] in
            // Keep the last picture through short blips, but start handoff quickly
            // enough to recover Wi‑Fi↔cellular within an interactive budget.
            let wait: UInt64 = unsatisfied ? 1_200_000_000 : 600_000_000
            try? await Task.sleep(nanoseconds: wait)
            guard let self, !Task.isCancelled else { return }
            let live = self.pathMonitor?.currentPath ?? path
            let now = self.pathFingerprint(live)
            guard now != self.lastPathFingerprint else { return }
            let previous = self.lastPathFingerprint

            // Live desktop on LAN/UDP: ignore almost all path noise. Only act on
            // sustained unsatisfied or a real Wi‑Fi ↔ cellular switch.
            let liveMedia = self.phase == .streaming || self.phase == .openingDesktop
            if liveMedia, live.status == .satisfied {
                let prevCell = previous?.contains("|cell") == true || previous?.split(separator: "|").contains("cell") == true
                let nowCell = live.usesInterfaceType(.cellular) && !live.usesInterfaceType(.wifi)
                let prevWifi = previous?.contains("wifi") == true
                let nowWifi = live.usesInterfaceType(.wifi)
                let wifiToCell = prevWifi && nowCell
                let cellToWifi = prevCell && nowWifi && !nowCell
                if !wifiToCell && !cellToWifi {
                    RE2Log.info("network path ignored while streaming (\(previous ?? "?") → \(now))")
                    self.lastPathFingerprint = now
                    return
                }
            }

            if live.status != .satisfied, liveMedia {
                // Two seconds total filters brief route churn without imposing the
                // previous 10s outage penalty before reconnect even started.
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                let again = self.pathMonitor?.currentPath ?? live
                if again.status == .satisfied {
                    let recovered = self.pathFingerprint(again)
                    RE2Log.info("network brief unsatisfied recovered — keep session → \(recovered)")
                    self.lastPathFingerprint = recovered
                    return
                }
            }

            self.lastPathFingerprint = now
            // Unstructured on purpose: reconnect() → disconnect(false) cancels
            // pathChangeDebounce, which used to cancel this very reconnect mid-BIND
            // (CancellationError → silent → "Binding…" forever after 5G → Wi‑Fi).
            let satisfied = live.status == .satisfied
            Task { @MainActor [weak self] in
                await self?.handleNetworkPathChange(previous: previous, current: now, satisfied: satisfied)
            }
        }
    }

    /// Fingerprint uses the phone IPv4 that shares a /24 with Agent QR `lan` —
    /// never "guess" among 10.x / 192.168 by preference order alone.
    private func pathFingerprint(_ path: NWPath) -> String {
        var parts: [String] = []
        parts.append(path.status == .satisfied ? "up" : "down")
        if path.usesInterfaceType(.wifi) { parts.append("wifi") }
        if path.usesInterfaceType(.cellular) { parts.append("cell") }
        if path.usesInterfaceType(.wiredEthernet) { parts.append("eth") }
        var agentHosts: [String] = []
        for c in paired?.lanCandidates ?? [] {
            if let h = Self.hostOnly(c) { agentHosts.append(h) }
        }
        if let d = Self.hostOnly(directPeerHostPort) { agentHosts.append(d) }
        if let lan = Self.localIPv4MatchingAgent(agentHosts) {
            parts.append(lan)
        }
        return parts.joined(separator: "|")
    }

    private static func samePrimaryLAN(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        let ap = a.split(separator: "|")
        let bp = b.split(separator: "|")
        let aIP = ap.last.map(String.init) ?? ""
        let bIP = bp.last.map(String.init) ?? ""
        let aWifi = ap.contains("wifi")
        let bWifi = bp.contains("wifi")
        return !aIP.isEmpty && aIP == bIP && aWifi && bWifi
    }

    private static func hostOnly(_ hostPort: String) -> String? {
        let t = hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let host = t.split(separator: ":").first.map(String.init) ?? t
        return host.isEmpty ? nil : host
    }

    private static func isVirtualIF(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("awdl")
            || name.hasPrefix("llw") || name.hasPrefix("anpi") || name.hasPrefix("ap")
    }

    private static func ipv4Octets(_ ip: String) -> [UInt8]? {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }

    /// Same /24 as Agent LAN from QR (e.g. Agent 192.168.1.115 → phone 192.168.1.116).
    /// Returns nil when no match — does **not** fall back to an unrelated RFC1918
    /// (cellular 10.x must not look like “on Agent LAN”).
    private static func localIPv4MatchingAgent(_ agentHosts: [String]) -> String? {
        let locals = enumerateLocalIPv4()
        for agent in agentHosts {
            let host = hostOnly(agent) ?? agent
            guard let a = ipv4Octets(host) else { continue }
            for (name, ip) in locals {
                if isVirtualIF(name) { continue }
                guard let b = ipv4Octets(ip) else { continue }
                if a[0] == b[0], a[1] == b[1], a[2] == b[2] {
                    return ip
                }
            }
        }
        return nil
    }

    /// True only when this phone has a non-virtual IPv4 on the same /24 as any Agent QR `lan`.
    /// 5G / other Wi‑Fi with no shared subnet → false → skip LAN PreferDirect entirely.
    private static func sharesSubnet24(withAgentLAN agentHostPorts: [String]) -> Bool {
        localIPv4MatchingAgent(agentHostPorts) != nil
    }

    private static func enumerateLocalIPv4() -> [(name: String, ip: String)] {
        var out: [(name: String, ip: String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0, let first = ptr else { return out }
        defer { freeifaddrs(first) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let c = cur {
            let flags = Int32(c.pointee.ifa_flags)
            let name = c.pointee.ifa_name != nil ? String(cString: c.pointee.ifa_name) : ""
            if flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
               let sa = c.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                if !ip.isEmpty, !ip.hasPrefix("169.254.") {
                    out.append((name, ip))
                }
            }
            cur = c.pointee.ifa_next
        }
        return out
    }

    private static func primaryPrivateIPv4() -> String? {
        let locals = enumerateLocalIPv4()
        let preferred = locals.first { !isVirtualIF($0.name) && $0.ip.hasPrefix("192.168.") }
            ?? locals.first { !isVirtualIF($0.name) && $0.ip.hasPrefix("10.") }
            ?? locals.first { !isVirtualIF($0.name) }
        return preferred?.ip
    }

    private static func localIPv4List() -> [String] {
        enumerateLocalIPv4().map(\.ip)
    }

    private func handleNetworkPathChange(previous: String?, current: String, satisfied: Bool) async {
        guard autoReconnect, paired?.canReconnect == true else { return }
        // In background iOS freezes sockets; a reconnect started there hangs until
        // foreground, which then owns the reconnect.
        if suspendedForBackground || backgroundGraceTask != nil {
            RE2Log.info("network path change while in background — reconnect on foreground (\(previous ?? "?") → \(current))")
            deferredNetworkChange = true
            return
        }
        // Ignore while mid-handshake unless restoring from outage, or a network reconnect
        // is running on the previous network (it gets superseded).
        let busy = phase == .binding || phase == .associating || phase == .handshaking
            || phase == .reconnecting
            || phase == .pairing || phase == .openingDesktop
        if busy, !awaitingNetworkRestore, !(networkReconnectInFlight && satisfied) { return }

        if !satisfied {
            // Never tear down a live picture on a blink — noteNetworkPath already
            // required sustained unsatisfied before calling here.
            RE2Log.info("network unsatisfied — soft teardown, await restore (\(previous ?? "?") → \(current))")
            awaitingNetworkRestore = true
            statusText = String(localized: "Network unavailable…")
            phase = .failed
            await softTeardownForNetworkChange(notifyReason: "network_change")
            return
        }

        // Satisfied again after outage, or real Wi‑Fi ↔ cellular switch.
        RE2Log.info("network changed — full desktop reconnect LAN-first (\(previous ?? "?") → \(current))")
        await reconnectAfterNetworkChange()
    }

    /// Tell Agent we are leaving so it can drop desktop + Noise before peer_gone races.
    private func notifyAgentLeaving(reason: String) async {
        let canSend = sendCipher != nil || (signaling != nil)
        guard canSend, !sessionID.isEmpty else { return }
        RE2Log.info("notify Agent goodbye reason=\(reason)")
        try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await self.sendInner(
                    RE2.Msg.desktopClose,
                    RE2Codec.jsonData([
                        "session_id": self.sessionID,
                        "reason": reason
                    ]),
                    reliable: false
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 350_000_000)
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    /// Close sockets but keep pairing + autoReconnect (path monitor drives the next connect).
    /// When `notifyReason` is set, best-effort `desktopClose` first (background / net drop).
    private func softTeardownForNetworkChange(notifyReason: String? = nil) async {
        if let reason = notifyReason {
            await notifyAgentLeaving(reason: reason)
        }
        suppressDisconnectHandling = true
        keepaliveTask?.cancel()
        keepaliveTask = nil
        recvTask?.cancel()
        recvTask = nil
        keyframeRetryTask?.cancel()
        keyframeRetryTask = nil
        audio.stop()
        endpoint?.close()
        endpoint = nil
        signaling?.close()
        signaling = nil
        sendCipher = nil
        recvCipher = nil
        videoMedia = nil
        videoPlaneActive = false
        usingP2P = false
        useWSSTunnel = false
        directPeerHostPort = ""
        pathLabel = ""
        suppressDisconnectHandling = false
    }

    /// Wi‑Fi↔蜂窝 / 内网↔跨网：清掉粘性路径，整链 BIND→探 LAN→UDP/WSS→OPEN。
    private func reconnectAfterNetworkChange() async {
        guard let profile = paired, profile.canReconnect else { return }
        if networkReconnectInFlight {
            // The running attempt may sit on sockets from the previous network (or ones iOS
            // froze in background) until its deadlines; fail it now and run again on this one.
            RE2Log.info("network reconnect supersedes in-flight attempt")
            networkReconnectRerun = true
            signaling?.failPendingReads(RE2Error.signaling("superseded by network change"))
            return
        }
        networkReconnectInFlight = true
        defer { networkReconnectInFlight = false }
        var attempts = 0
        while true {
            networkReconnectRerun = false
            attempts += 1
            let ok = await runNetworkReconnect(profile: paired ?? profile)
            if ok { return }
            let active = UIApplication.shared.applicationState == .active
            guard autoReconnect, active, paired?.canReconnect == true, attempts < 4 else { return }
            if !networkReconnectRerun {
                // One automatic retry: the first BIND right after a Wi‑Fi join often
                // races DHCP / DNS on the new interface.
                guard attempts < 2 else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard autoReconnect, !suspendedForBackground else { return }
            }
            RE2Log.info("network reconnect retry #\(attempts)")
        }
    }

    /// One full reconnect after a path change. On failure leaves `phase == .failed` so the
    /// next path change / foreground can start another one (a stuck `.binding` blocked both).
    private func runNetworkReconnect(profile: PairedDesktop) async -> Bool {
        awaitingNetworkRestore = false
        autoReconnect = true
        // Force re-evaluation of LAN vs relay (don't sticky-WSS across networks).
        var cleared = profile
        cleared.lastMediaPath = nil
        paired = cleared
        lanUpgradeAttempted = false
        statusText = String(localized: "Network changed — reconnecting…")
        do {
            try await reconnect(profile: cleared, accessPassword: accessPassword)
            RE2Log.info("network reconnect OK path=\(pathLabel)")
            return true
        } catch {
            RE2Log.error("network reconnect failed: \(error)")
            phase = .failed
            if let e = error as? RE2Error {
                if case .cancelled = e {} else {
                    lastError = e.localizedDescription
                    recoveryHint = e.recoveryHint
                }
                if e.stopsAutoReconnect { autoReconnect = false }
            } else if !(error is CancellationError) {
                lastError = error.localizedDescription
            }
            statusText = suspendedForBackground
                ? String(localized: "Background")
                : String(localized: "Disconnected")
            return false
        }
    }

    // MARK: - input / outbound

    /// Queued/in-flight outbound work. Above this, unreliable traffic is dropped.
    private var outboundDepth = 0
    private let maxOutboundDepth = 3
    private enum OutboundKind { case input, media, control }
    private struct OutboundJob {
        let kind: OutboundKind
        let body: @MainActor () async -> Void
    }
    /// Serial outbound jobs. Must NOT be a Task→await-previous chain: Swift
    /// priority escalation walks that chain recursively and overflows the stack
    /// (seen as EXC_BAD_ACCESS "excessive recursion" in enqueueOutbound).
    /// PreferDirect forces reliable AEAD for every packet — phone-cam must not
    /// sit ahead of mouse/gesture or input feels dead while webcam is on.
    private var outboundJobs: [OutboundJob] = []
    private var outboundDraining = false
    private var nextInputEventID: UInt64 = 1
    private var pendingMove: [String: Any]?
    private var moveFlushScheduled = false
    /// True while the viewer is pinching — drop move flood.
    private var remotePointerSuspended = false
    /// Drop phone-cam frames while a prior send burst is still draining.
    private var phoneCamSendBusy = false
    private var pendingPhoneCam: PendingPhoneCamFrame?
    private var phoneCamPumpRunning = false

    private func enqueueOutbound(
        kind: OutboundKind = .control,
        _ body: @escaping @MainActor () async -> Void
    ) {
        let job = OutboundJob(kind: kind, body: body)
        switch kind {
        case .input:
            // Jump ahead of media/control so Space-swipe / clicks stay live.
            // Do NOT drop media here — incomplete phone-cam parts → AkVCam RGB noise.
            if let idx = outboundJobs.firstIndex(where: { $0.kind != .input }) {
                outboundJobs.insert(job, at: idx)
            } else {
                outboundJobs.append(job)
            }
        case .media:
            outboundJobs.append(job)
        case .control:
            outboundJobs.append(job)
        }
        outboundDepth = outboundJobs.count + (outboundDraining ? 1 : 0)
        guard !outboundDraining else { return }
        outboundDraining = true
        Task { @MainActor [weak self] in
            while let self {
                guard !self.outboundJobs.isEmpty else { break }
                let next = self.outboundJobs.removeFirst()
                self.outboundDepth = self.outboundJobs.count + 1
                await next.body()
            }
            guard let self else { return }
            self.outboundDraining = false
            self.outboundDepth = self.outboundJobs.count
        }
    }

    /// Drop coalesced moves during pinch / gesture storms; clicks still go through.
    func suspendRemotePointer(_ suspended: Bool) {
        remotePointerSuspended = suspended
        if suspended {
            pendingMove = nil
        }
    }

    func inputTransportDebug() async -> String {
        guard let endpoint else { return useWSSTunnel ? "WSS" : "no endpoint" }
        return await endpoint.reliableDebugSnapshot()
    }

    func sendMouse(
        x: Double, y: Double,
        buttons: Int = 0,
        down: Bool = false, up: Bool = false, move: Bool = true,
        wheel: Int = 0, wheelH: Int = 0,
        relative: Bool = false, dx: Double = 0, dy: Double = 0,
        gesture: String? = nil, spaceDelta: Int = 0
    ) {
        let reliable = down || up || wheel != 0 || wheelH != 0 || gesture != nil
        if remotePointerSuspended, !reliable { return }

        var cdx = dx
        var cdy = dy
        if relative {
            cdx = min(max(dx, -120), 120)
            cdy = min(max(dy, -120), 120)
        }

        var obj: [String: Any] = [
            "session_id": sessionID,
            "x": x, "y": y,
            "buttons": buttons,
            "down": down, "up": up, "move": move
        ]
        if reliable {
            obj["event_id"] = nextInputEventID
            nextInputEventID &+= 1
        }
        if wheel != 0 { obj["wheel"] = wheel }
        if wheelH != 0 { obj["wheel_h"] = wheelH }
        if relative {
            obj["relative"] = true
            obj["dx"] = cdx
            obj["dy"] = cdy
        }
        if let gesture, !gesture.isEmpty {
            obj["gesture"] = gesture
            obj["space_delta"] = spaceDelta
            obj["move"] = false
        }
        // Optimistic local cursor: Agent CURSOR is unreliable UDP and often starved
        // by video, so the overlay would freeze while the Mac still moved.
        if gesture == nil {
            if relative {
                cursorX = min(max(cursorX + cdx / max(Double(desktopWidth), 1), 0), 1)
                cursorY = min(max(cursorY + cdy / max(Double(desktopHeight), 1), 0), 1)
            } else {
                cursorX = min(max(x, 0), 1)
                cursorY = min(max(y, 0), 1)
            }
            cursorVisible = true
        }
        if reliable {
            pendingMove = nil
            // Discrete clicks/gestures are prioritized over media and never dropped.
            let payload = RE2Codec.jsonData(obj)
            enqueueOutbound(kind: .input) { [weak self] in
                do {
                    try await self?.performSend(RE2.Msg.inputMouse, payload, reliable: true)
                } catch {
                    RE2Log.error("input mouse send failed: \(error)")
                }
            }
            return
        }
        if relative, let prev = pendingMove, (prev["relative"] as? Bool) == true {
            let sumDx = ((prev["dx"] as? Double) ?? 0) + cdx
            let sumDy = ((prev["dy"] as? Double) ?? 0) + cdy
            obj["dx"] = min(max(sumDx, -200), 200)
            obj["dy"] = min(max(sumDy, -200), 200)
            obj["x"] = x
            obj["y"] = y
        }
        pendingMove = obj
        guard !moveFlushScheduled else { return }
        moveFlushScheduled = true
        let interval: UInt64 = useWSSTunnel ? 50_000_000 : 16_000_000
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: interval)
            self.moveFlushScheduled = false
            guard !self.remotePointerSuspended else {
                self.pendingMove = nil
                return
            }
            // Pipe saturated → keep coalescing; skip this flush tick.
            if self.outboundDepth >= self.maxOutboundDepth {
                // Reschedule once so the latest move eventually goes out.
                if self.pendingMove != nil, !self.moveFlushScheduled {
                    self.moveFlushScheduled = true
                    let retry: UInt64 = self.useWSSTunnel ? 50_000_000 : 16_000_000
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: retry)
                        self.moveFlushScheduled = false
                        guard !self.remotePointerSuspended,
                              self.outboundDepth < self.maxOutboundDepth,
                              let moveObj = self.pendingMove else { return }
                        self.pendingMove = nil
                        let payload = RE2Codec.jsonData(moveObj)
                        self.enqueueOutbound(kind: .input) { [weak self] in
                            do {
                                try await self?.performSend(RE2.Msg.inputMouse, payload, reliable: false)
                            } catch {
                                RE2Log.error("input move send failed: \(error)")
                            }
                        }
                    }
                }
                return
            }
            guard let moveObj = self.pendingMove else { return }
            self.pendingMove = nil
            let payload = RE2Codec.jsonData(moveObj)
            self.enqueueOutbound(kind: .input) { [weak self] in
                do {
                    try await self?.performSend(RE2.Msg.inputMouse, payload, reliable: false)
                } catch {
                    RE2Log.error("input move send failed: \(error)")
                }
            }
        }
    }

    func sendTouch(x: Double, y: Double, phase: String) {
        let reliable = phase != "moved"
        if !reliable, outboundDepth >= maxOutboundDepth { return }
        var obj: [String: Any] = [
            "session_id": sessionID, "x": x, "y": y, "phase": phase
        ]
        if reliable {
            obj["event_id"] = nextInputEventID
            nextInputEventID &+= 1
        }
        let payload = RE2Codec.jsonData(obj)
        enqueueOutbound(kind: .input) { [weak self] in
            try? await self?.performSend(RE2.Msg.inputTouch, payload, reliable: reliable)
        }
    }

    func sendKey(text: String? = nil, keyCode: Int? = nil, down: Bool, modifiers: Int = 0) {
        var obj: [String: Any] = [
            "session_id": sessionID, "event_id": nextInputEventID,
            "down": down, "modifiers": modifiers
        ]
        nextInputEventID &+= 1
        if let text { obj["text"] = text }
        if let keyCode { obj["key_code"] = keyCode }
        let payload = RE2Codec.jsonData(obj)
        enqueueOutbound(kind: .input) { [weak self] in
            do {
                try await self?.performSend(RE2.Msg.inputKey, payload, reliable: true)
            } catch {
                RE2Log.error("input key send failed: \(error)")
            }
        }
    }

    func setInputMode(game: Bool) {
        // gameMouseMode == true → absolute finger pointing; false → trackpad (relative).
        gameMouseMode = game
        Task {
            try? await sendInner(RE2.Msg.inputMode, RE2Codec.jsonData([
                "session_id": sessionID,
                "relative_mouse": !game,
                "game_mode": game
            ]), reliable: true)
        }
    }

    func requestKeyframe(force: Bool = false) {
        if !force, let last = lastKeyframeAskAt, Date().timeIntervalSince(last) < 2.5 {
            return
        }
        lastKeyframeAskAt = Date()
        Task {
            try? await sendInner(RE2.Msg.keyframeReq, RE2Codec.jsonData([
                "session_id": sessionID, "reason": "client"
            ]), reliable: true)
        }
    }

    func refreshDisplays() {
        Task {
            try? await sendInner(RE2.Msg.displays, RE2Codec.jsonData([
                "session_id": sessionID, "action": "list"
            ]), reliable: true)
        }
    }

    func selectDisplay(_ id: Int) {
        // Always close+reopen. A same-id skip hid the case where UI thought we were
        // already on the target (stale DESKTOP_READY / omitempty display_id=0) while
        // capture stayed on the other monitor — "can leave secondary but not return".
        desiredDisplayID = id
        selectedDisplayID = id
        confirmedDisplayID = nil
        // Clear the previous monitor's frame immediately. The connecting overlay
        // (and "Switching display…") only appears when frameImage == nil; keeping
        // the old CGImage made display switches look like they did nothing.
        frameImage = nil
        // Drop stale DESKTOP_READY geometry so E2E / UI cannot treat the previous
        // monitor's 720p/1080p size as the new display.
        desktopWidth = 0
        desktopHeight = 0
        frameEpoch &+= 1
        lastDecodedAt = nil
        phase = .openingDesktop
        statusText = String(localized: "Switching display…")
        lastError = nil
        didApplyNativeQuality = true
        // Same patience as quality menu — 5K secondary OPEN must not hit attempt==3
        // conservative (frameImage cleared ⇒ false "no video" path).
        qualityChangeAwaitingPaint = true
        qualityChangeStartedAt = Date()
        RE2Log.info("selectDisplay id=\(id) — close+reopen")
        Task {
            do {
                try await sendInner(RE2.Msg.displays, RE2Codec.jsonData([
                    "session_id": sessionID, "action": "select", "display_id": id
                ]), reliable: true)
            } catch {
                RE2Log.error("selectDisplay list/select failed: \(error.localizedDescription)")
            }
            guard phase == .streaming || phase == .openingDesktop else {
                requestKeyframe(force: true)
                return
            }
            // Capture binds monitor at OPEN — re-OPEN so the chosen display is visible.
            do {
                try await sendInner(RE2.Msg.desktopClose, RE2Codec.jsonData([
                    "session_id": sessionID, "reason": "display_change"
                ]), reliable: true)
                sessionID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(16))
                var open = openDesktopParams(sessionID: sessionID, privacyBlank: privacyBlank)
                open["display_id"] = id
                if let pw = accessPassword, !pw.isEmpty { open["password"] = pw }
                videoAssembler = VideoFrameAssembler()
                decoder.reset()
                lastDecodedAt = nil
                resetVideoDebugCounters()
                phase = .openingDesktop
                statusText = String(localized: "Switching display…")
                qualityChangeAwaitingPaint = true
                qualityChangeStartedAt = Date()
                try await sendInner(RE2.Msg.openDesktop, RE2Codec.jsonData(open), reliable: true)
                requestKeyframe(force: true)
                scheduleKeyframeRetry()
            } catch {
                RE2Log.error("selectDisplay reopen failed: \(error.localizedDescription)")
                lastError = error.localizedDescription
                statusText = String(localized: "Display switch failed")
                // Keep session usable — do not tear down to .failed on a bad switch.
                phase = .streaming
                requestKeyframe(force: true)
            }
        }
    }

    func setPrivacyBlank(_ on: Bool) {
        privacyBlank = on
        guard paired != nil else { return }
        frameImage = nil
        frameEpoch &+= 1
        lastDecodedAt = nil
        phase = .openingDesktop
        statusText = on
            ? String(localized: "Privacy blank on…")
            : String(localized: "Privacy blank off…")
        qualityChangeAwaitingPaint = true
        qualityChangeStartedAt = Date()
        keyframeRetryTask?.cancel()
        keyframeRetryTask = nil
        // Share the quality-open generation so privacy ↔ quality taps cannot interleave.
        qualityOpenGen &+= 1
        let gen = qualityOpenGen
        qualityOpenTask?.cancel()
        qualityOpenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled, gen == self.qualityOpenGen else { return }
            self.didApplyNativeQuality = true
            // Same as quality OPEN: skip desktopClose — Agent openDesktop tears down.
            guard gen == self.qualityOpenGen else { return }
            self.sessionID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(16))
            var open: [String: Any] = self.openDesktopParams(sessionID: self.sessionID, privacyBlank: on)
            if let pw = self.accessPassword, !pw.isEmpty { open["password"] = pw }
            self.videoAssembler = VideoFrameAssembler()
            self.decoder.reset()
            self.lastDecodedAt = nil
            self.phase = .openingDesktop
            try? await self.sendInner(RE2.Msg.openDesktop, RE2Codec.jsonData(open), reliable: true)
            guard gen == self.qualityOpenGen else { return }
            self.qualityChangeAwaitingPaint = true
            self.qualityChangeStartedAt = Date()
            self.requestKeyframe(force: true)
            self.scheduleKeyframeRetry()
        }
    }

    // MARK: - clipboard

    func sendClipboardText(_ text: String) {
        Task {
            try? await sendInner(RE2.Msg.clipboard, RE2Codec.jsonData([
                "session_id": sessionID, "mime": "text/plain", "text": text
            ]), reliable: true)
        }
    }

    func sendClipboardPNG(_ data: Data) {
        Task {
            try? await sendInner(RE2.Msg.clipboard, RE2Codec.jsonData([
                "session_id": sessionID,
                "mime": "image/png",
                "data_b64": data.base64EncodedString()
            ]), reliable: true)
        }
    }

    func pushLocalClipboard() {
        let pb = UIPasteboard.general
        if let text = pb.string, !text.isEmpty {
            sendClipboardText(text)
        } else if let img = pb.image, let png = img.pngData() {
            sendClipboardPNG(png)
        }
    }

    // MARK: - files

    func listRemoteFiles(path: String = "") {
        // Do not assign remotePath from the *request* — "../" probes would corrupt
        // relative path joins until a success response arrives.
        fileListError = nil
        Task {
            try? await sendInner(RE2.Msg.fileList, RE2Codec.jsonData([
                "session_id": sessionID, "path": path
            ]), reliable: true)
        }
    }

    /// Drain buffered Noise/control while a file RPC is waiting — PreferDirect
    /// video decode frequently starves the normal recv loop (ctrl backlog, waiters=0).
    private func pumpControlWhileFileWaiting() async {
        var n = 0
        while n < 32, let ct = endpoint?.popControl() {
            n += 1
            await decryptUDPCiphertext(ct)
        }
    }

    /// E2E pull loop needs the same drain (Offer/Chunk replies).
    func pumpControlWhileFileWaitingPublic() async {
        await pumpControlWhileFileWaiting()
    }

    /// Awaitable FileList for E2E. Must NOT await sendInner on the MainActor caller's
    /// cooperative thread — that deadlocks the recv loop which also needs MainActor.
    /// Detects empty-list / error replies via `fileListReplyGen` (count alone is racy).
    @discardableResult
    func listRemoteFilesAndWait(path: String = "", timeout: Double = 10) async -> Bool {
        fileListError = nil
        let sid = sessionID
        let body = RE2Codec.jsonData(["session_id": sid, "path": path])
        let prior = fileListReplyGen
        Task { [weak self] in
            do {
                try await self?.sendInner(RE2.Msg.fileList, body, reliable: true)
                RE2Log.info("file TX LIST path=\(path) queued-ok")
            } catch {
                RE2Log.error("file TX LIST failed: \(error.localizedDescription)")
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fileListReplyGen != prior { return true }
            await pumpControlWhileFileWaiting()
            if fileListReplyGen != prior { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let snap = endpoint?.debugIngressSnapshot() ?? "no-ep"
        RE2Log.error("file LIST wait timeout path=\(path) ingress=\(snap)")
        return fileListReplyGen != prior
    }

    private func resumeFileListWaiter(ok: Bool) {
        fileListReplyGen &+= 1
        if let w = fileListWaiter {
            fileListWaiter = nil
            w.resume(returning: ok)
        }
    }

    /// Raw file-chunk budget: WSS can take large parts; UDP Noise must fit REUDP 1200.
    private func fileChunkRawBytes() -> Int {
        if useWSSTunnel { return 48 * 1024 }
        // MaxPayload - NoiseTag - EncodeInnerHdr - JSON envelope → base64 → raw.
        return max(48, ((REUDP.maxPayload - 16 - 5 - 220) * 3) / 4)
    }

    func pullRemoteFile(path: String, name: String, resumeFrom: Int64 = 0) {
        let fileID = UUID().uuidString
        let dest = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RE2Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let url = dest.appendingPathComponent(name)
        if resumeFrom == 0 { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: url) {
            if resumeFrom > 0 { try? handle.seek(toOffset: UInt64(resumeFrom)) }
            incomingFiles[fileID] = (name, handle, 0)
            upsertTransfer(RE2TransferProgress(
                fileID: fileID, name: name, direction: .download,
                bytesDone: resumeFrom, bytesTotal: 0, finished: false
            ))
        }
        Task {
            do {
                try await sendInner(RE2.Msg.filePull, RE2Codec.jsonData([
                    "session_id": sessionID,
                    "file_id": fileID,
                    "path": path,
                    "resume_from": resumeFrom
                ]), reliable: true)
                RE2Log.info("file TX PULL path=\(path) id=\(fileID.prefix(8))")
            } catch {
                RE2Log.error("file TX PULL failed: \(error.localizedDescription)")
                upsertTransfer(RE2TransferProgress(
                    fileID: fileID, name: name, direction: .download,
                    bytesDone: 0, bytesTotal: 0, finished: true,
                    error: error.localizedDescription
                ))
            }
        }
    }

    func uploadLocalFile(url: URL) async throws {
        let data = try Data(contentsOf: url)
        let fileID = UUID().uuidString
        let name = url.lastPathComponent
        upsertTransfer(RE2TransferProgress(
            fileID: fileID, name: name, direction: .upload,
            bytesDone: 0, bytesTotal: Int64(data.count), finished: false
        ))
        let offerBody = RE2Codec.jsonData([
            "session_id": sessionID,
            "file_id": fileID,
            "name": name,
            "size": data.count,
            "mime": "application/octet-stream"
        ])
        // Register ACK waiter synchronously BEFORE offer leave this actor.
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if let early = self.pendingUploadAcks.removeValue(forKey: fileID) {
                    if early.ok { cont.resume() }
                    else { cont.resume(throwing: RE2Error.signaling(early.error ?? "file rejected")) }
                    return
                }
                self.uploadAcks[fileID] = cont
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if let parked = self.uploadAcks.removeValue(forKey: fileID) {
                        parked.resume(throwing: RE2Error.signaling("file ACK timeout"))
                    }
                }
                Task { [weak self] in
                    do {
                        try await self?.sendInner(RE2.Msg.fileOffer, offerBody, reliable: true)
                        RE2Log.info("file TX OFFER id=\(fileID.prefix(8)) name=\(name) size=\(data.count)")
                    } catch {
                        RE2Log.error("file TX OFFER failed: \(error.localizedDescription)")
                        if let parked = self?.uploadAcks.removeValue(forKey: fileID) {
                            parked.resume(throwing: error)
                        } else {
                            self?.pendingUploadAcks[fileID] = (false, error.localizedDescription)
                        }
                    }
                }
                // Keep draining Noise/control while we wait — same starvation as FileList.
                Task { @MainActor [weak self] in
                    for _ in 0..<300 {
                        guard let self, self.uploadAcks[fileID] != nil else { return }
                        await self.pumpControlWhileFileWaiting()
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
            }
        } catch {
            RE2Log.error("file upload ACK failed for \(name): \(error.localizedDescription)")
            upsertTransfer(RE2TransferProgress(
                fileID: fileID, name: name, direction: .upload,
                bytesDone: 0, bytesTotal: Int64(data.count), finished: true,
                error: error.localizedDescription
            ))
            throw error
        }
        let chunkSize = fileChunkRawBytes()
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let slice = data[offset..<end]
            try await sendInner(RE2.Msg.fileChunk, RE2Codec.jsonData([
                "session_id": sessionID,
                "file_id": fileID,
                "offset": offset,
                "data_b64": Data(slice).base64EncodedString(),
                "eof": end >= data.count
            ]), reliable: true)
            offset = end
            upsertTransfer(RE2TransferProgress(
                fileID: fileID, name: name, direction: .upload,
                bytesDone: Int64(offset), bytesTotal: Int64(data.count),
                finished: end >= data.count
            ))
        }
    }

    // MARK: - hole punch / WOL / camera

    func startHolePunch() {
        // PreferDirect on the Agent must not run while App media is still on WSS tunnel.
        guard !useWSSTunnel else {
            RE2Log.info("skip holePunch — media still on WSS (use Retry P2P to upgrade)")
            return
        }
        if Self.e2eStripLAN {
            RE2Log.info("skip holePunch — E2E stripLAN (force UDP·Relay)")
            return
        }
        Task {
            let lan = (paired?.lanCandidates ?? []).filter { !$0.isEmpty && !$0.hasSuffix(":0") }
            var agentHosts: [String] = lan.compactMap { Self.hostOnly($0) }
            if let d = Self.hostOnly(directPeerHostPort) { agentHosts.append(d) }

            // Only skip when LAN P2P is already locked (same /24 as Agent). Cross-network /
            // public punch must still offer candidates — do not require Agent /24 match.
            if usingP2P, Self.sameSlash24(Self.hostOnly(directPeerHostPort), agentHosts) {
                RE2Log.info("skip holePunch offer — LAN PreferDirect already \(directPeerHostPort)")
                return
            }

            let listen = await endpoint?.ensureDirectListener() ?? ""
            let portHint = listen.isEmpty ? endpoint?.localHostPort : listen
            var port = 0
            if let hint = portHint {
                let parts = hint.split(separator: ":", maxSplits: 1)
                if parts.count == 2, let p = Int(parts[1]), p > 0 { port = p }
            }

            // Structural filter: drop virtual NICs (VPN/utun/…). Never hard-code a host.
            // Same /24 as Agent first; if none (WAN / other Wi‑Fi), advertise other
            // non-virtual addresses so REHP1 / future srflx can still punch.
            var sameSubnet: [String] = []
            var otherSubnet: [String] = []
            for (name, ip) in Self.enumerateLocalIPv4() {
                if Self.isVirtualIF(name) { continue }
                if ip.hasPrefix("169.254.") { continue }
                guard port > 0 else { continue }
                let hp = "\(ip):\(port)"
                if Self.sameSlash24(ip, agentHosts) {
                    sameSubnet.append(hp)
                } else {
                    otherSubnet.append(hp)
                }
            }
            // Same-LAN: only same-/24 (VPN on another RFC1918 must not steal PreferDirect).
            // Cross-network: all remaining non-virtual locals.
            let local = sameSubnet.isEmpty ? otherSubnet : sameSubnet
            if local.isEmpty {
                RE2Log.info("holePunch skip — no usable local UDP candidate (virtual filtered); listen=\(listen)")
                return
            }

            let token = UUID().uuidString
            if !lan.isEmpty {
                RE2Log.info("LAN candidates from QR: \(lan.joined(separator: ","))")
                Task { await self.establishDirect(peers: lan, token: token) }
            }
            let udpSelf = local.first ?? listen
            RE2Log.info("holePunch offer self=\(udpSelf) local=\(local.joined(separator: ",")) sameLAN=\(!sameSubnet.isEmpty)")
            try? await sendInner(RE2.Msg.holePunch, RE2Codec.jsonData([
                "session_id": sessionID,
                "action": "offer",
                "token": token,
                "candidates": local,
                "udp_addr": udpSelf
            ]), reliable: true)
        }
    }

    private static func sameSlash24(_ host: String?, _ agents: [String]) -> Bool {
        guard let host, let b = ipv4Octets(host) else { return false }
        for aHost in agents {
            guard let a = ipv4Octets(aHost) else { continue }
            if a[0] == b[0], a[1] == b[1], a[2] == b[2] { return true }
        }
        return false
    }

    func wakeOnLAN(mac: String) {
        Task {
            try? await sendInner(RE2.Msg.wakeOnLAN, RE2Codec.jsonData([
                "session_id": sessionID, "mac": mac
            ]), reliable: true)
        }
    }

    func requestCameraList() {
        Task {
            try? await sendInner(RE2.Msg.cameraList, RE2Codec.jsonData([
                "session_id": sessionID
            ]), reliable: true)
        }
    }

    // MARK: - private connect

    private func bindAndOpen(profile: PairedDesktop, accessPassword: String?) async throws {
        phase = phase == .reconnecting ? .reconnecting : .binding
        statusText = String(localized: "Binding…")
        didFatUDPConservative = false
        RE2Log.info("bind start device=\(profile.deviceID.prefix(16))… ticketLen=\(profile.sessionTicket.count)")

        let updated: PairedDesktop = try await withThrowingTaskGroup(of: PairedDesktop.self) { group in
            group.addTask { @MainActor in
                try await self.performBind(profile: profile)
            }
            // Deadline must NOT be @MainActor — a stuck BIND write/read on MainActor
            // would otherwise prevent the timeout from ever firing ("Binding…" forever).
            group.addTask {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                RE2Log.error("BIND deadline 20s — abort")
                await MainActor.run {
                    self.signaling?.failPendingReads(RE2Error.signaling("bind timeout"))
                    self.signaling?.close()
                }
                throw RE2Error.signaling(String(localized: "Binding timed out. Check network / Agent online, then reconnect."))
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                await MainActor.run { self.signaling?.close() }
                throw error
            }
        }
        paired = updated
        refreshLanEndpointsDisplay()
        try await establishDataPlane(profile: updated, accessPassword: accessPassword)
    }

    /// Fresh WS + BIND only (no desktop open). Hard-timeout friendly.
    private func performBind(profile: PairedDesktop) async throws -> PairedDesktop {
        // Always use a fresh signaling socket for BIND — reusing a half-dead WS
        // after background/network teardown was a common "Binding…" hang.
        signaling?.close()
        signaling = nil
        let sig = RE2SignalingClient()
        signaling = sig
        try await sig.connect(relay: profile.relayURL)

        RE2ControllerIdentity.name = UIDevice.current.name
        try await sig.writeFrame(RE2Frame(
            type: RE2.OuterType.bind,
            routeID: profile.deviceID,
            payload: RE2ControllerIdentity.bindPayload(
                deviceID: profile.deviceID, sessionTicket: profile.sessionTicket, force: forceTakeover
            )
        ))
        let bindFrame = try await readSignalingSkippingPing(sig)
        if bindFrame.type == RE2.OuterType.error {
            throw annotated(escalateTicketFailure(Self.mapErrorPayload(bindFrame.payload)))
        }
        guard bindFrame.type == RE2.OuterType.bindOK else {
            throw annotated(escalateTicketFailure(RE2Error.ticketRejected))
        }
        ticketAuthFailures = 0
        forceTakeover = false
        let bok = RE2Codec.jsonObject(bindFrame.payload)
        var updated = profile
        if let u = bok["udp"] as? String, !u.isEmpty {
            updated.udpHostPort = u
        } else if updated.udpHostPort.isEmpty {
            updated.udpHostPort = RE2.udpHostPort(from: profile.relayURL, bindUDP: nil, qrUDP: nil) ?? ""
        }
        guard !updated.udpHostPort.isEmpty else { throw RE2Error.udp(String(localized: "No UDP endpoint")) }
        RE2Log.info("bindOK udp=\(updated.udpHostPort)")
        return updated
    }

    private func establishDataPlane(profile: PairedDesktop, accessPassword: String?) async throws {
        phase = .associating
        statusText = String(localized: "Connecting UDP…")
        useWSSTunnel = false
        lanUpgradeAttempted = false
        let lan = profile.lanCandidates.filter { !$0.isEmpty && !$0.hasSuffix(":0") }
        RE2Log.info("dataPlane start udp=\(profile.udpHostPort) prefer=\(profile.lastMediaPath ?? "auto") lan=\(lan.joined(separator: ","))")
        // Need NWPath before LAN gate — previously monitor started only after OPEN,
        // so wifi/cellular flags were always false and /24-only skip misfired to WSS.
        if pathMonitor == nil {
            startPathMonitor()
        }

        // LAN probe gate (strict cellular skip PreferDirect, permissive Wi-Fi):
        // - Cellular-only + no /24 match → skip REHP1 / UDP·LAN only (still try
        //   public UDP·Relay first below; WSS is fallback after UDP fail).
        // - Wi-Fi up → always REHP1 even if /24 not matched yet (Local Network
        //   permission / IP enumerate lag used to false-negative → wrong path
        //   while phone and Agent were on the same SSID).
        var reachableLAN: [String] = []
        let pathNow = pathMonitor?.currentPath
        let wifiUp = pathNow?.usesInterfaceType(.wifi) == true
            || pathNow?.usesInterfaceType(.wiredEthernet) == true
        let cellularOnly = pathNow?.usesInterfaceType(.cellular) == true && !wifiUp
        let sameSubnet = !lan.isEmpty && Self.sharesSubnet24(withAgentLAN: lan)
        let localsDump = Self.enumerateLocalIPv4()
            .filter { !Self.isVirtualIF($0.name) }
            .map { "\($0.name)=\($0.ip)" }
            .joined(separator: ",")
        RE2Log.info("LAN gate sameSubnet=\(sameSubnet) wifi=\(wifiUp) cellOnly=\(cellularOnly) locals=[\(localsDump)] agentLan=\(lan.joined(separator: ","))")

        if !lan.isEmpty, cellularOnly, !sameSubnet {
            RE2Log.info("skip LAN PreferDirect — cellular-only, not same /24 (public UDP·Relay still first)")
        } else if !lan.isEmpty, sameSubnet || wifiUp {
            statusText = String(localized: "Trying LAN…")
            // Real devices: Wi-Fi / Local Network permission can make the first
            // probe flaky — retry before giving up on LAN.
            for round in 0..<3 {
                reachableLAN = await probeReachableLAN(lan, perPeerTimeout: 1.6)
                if !reachableLAN.isEmpty { break }
                RE2Log.info("REHP1 miss round \(round + 1)/3 — retry")
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if !reachableLAN.isEmpty {
                RE2Log.info("LAN reachable \(reachableLAN.joined(separator: ",")) — UDP+P2P before OPEN")
            } else {
                // Wi-Fi/same-/24 but REHP1 failed — do NOT optimistic PreferDirect
                // (stale lan:port black-holes Noise). Fall through to public UDP/WSS.
                RE2Log.info("REHP1 miss (wifi=\(wifiUp) same/24=\(sameSubnet)) — public UDP·Relay first (no optimistic LAN)")
            }
        }

        // Proven LAN → UDP PreferDirect. Otherwise public UDP·Relay first.
        // Cellular / unknown WAN must NOT force WSS — that only skipped UDP·LAN;
        // WSS is for UDP Noise fail, cool-down, or post-background resume.
        let udpCooldown = skipUDPNoiseUntil.map { Date() < $0 } ?? false
        var preferWSS = false
        if forceWSSNextConnect {
            preferWSS = true
            forceWSSNextConnect = false
            RE2Log.info("forced WSS-first (post-background / resume)")
        } else if !reachableLAN.isEmpty {
            preferWSS = false
            skipUDPNoiseUntil = nil
            recentUDPNoiseFailures = 0
        } else if udpCooldown {
            preferWSS = true
            RE2Log.info("UDP Noise cool-down active — WSS first")
        } else {
            preferWSS = false
            if cellularOnly || (!wifiUp && !sameSubnet) {
                RE2Log.info("no LAN PreferDirect (cell=\(cellularOnly ? 1 : 0) wifi=\(wifiUp ? 1 : 0) /24=\(sameSubnet ? 1 : 0)) — public UDP·Relay first")
            } else if lan.isEmpty {
                RE2Log.info("no LAN in pairing — public UDP·Relay first")
            } else {
                RE2Log.info("LAN probe empty — public UDP·Relay first")
            }
        }

        if Self.e2eForceWSS {
            preferWSS = true
            RE2Log.info("E2E force WSS path")
        } else if Self.e2eForceUDP {
            preferWSS = false
            RE2Log.info("E2E force UDP path (lan=\(reachableLAN.joined(separator: ",")))")
        }
        var udpNoiseError: Error?

        if preferWSS {
            if lan.isEmpty {
                RE2Log.info("no LAN candidates — WSS first")
            } else if udpCooldown {
                RE2Log.info("UDP Noise cool-down active — WSS first (skip LAN thrash)")
            }
            statusText = String(localized: "Encrypting via relay…")
            do {
                try await runNoiseHandshakeWithDeadline(profile: profile, overUDP: false, seconds: 12)
                useWSSTunnel = true
            } catch {
                // Agent may still hold UDP·LAN ("WSS Noise ignored — session already live").
                // Falling back to UDP recovers; throwing Failed forced a manual Reconnect tap.
                RE2Log.error("WSS-first Noise failed — try UDP: \(error)")
                preferWSS = false
                lastError = nil
                recoveryHint = nil
            }
        }
        if !preferWSS {
            do {
                // Only REHP1-proven same-/24 peers get PreferDirect. Empty → relay UDP.
                let peers = reachableLAN
                try await bringUpUDPNoise(profile: profile, lan: peers)
                // Session id for hole-punch / OPEN — assign before LAN reinforce.
                sessionID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(16))
                // Reinforce PreferDirect if Noise still rode the relay.
                if !peers.isEmpty, !usingP2P {
                    statusText = String(localized: "Connecting LAN…")
                    _ = await preferDirectToLAN(peers)
                }
                if !useWSSTunnel, !peers.isEmpty {
                    startHolePunch()
                    for _ in 0..<12 {
                        if usingP2P { break }
                        try? await Task.sleep(nanoseconds: 80_000_000)
                    }
                    RE2Log.info("pre-OPEN LAN latch p2p=\(usingP2P) path=\(pathLabel)")
                }
            } catch {
                udpNoiseError = error
                recentUDPNoiseFailures += 1
                if recentUDPNoiseFailures >= 2 {
                    skipUDPNoiseUntil = Date().addingTimeInterval(90)
                    RE2Log.error("UDP Noise failed \(recentUDPNoiseFailures)× — cool-down 90s (WSS-first)")
                }
                RE2Log.error("UDP path failed → WSS fallback: \(error)")
                endpoint?.close()
                endpoint = nil
                sendCipher = nil
                recvCipher = nil
                videoMedia = nil
                videoPlaneActive = false
                usingP2P = false
                directPeerHostPort = ""
                // Transient UDP Noise failure must not stick as a user-facing error
                // while we still try WSS / open the desktop.
                lastError = nil
                recoveryHint = nil
                statusText = String(localized: "Encrypting via relay…")
                do {
                    // UDP/LAN bring-up can take 10–20s; relay often idle-closes WSS.
                    // Re-BIND on a fresh socket before WSS Noise or we get "WebSocket closed".
                    try await ensureSignalingForWSS(profile: profile)
                    try await runNoiseHandshakeWithDeadline(profile: profile, overUDP: false, seconds: 12)
                    useWSSTunnel = true
                    sessionID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(16))
                    lastError = nil
                    recoveryHint = nil
                } catch {
                    phase = .failed
                    statusText = String(localized: "Failed")
                    lastError = error.localizedDescription
                    if let e = error as? RE2Error { recoveryHint = e.recoveryHint }
                    RE2Log.error("WSS Noise also failed — giving up: \(error)")
                    throw error
                }
            }
        }
        if preferWSS, sessionID.isEmpty {
            sessionID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(16))
        }
        if let udpNoiseError {
            RE2Log.info("using WSS tunnel after UDP error: \(udpNoiseError)")
        }
        didFallbackVideoToWSS = useWSSTunnel
        refreshPathLabel()
        persistMediaPathHint()

        phase = .openingDesktop
        statusText = String(localized: "Opening desktop…")
        lastError = nil
        recoveryHint = nil
        if sessionID.isEmpty {
            sessionID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(16))
        }
        RE2Log.info("OPEN_DESKTOP session=\(sessionID) via=\(useWSSTunnel ? "wss" : "udp") path=\(pathLabel) lan=\(lan.joined(separator: ",")) p2p=\(usingP2P)")

        reconnectAttempts = 0
        recvTask?.cancel()
        recvTask = Task { [weak self] in await self?.receiveLoop() }
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in await self?.keepaliveLoop() }
        // UDP without pre-OPEN punch (no QR lan): still offer hole-punch now.
        // E2E stripLAN must stay on UDP·Relay — hole-punch would PreferDirect
        // via Agent candidates and mislabel the relay probe as UDP·LAN.
        if !useWSSTunnel, lan.isEmpty, !Self.e2eStripLAN {
            startHolePunch()
        }

        var open: [String: Any] = openDesktopParams(sessionID: sessionID, privacyBlank: privacyBlank)
        if let pw = accessPassword, !pw.isEmpty { open["password"] = pw }
        try await sendInner(RE2.Msg.openDesktop, RE2Codec.jsonData(open), reliable: true)

        // Host may show a confirm dialog before DESKTOP_READY.
        let opened = await waitUntilStreaming(timeout: 90)
        if !opened && phase == .openingDesktop {
            phase = .failed
            RE2Log.error("DESKTOP_READY timeout session=\(sessionID)")
            throw annotated(RE2Error.desktopOpenTimeout)
        }
        RE2Log.info("desktop open result streaming=\(opened) phase=\(String(describing: phase)) path=\(pathLabel) p2p=\(usingP2P)")
        persistMediaPathHint()

        // Reinforce P2P once desktop is live (Agent may PreferDirect on late candidates).
        if opened, !useWSSTunnel, !usingP2P, !lan.isEmpty {
            startHolePunch()
            _ = await preferDirectToLAN(lan)
            refreshPathLabel()
            persistMediaPathHint()
        }

        // Do NOT auto-upgrade WSS→UDP mid-stream. upgradeMediaToLAN re-Noises the
        // Agent while the App still holds WSS keys → first frames OK, then freeze
        // (exactly the "WSS relay freezes after a few seconds" field bug).
        // LAN must be selected on first connect via REHP1; user can tap Retry P2P.
        if opened, useWSSTunnel, !lan.isEmpty {
            RE2Log.info("stay on WSS — auto LAN upgrade disabled (use Retry P2P)")
        }

        if opened {
            startPathMonitor()
        }
    }

    /// Parallel REHP1 probes — any pong means same LAN is usable for PreferDirect.
    private func probeReachableLAN(_ lan: [String], perPeerTimeout: TimeInterval) async -> [String] {
        guard !lan.isEmpty else { return [] }
        let token = "lanprobe"
        return await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for peer in lan {
                group.addTask {
                    await RE2HolePunch.tryDirect(peerHostPort: peer, token: token, timeout: perPeerTimeout)
                }
            }
            var ok: [String] = []
            for await r in group {
                if let r { ok.append(r) }
            }
            return ok
        }
    }

    /// ASSOC → (optional LAN PreferDirect) → Noise over UDP.
    /// Same-LAN must latch direct *before* Noise: volunteer-relay UDP often drops
    /// Noise msg1/msg2 ("no handshake reply") even when Wi‑Fi peer is reachable.
    private func bringUpUDPNoise(profile: PairedDesktop, lan: [String]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                // Keep BIND WebSocket alive while ASSOC/LAN/Noise runs (relay idle-timeout).
                let keepAlive = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        self.signaling?.sendKeepalivePing()
                    }
                }
                defer { keepAlive.cancel() }

                let ep = try REUDPEndpoint(hostPort: profile.udpHostPort)
                self.endpoint = ep
                try await withThrowingTaskGroup(of: Void.self) { startGroup in
                    startGroup.addTask { try await ep.start() }
                    startGroup.addTask {
                        try await Task.sleep(nanoseconds: 8_000_000_000)
                        throw RE2Error.udp("UDP connect timeout")
                    }
                    do {
                        try await startGroup.next()!
                        startGroup.cancelAll()
                    } catch {
                        startGroup.cancelAll()
                        ep.close()
                        throw error
                    }
                }
                RE2Log.info("udp socket started → ASSOC")
                try await ep.assocClient(deviceID: profile.deviceID, sessionTicket: profile.sessionTicket)
                self.ticketAuthFailures = 0
                if !lan.isEmpty {
                    self.statusText = String(localized: "Connecting LAN…")
                    let ok = await self.preferDirectToLAN(lan)
                    // Only PreferDirect after REHP1 pong. Optimistic latch to a stale QR
                    // lan:port (Agent UDP moved) black-holes Noise on a dead socket and
                    // still burns the relay retry budget — see device logs on :63376.
                    if !ok {
                        RE2Log.info("LAN PreferDirect miss — Noise via relay UDP (QR lan may be stale)")
                    }
                    RE2Log.info("pre-Noise LAN latch ok=\(ep.usingDirect) direct=\(self.directPeerHostPort) → Noise")
                } else {
                    RE2Log.info("udp ASSOC ok (no LAN) → Noise via relay")
                }
                // Never fan-out Noise msg1 to relay+LAN: Agent sees two XX msg1s,
                // completes one handshake then MAC-fails the duplicate → App falls
                // back to WSS (logs: REHP1 ok, then "Noise 会话已建立" without UDP).
                // PreferDirect latched → LAN only; else relay UDP only.
                ep.setNoiseFanout(false)
                do {
                    try await self.runNoiseHandshake(profile: profile, overUDP: true)
                    self.recentUDPNoiseFailures = 0
                    self.skipUDPNoiseUntil = nil
                } catch {
                    // Direct path latched but Agent didn't reply — clear PreferDirect and
                    // retry Noise once on relay UDP before falling back to WSS.
                    if ep.usingDirect {
                        RE2Log.error("Noise via LAN failed (\(error)) — retry once via relay UDP")
                        ep.clearDirect()
                        self.usingP2P = false
                        self.directPeerHostPort = ""
                        self.refreshPathLabel()
                        try await self.runNoiseHandshake(profile: profile, overUDP: true)
                        self.recentUDPNoiseFailures = 0
                        self.skipUDPNoiseUntil = nil
                    } else {
                        throw error
                    }
                }
            }
            group.addTask { @MainActor in
                let budget: UInt64 = lan.isEmpty ? 15_000_000_000 : 22_000_000_000
                try await Task.sleep(nanoseconds: budget)
                RE2Log.error("UDP Noise deadline — aborting endpoint")
                self.endpoint?.close()
                throw RE2Error.udp("UDP Noise deadline")
            }
            do {
                try await group.next()!
                group.cancelAll()
            } catch {
                group.cancelAll()
                endpoint?.close()
                throw error
            }
        }
    }

    /// Fresh BIND when falling back to WSS after a long UDP/LAN attempt.
    private func ensureSignalingForWSS(profile: PairedDesktop) async throws {
        if let sig = signaling, sig.isOpen {
            sig.sendKeepalivePing()
            // Probe with a real write path — ping alone can succeed on a half-dead socket.
            do {
                try await sig.writeFrame(RE2Frame(
                    type: RE2.OuterType.ping,
                    routeID: profile.deviceID,
                    payload: Data()
                ))
                RE2Log.info("WSS fallback — existing signaling still writable")
                return
            } catch {
                RE2Log.info("WSS fallback — signaling write failed (\(error)); re-BIND")
            }
        } else {
            RE2Log.info("WSS fallback — signaling missing/closed; re-BIND")
        }
        _ = try await performBind(profile: profile)
    }

    /// App→Agent REHP1 + PreferDirect (outbound). Does not make Agent PreferDirect back.
    private func preferDirectToLAN(_ lan: [String]) async -> Bool {
        guard let ep = endpoint else { return false }
        _ = await ep.ensureDirectListener()
        let token = UUID().uuidString
        RE2Log.info("LAN PreferDirect probe: \(lan.joined(separator: ","))")
        for peer in lan {
            guard let ok = await RE2HolePunch.tryDirect(peerHostPort: peer, token: token, timeout: 1.2),
                  !ok.isEmpty else { continue }
            do {
                try await ep.preferDirect(hostPort: ok)
                if ep.usingDirect {
                    usingP2P = true
                    directPeerHostPort = ok
                    refreshPathLabel()
                    refreshLanEndpointsDisplay()
                    RE2Log.info("LAN PreferDirect OK → \(ok)")
                    return true
                }
            } catch {
                RE2Log.info("LAN PreferDirect failed \(peer): \(error)")
            }
        }
        RE2Log.info("LAN PreferDirect: no peer answered")
        return false
    }

    /// Menu / manual: move media from WSS relay onto LAN UDP+P2P.
    func retryLANOrP2P() {
        if useWSSTunnel, let profile = paired {
            lanUpgradeAttempted = false
            lanUpgradeTask?.cancel()
            Task { await upgradeMediaToLAN(profile: profile, accessPassword: accessPassword, force: true) }
            return
        }
        startHolePunch()
    }

    /// Wait for stable WSS paints, then REHP1-probe before any UDP Noise upgrade.
    private func scheduleDeferredLANUpgrade(profile: PairedDesktop, accessPassword: String?) {
        lanUpgradeTask?.cancel()
        lanUpgradeTask = Task { [weak self] in
            // Let WSS produce a few frames before we even probe — avoids connect race.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.useWSSTunnel, self.phase == .streaming else { return }
            let lan = profile.lanCandidates.filter { !$0.isEmpty && !$0.hasSuffix(":0") }
            guard !lan.isEmpty else { return }
            // Up to ~30s of REHP1 probes; upgrade only when peer answers.
            for attempt in 0..<6 {
                guard !Task.isCancelled, self.useWSSTunnel, self.phase == .streaming else { return }
                if let until = self.skipUDPNoiseUntil, Date() < until {
                    RE2Log.info("deferred LAN upgrade: UDP cool-down active — stay on WSS")
                    return
                }
                let hit = await self.probeReachableLAN(lan, perPeerTimeout: 0.8)
                if !hit.isEmpty {
                    RE2Log.info("deferred LAN upgrade: REHP1 ok \(hit.joined(separator: ",")) — cut over")
                    await self.upgradeMediaToLAN(profile: profile, accessPassword: accessPassword, force: false)
                    return
                }
                RE2Log.info("deferred LAN upgrade: REHP1 miss #\(attempt) — keep WSS")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            RE2Log.info("deferred LAN upgrade: gave up probes — stay on WSS (use Retry P2P)")
        }
    }

    /// WSS → UDP: pause WSS recv → ASSOC → UDP Noise → OPEN → then PreferDirect.
    /// Never start UDP Noise while WSS receiveLoop is still decrypting (Agent rekeys on msg1).
    private func upgradeMediaToLAN(profile: PairedDesktop, accessPassword: String?, force: Bool) async {
        guard useWSSTunnel, phase == .streaming || phase == .openingDesktop else { return }
        if lanUpgradeAttempted, !force { return }
        lanUpgradeAttempted = true
        let lan = profile.lanCandidates.filter { !$0.isEmpty && !$0.hasSuffix(":0") }
        // Refuse Noise-without-reachability unless user forced Retry P2P.
        if !force, !lan.isEmpty {
            let hit = await probeReachableLAN(lan, perPeerTimeout: 0.9)
            if hit.isEmpty {
                RE2Log.info("LAN upgrade aborted — no REHP1 pong (avoid WSS desync)")
                lanUpgradeAttempted = false
                return
            }
        }
        RE2Log.info("LAN upgrade: pause WSS recv → UDP Noise (lan=\(lan.joined(separator: ",")))…")
        statusText = String(localized: "Switching to LAN…")
        suppressDisconnectHandling = true
        lanPeerAcked = false
        // Stop consuming WSS tunnel BEFORE Agent sees UDP Noise msg1.
        recvTask?.cancel()
        recvTask = nil
        do {
            let ep = try REUDPEndpoint(hostPort: profile.udpHostPort)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await ep.start() }
                group.addTask {
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                    throw RE2Error.udp("UDP connect timeout")
                }
                try await group.next()!
                group.cancelAll()
            }
            try await ep.assocClient(deviceID: profile.deviceID, sessionTicket: profile.sessionTicket)
            endpoint = ep
            _ = await ep.ensureDirectListener()

            // UDP Noise replaces Agent WSS session — switch recv immediately after.
            phase = .openingDesktop
            try await runNoiseHandshakeWithDeadline(profile: profile, overUDP: true, seconds: 12)
            useWSSTunnel = false
            didFallbackVideoToWSS = false
            refreshPathLabel()
            persistMediaPathHint()
            recvTask?.cancel()
            recvTask = Task { [weak self] in await self?.receiveLoop() }

            sessionID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(16))
            var open: [String: Any] = openDesktopParams(sessionID: sessionID, privacyBlank: privacyBlank)
            if let pw = accessPassword ?? self.accessPassword, !pw.isEmpty { open["password"] = pw }
            try await sendInner(RE2.Msg.openDesktop, RE2Codec.jsonData(open), reliable: true)
            videoAssembler = VideoFrameAssembler()
            decoder.reset()
            lastDecodedAt = nil
            requestKeyframe()
            scheduleKeyframeRetry()
            let opened = await waitUntilStreaming(timeout: 30)
            if !opened {
                throw RE2Error.desktopOpenTimeout
            }
            // Wait for at least one UDP paint before PreferDirect (Agent media must be on UDP).
            for _ in 0..<25 {
                if let last = lastDecodedAt, Date().timeIntervalSince(last) < 2 { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            startHolePunch()
            _ = await preferDirectToLAN(lan)
            refreshPathLabel()
            persistMediaPathHint()
            RE2Log.info("LAN upgrade OK path=\(pathLabel) p2p=\(usingP2P)")
            statusText = String(localized: "Connected")
            suppressDisconnectHandling = false
        } catch {
            RE2Log.error("LAN upgrade failed — restoring WSS session: \(error)")
            endpoint?.close()
            endpoint = nil
            usingP2P = false
            directPeerHostPort = ""
            do {
                try await runNoiseHandshakeWithDeadline(profile: profile, overUDP: false, seconds: 12)
                useWSSTunnel = true
                didFallbackVideoToWSS = true
                refreshPathLabel()
                persistMediaPathHint()
                sessionID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(16))
                var open: [String: Any] = openDesktopParams(sessionID: sessionID, privacyBlank: privacyBlank)
                if let pw = accessPassword ?? self.accessPassword, !pw.isEmpty { open["password"] = pw }
                try await sendInner(RE2.Msg.openDesktop, RE2Codec.jsonData(open), reliable: true)
                videoAssembler = VideoFrameAssembler()
                decoder.reset()
                lastDecodedAt = nil
                recvTask?.cancel()
                recvTask = Task { [weak self] in await self?.receiveLoop() }
                requestKeyframe()
                scheduleKeyframeRetry()
                statusText = String(localized: "Connected")
                RE2Log.info("WSS session restored after failed LAN upgrade")
            } catch {
                RE2Log.error("WSS restore after LAN upgrade also failed: \(error)")
                phase = .failed
                statusText = String(localized: "Failed")
                lastError = error.localizedDescription
            }
            suppressDisconnectHandling = false
        }
    }

    private func persistMediaPathHint() {
        guard var p = paired else { return }
        let hint: String
        if usingP2P { hint = "p2p" }
        else if useWSSTunnel { hint = "wss" }
        else { hint = "udp" }
        if p.lastMediaPath != hint {
            p.lastMediaPath = hint
            paired = p
        }
    }

    /// Keep PairedDesktop.lanCandidates fresh from Agent hole-punch replies (QR ports go stale).
    /// Same host IP → replace port (Agent sticky listen can move across restarts).
    private func mergeLanCandidates(_ peers: [String]) {
        let fresh = peers.filter { !$0.isEmpty && !$0.hasSuffix(":0") }
        guard !fresh.isEmpty, var p = paired else { return }
        var byHost: [String: String] = [:]
        for c in p.lanCandidates where !c.isEmpty && !c.hasSuffix(":0") {
            if let h = Self.hostOnly(c) { byHost[h] = c }
        }
        var changed = false
        for f in fresh {
            guard let h = Self.hostOnly(f) else { continue }
            if byHost[h] != f {
                if let old = byHost[h], old != f {
                    RE2Log.info("LAN port changed \(old) → \(f)")
                }
                byHost[h] = f
                changed = true
            }
        }
        guard changed else {
            refreshLanEndpointsDisplay()
            return
        }
        p.lanCandidates = byHost.values.sorted()
        paired = p
        refreshLanEndpointsDisplay()
        // HostListView persists on pathLabel / lanEndpointsDisplay change.
        refreshPathLabel()
    }

    /// Host-list subtitle: live PreferDirect peer first, then advertised LAN candidates.
    private func refreshLanEndpointsDisplay() {
        var parts: [String] = []
        if !directPeerHostPort.isEmpty {
            parts.append(directPeerHostPort)
        }
        for c in paired?.lanCandidates ?? [] {
            guard !c.isEmpty, !c.hasSuffix(":0"), !parts.contains(c) else { continue }
            parts.append(c)
        }
        let next = parts.joined(separator: " · ")
        if lanEndpointsDisplay != next {
            lanEndpointsDisplay = next
        }
    }

    /// Noise with a hard wall-clock deadline — never leave UI on Encrypting….
    private func runNoiseHandshakeWithDeadline(
        profile: PairedDesktop,
        overUDP: Bool,
        seconds: TimeInterval
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await self.runNoiseHandshake(profile: profile, overUDP: overUDP)
            }
            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                RE2Log.error("Noise deadline (\(Int(seconds))s) via=\(overUDP ? "udp" : "wss") — abort")
                if overUDP {
                    self.endpoint?.close()
                } else {
                    // Unblock frame waiters without tearing down BIND for optional retry paths.
                    self.signaling?.failPendingReads(RE2Error.noise("handshake timeout"))
                }
                throw RE2Error.noise("handshake timeout")
            }
            do {
                try await group.next()!
                group.cancelAll()
            } catch {
                group.cancelAll()
                if overUDP { endpoint?.close() }
                else { signaling?.failPendingReads(error) }
                throw error
            }
        }
    }

    /// Noise_XXpsk3 over REUDP or WSS signaling frames.
    private func runNoiseHandshake(profile: PairedDesktop, overUDP: Bool) async throws {
        phase = .handshaking
        statusText = overUDP
            ? String(localized: "Encrypting…")
            : String(localized: "Encrypting via relay…")
        do {
            let psk = RE2.derivePSK(pairingToken: profile.pairingToken)
            let hs = try NoiseXXPSK3(psk: psk)
            let msg1 = try hs.writeMessage1()
            RE2Log.info("Noise msg1 len=\(msg1.count) via=\(overUDP ? "udp" : "wss") token=\(profile.pairingToken.prefix(8))…")

            var msg2: Data?
            if overUDP {
                guard let ep = endpoint else { throw RE2Error.udp("no endpoint") }
                RE2Log.info("Noise udp send msg1…")
                // Unreliable + retransmit: PreferDirect reliable ACK often never
                // completes (Agent never sees msg1 → forced WSS after ~16s).
                try await ep.sendLatest(msg1)
                RE2Log.info("Noise udp msg1 sent, waiting msg2 (retransmit)")
                // Retransmit msg1 while waiting — volunteer/LAN UDP often drops the first.
                msg2 = try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask {
                        for _ in 0..<30 {
                            try Task.checkCancellation()
                            // Agent msg2 is e(32) + enc s(48) + empty payload tag(16) = 96 bytes.
                            // The Agent keeps streaming the previous session until XX completes,
                            // and readMessage2 cannot be retried after a wrong packet, so any
                            // other size (small video tail / NACK / cursor) must be skipped.
                            if let b = try? await ep.recv(timeout: 0.4), b.count == 96 {
                                return b
                            }
                        }
                        throw RE2Error.noise("no handshake reply")
                    }
                    group.addTask {
                        for i in 0..<16 {
                            try Task.checkCancellation()
                            try await Task.sleep(nanoseconds: 350_000_000)
                            try? await ep.sendLatest(msg1)
                            if i == 0 || i == 5 || i == 10 {
                                RE2Log.info("Noise udp msg1 retransmit #\(i) direct=\(ep.usingDirect)")
                            }
                        }
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        throw RE2Error.noise("no handshake reply")
                    }
                    do {
                        let got = try await group.next()!
                        group.cancelAll()
                        return got
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                }
                RE2Log.info("Noise udp msg2 len=\(msg2?.count ?? 0)")
            } else {
                guard let sig = signaling else { throw RE2Error.signaling("no signaling") }
                RE2Log.info("Noise wss send msg1…")
                try await sig.writeFrame(RE2Frame(type: RE2.OuterType.noise, routeID: deviceID, payload: msg1))
                RE2Log.info("Noise wss msg1 sent, waiting msg2")
                for attempt in 0..<8 {
                    try Task.checkCancellation()
                    let f = try await sig.readFrame(timeout: 3)
                    if f.type == RE2.OuterType.ping {
                        try? await sig.writeFrame(RE2Frame(type: RE2.OuterType.pong, routeID: f.routeID, payload: f.payload))
                        continue
                    }
                    if f.type == RE2.OuterType.pong {
                        continue
                    }
                    if f.type == RE2.OuterType.error {
                        throw annotated(Self.mapErrorPayload(f.payload))
                    }
                    if f.type == RE2.OuterType.noise {
                        RE2Log.info("Noise wss msg2 len=\(f.payload.count) attempt=\(attempt)")
                        msg2 = f.payload
                        break
                    }
                    // Drop stale tunnel from a previous session — never treat as msg2.
                    if f.type == RE2.OuterType.tunnel {
                        RE2Log.info("Noise wss drop stale tunnel during handshake")
                        continue
                    }
                    RE2Log.info("Noise wss skip frame type=0x\(String(f.type, radix: 16))")
                }
            }
            guard let msg2 else { throw RE2Error.noise("no handshake reply") }
            try hs.readMessage2(msg2)
            let (msg3, send, recv) = try hs.writeMessage3()
            RE2Log.info("Noise msg3 len=\(msg3.count) via=\(overUDP ? "udp" : "wss")")
            if overUDP {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.endpoint?.sendLatest(msg3) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        throw RE2Error.udp("msg3 send timeout")
                    }
                    do {
                        try await group.next()!
                        group.cancelAll()
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                }
                // Do NOT retransmit msg3: Agent already finished XX on the first copy;
                // a second msg3 decrypts as tunnel → chacha20 MAC fail (nonce stays).
            } else {
                try await signaling?.writeFrame(RE2Frame(type: RE2.OuterType.noise, routeID: deviceID, payload: msg3))
            }
            sendCipher = send
            recvCipher = recv
            videoMedia = nil
            videoPlaneActive = false
            if overUDP {
                // Agent keeps one udpEP across rescans; both sides must start seq at 0
                // or OPEN (reliable) is buffered forever → "正在打开桌面".
                endpoint?.resetReliableSession()
                // Derive gap-tolerant video keys (must match Agent DeriveVideoMediaKeys).
                if let peer = hs.peerStaticPublicKey {
                    do {
                        let keys = try RE2VideoMedia.deriveKeys(
                            psk: psk,
                            initiatorStatic: hs.localStaticPublicKey,
                            responderStatic: peer
                        )
                        videoMedia = try RE2VideoMedia(a2c: keys.a2c, c2a: keys.c2a)
                        RE2Log.info("video_plane keys ready")
                    } catch {
                        RE2Log.error("video_plane key derive failed: \(error)")
                        videoMedia = nil
                    }
                }
            } else {
                // Drop in-flight tunnels still encrypted under the previous CipherState.
                await drainStaleWSSTunnels(seconds: 1.0)
            }

            if let pin = pinnedNoisePub, let peer = hs.peerStaticPublicKey, pin != peer {
                autoReconnect = false
                throw annotated(RE2Error.pinMismatch)
            }
            RE2Log.info("Noise handshake OK via=\(overUDP ? "udp" : "wss") videoMedia=\(videoMedia != nil)")
        } catch {
            RE2Log.error("Noise handshake FAIL via=\(overUDP ? "udp" : "wss"): \(error)")
            if let e = error as? RE2Error, case .pinMismatch = e {
                autoReconnect = false
                throw e
            }
            let classified = classifyNoiseFailure(error)
            if classified.stopsAutoReconnect { autoReconnect = false }
            throw annotated(classified)
        }
    }

    /// After re-Noise on WSS, discard tunnel frames from the prior session (wrong keys).
    private func drainStaleWSSTunnels(seconds: TimeInterval) async {
        guard let sig = signaling else { return }
        let deadline = Date().addingTimeInterval(seconds)
        var dropped = 0
        while Date() < deadline {
            do {
                let f = try await sig.readFrame(timeout: 0.12)
                if f.type == RE2.OuterType.ping {
                    try? await sig.writeFrame(RE2Frame(type: RE2.OuterType.pong, routeID: f.routeID, payload: f.payload))
                    continue
                }
                if f.type == RE2.OuterType.pong { continue }
                if f.type == RE2.OuterType.tunnel {
                    dropped += 1
                    continue
                }
                // Anything else — stop draining; caller may need it.
                break
            } catch {
                break
            }
        }
        if dropped > 0 {
            RE2Log.info("drained \(dropped) stale WSS tunnel frame(s) after Noise")
        }
    }

    /// Wait until phase becomes streaming/failed or timeout.
    private func waitUntilStreaming(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Initial OPEN succeeded once DESKTOP_READY landed (hadActiveDesktop).
            // A concurrent maybeReopenForNativeQuality / ABR quality OPEN may flip
            // phase back to openingDesktop within the 200ms poll window — that must
            // not make the *first* waitUntilStreaming time out (UDP·Relay E2E).
            if phase == .streaming || hadActiveDesktop { return true }
            if phase == .failed { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return phase == .streaming || hadActiveDesktop
    }

    /// Map Noise failures: pin/PSK rotate → needsRescan; timeouts/short/no-reply → retryable.
    private func classifyNoiseFailure(_ error: Error) -> RE2Error {
        if error is CancellationError {
            return .cancelled
        }
        if let e = error as? RE2Error {
            switch e {
            case .pinMismatch, .needsRescan, .cancelled:
                return e
            case .noise(let m):
                let lower = m.lowercased()
                if Self.isTransientNoiseMessage(lower) {
                    return e
                }
                if Self.isCryptoAuthFailureMessage(lower) {
                    return .needsRescan
                }
                // Ambiguous Noise errors stay retryable (flaky network).
                return e
            default:
                return e
            }
        }
        let blob = "\(error) \(error.localizedDescription)".lowercased()
        if blob.contains("cancellationerror") || blob.contains("cancelled") {
            return .cancelled
        }
        if Self.isCryptoAuthFailureMessage(blob) {
            return .needsRescan
        }
        return .noise(error.localizedDescription)
    }

    private static func isTransientNoiseMessage(_ m: String) -> Bool {
        m.contains("no handshake")
            || m.contains("timeout")
            || m.contains("short")
            || m.contains("msg2 short")
            || m.contains("cancelled")
            || m.contains("network")
            || m.contains("timed out")
    }

    private static func isCryptoAuthFailureMessage(_ m: String) -> Bool {
        m.contains("authentication")
            || m.contains("auth fail")
            || m.contains("tag") && m.contains("fail")
            || m.contains("decrypt")
            || m.contains("bad remote static")
            || m.contains("ciphertext short")
            || m.contains("cryptokit")
            || m.contains("chachapoly")
    }

    private func classifyAssocFailure(_ error: Error) -> RE2Error {
        if let e = error as? RE2Error {
            switch e {
            case .udp(let m):
                let lower = m.lowercased()
                if lower.contains("reject") || lower.contains("auth") || lower.contains("ticket") || lower.contains("denied") {
                    return .ticketRejected
                }
                if lower.contains("timeout") {
                    return e // retryable
                }
                return e
            case .ticketRejected, .relayRestarted, .peerTaken:
                return e
            default:
                return e
            }
        }
        return .udp(error.localizedDescription)
    }

    /// After repeated ticket rejects, treat as relay restart (in-memory tickets wiped).
    private func escalateTicketFailure(_ error: RE2Error) -> RE2Error {
        switch error {
        case .ticketRejected, .relayRestarted:
            ticketAuthFailures += 1
            if ticketAuthFailures >= 2 {
                autoReconnect = false
                return .relayRestarted
            }
            return .ticketRejected
        case .peerTaken, .controllerBusy, .needsRescan, .pinMismatch, .expired:
            if error.stopsAutoReconnect { autoReconnect = false }
            return error
        default:
            let mapped = RE2Error.fromRelayError(code: "", message: error.localizedDescription ?? "")
            if case .ticketRejected = mapped {
                return escalateTicketFailure(.ticketRejected)
            }
            if case .peerTaken = mapped {
                autoReconnect = false
                return .peerTaken
            }
            return error
        }
    }

    private func receiveLoop() async {
        if useWSSTunnel {
            await receiveLoopWSS()
            return
        }
        // Single media plane: UDP Noise ⇒ video/control on UDP (Agent PreferDirect
        // carries LAN). WSS stays signaling-only (ping) — do not decrypt tunnel on
        // WSS or we reintroduce the dual-plane freeze/WSS-HUD mess.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await self.signalingKeepaliveLoop()
            }
            // Recv must NOT sit on MainActor — file-wait evidence showed ctrl=
            // backlog growing with waiters=0 while video decode / E2E held the actor.
            group.addTask {
                await self.receiveLoopUDPOffMain()
            }
            await group.next()
            group.cancelAll()
            for await _ in group {}
        }
    }

    /// BIND WebSocket alive while media is on UDP — ping/pong only, no tunnel decrypt.
    private func signalingKeepaliveLoop() async {
        guard let signaling else { return }
        RE2Log.info("WSS signaling keepalive (UDP media primary)")
        while !Task.isCancelled {
            if useWSSTunnel { return }
            do {
                let f = try await signaling.readFrame(timeout: 30)
                if f.type == RE2.OuterType.ping {
                    try? await signaling.writeFrame(RE2Frame(type: RE2.OuterType.pong, routeID: f.routeID, payload: f.payload))
                }
                if f.type == RE2.OuterType.error, case .peerTaken = Self.mapErrorPayload(f.payload) {
                    RE2Log.info("relay: another device took over — stop UDP session")
                    await handleDisconnect(annotated(RE2Error.peerTaken))
                    return
                }
                // Ignore other tunnel/error frames on signaling while UDP owns the media plane.
            } catch {
                if Task.isCancelled || useWSSTunnel { return }
                let msg = (error as? RE2Error)?.localizedDescription.lowercased() ?? error.localizedDescription.lowercased()
                if msg.contains("timeout") || msg.contains("cancelled") { continue }
                RE2Log.info("WSS signaling ended while UDP media: \(error)")
                return
            }
        }
    }

    /// UDP read off the main actor. Decrypt stays ordered on MainActor; handleInner
    /// is enqueued so a stuck pong/fileAck send cannot freeze Noise ingress
    /// (file-wait: ctrl backlog with waiters=0 while recv loop was inside handleInner).
    nonisolated private func receiveLoopUDPOffMain() async {
        while !Task.isCancelled {
            let endpoint = await MainActor.run { self.endpoint }
            guard let endpoint else { return }
            do {
                let ct = try await endpoint.recv(timeout: 30)
                await self.decryptUDPCiphertext(ct)
            } catch {
                if Task.isCancelled { return }
                let msg = (error as? RE2Error)?.localizedDescription.lowercased()
                    ?? error.localizedDescription.lowercased()
                if msg.contains("timeout") || msg.contains("cancelled") {
                    continue
                }
                let stay = await MainActor.run { self.usingP2P || (self.endpoint?.usingDirect ?? false) }
                if stay {
                    RE2Log.info("UDP recv error while P2P/direct — ignore: \(error)")
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                await self.handleDisconnect(error)
                return
            }
        }
    }

    private var pendingInners: [(UInt8, Data)] = []
    private var drainingInners = false

    /// Decrypt/decode only — never await sendInner here.
    private func decryptUDPCiphertext(_ ct: Data) async {
        let fileBusy = fileListWaiter != nil || !uploadAcks.isEmpty
        let plain: Data
        if RE2VideoMedia.isVideoPlane(ct) {
            if fileBusy { return }
            if let vm = videoMedia, let opened = try? vm.open(packet: ct) {
                plain = opened
            } else {
                guard let cipher = recvCipher else { return }
                do {
                    plain = try cipher.decrypt(ciphertext: ct)
                } catch {
                    if fileBusy {
                        RE2Log.error("UDP Noise decrypt failed (file-wait): \(error) ct=\(ct.count)")
                    } else if Int.random(in: 0..<40) == 0 {
                        RE2Log.error("UDP Noise decrypt failed: \(error) ct=\(ct.count)")
                    }
                    return
                }
            }
        } else {
            guard let cipher = recvCipher else { return }
            do {
                plain = try cipher.decrypt(ciphertext: ct)
            } catch {
                if fileBusy {
                    RE2Log.error("UDP Noise decrypt failed (file-wait): \(error) ct=\(ct.count)")
                } else if Int.random(in: 0..<20) == 0 {
                    RE2Log.error("UDP Noise decrypt failed: \(error) ct=\(ct.count)")
                }
                return
            }
        }
        do {
            let (mt, body) = try RE2Codec.decodeInner(plain)
            pendingInners.append((mt, body))
            pumpPendingInners()
        } catch {
            RE2Log.error("UDP inner decode failed: \(error)")
        }
    }

    private func pumpPendingInners() {
        guard !drainingInners else { return }
        drainingInners = true
        Task { @MainActor in
            while !self.pendingInners.isEmpty {
                let (mt, body) = self.pendingInners.removeFirst()
                await self.handleInner(mt, body)
            }
            self.drainingInners = false
            if !self.pendingInners.isEmpty {
                self.pumpPendingInners()
            }
        }
    }

    private func processUDPCiphertext(_ ct: Data) async {
        await decryptUDPCiphertext(ct)
    }

    private func receiveLoopUDP() async {
        // Legacy path kept for reference; PreferDirect uses receiveLoopUDPOffMain.
        guard let endpoint else { return }
        while !Task.isCancelled {
            do {
                let ct = try await endpoint.recv(timeout: 30)
                await processUDPCiphertext(ct)
            } catch {
                if Task.isCancelled { return }
                let msg = (error as? RE2Error)?.localizedDescription.lowercased() ?? error.localizedDescription.lowercased()
                if msg.contains("timeout") || msg.contains("cancelled") {
                    continue
                }
                if usingP2P || endpoint.usingDirect {
                    RE2Log.info("UDP recv error while P2P/direct — ignore: \(error)")
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                await handleDisconnect(error)
                return
            }
        }
    }

    private func receiveLoopWSS() async {
        guard let signaling else { return }
        while !Task.isCancelled {
            do {
                let f = try await signaling.readFrame(timeout: 30)
                if f.type == RE2.OuterType.ping {
                    try? await signaling.writeFrame(RE2Frame(type: RE2.OuterType.pong, routeID: f.routeID, payload: f.payload))
                    continue
                }
                if f.type == RE2.OuterType.error {
                    await handleDisconnect(Self.mapErrorPayload(f.payload))
                    return
                }
                guard f.type == RE2.OuterType.tunnel else { continue }
                guard let recvCipher else { continue }
                let plain: Data
                do {
                    plain = try recvCipher.decrypt(ciphertext: f.payload)
                    wssDecryptFailures = 0
                } catch {
                    wssDecryptFailures += 1
                    // Dual ciphertext (stale Agent pump + new session) looks like intermittent
                    // decrypt fail. Keyframe floods and re-OPEN loops make it worse.
                    if wssDecryptFailures == 1 || wssDecryptFailures == 20 || wssDecryptFailures == 50 {
                        RE2Log.error("WSS tunnel decrypt failed #\(wssDecryptFailures) (drop; no keyframe flood)")
                    }
                    // Sustained fail = CipherState dead (Agent idle-timeout / rekey). Soft
                    // keyframe cannot fix — need a fresh WSS Noise session.
                    if wssDecryptFailures == 50 {
                        Task { await self.recoverWSSNoiseSession() }
                    }
                    continue
                }
                let (mt, body) = try RE2Codec.decodeInner(plain)
                await handleInner(mt, body)
            } catch {
                if Task.isCancelled { return }
                // Idle gaps / timeout must NOT tear down the session — that freezes
                // the last decoded frame on screen forever.
                let msg = (error as? RE2Error)?.localizedDescription.lowercased() ?? error.localizedDescription.lowercased()
                if msg.contains("timeout") || msg.contains("cancelled") {
                    RE2Log.info("WSS recv idle/timeout — keep listening")
                    continue
                }
                await handleDisconnect(error)
                return
            }
        }
    }

    /// Re-OPEN on WSS with hard-capped size after "kbps>0 but no decode" stall.
    private func reopenDesktopRelaySafe() async {
        guard useWSSTunnel, !isRecoveringWSS, phase == .streaming || phase == .openingDesktop else { return }
        isRecoveringWSS = true
        defer { isRecoveringWSS = false }
        recvWithoutDecodeWindows = 0
        RE2Log.error("WSS relay-safe reopen — traffic without decode (torn multi-part frames)")
        statusText = String(localized: "Reconnecting video…")
        wssDecryptFailures = 0
        let oldSID = sessionID
        try? await sendInner(RE2.Msg.desktopClose, RE2Codec.jsonData([
            "session_id": oldSID, "reason": "relay_safe_reopen"
        ]), reliable: true)
        videoAssembler = VideoFrameAssembler()
        decoder.reset()
        lastDecodedAt = nil
        sessionID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(16))
        var open: [String: Any] = [
            "session_id": sessionID,
            "max_width": 854,
            "max_height": 480,
            "fps": 12,
            "bitrate_kbps": 900,
            "codec": "h264",
            "hide_cursor": true,
            "privacy_blank": privacyBlank
        ]
        open["display_id"] = desiredDisplayID
        if let pw = accessPassword, !pw.isEmpty { open["password"] = pw }
        phase = .openingDesktop
        try? await sendInner(RE2.Msg.openDesktop, RE2Codec.jsonData(open), reliable: true)
        requestKeyframe()
        scheduleKeyframeRetry()
    }

    /// WSS decrypt dead / Agent session_idle_timeout: re-handshake Noise on the same
    /// signaling socket, drain stale tunnels, then tiny OPEN. Keeps last CGImage.
    private func recoverWSSNoiseSession() async {
        guard useWSSTunnel, !isRecoveringWSS else { return }
        // Quality / privacy reopen already re-OPENs; a concurrent Noise recover
        // races to handshaking and freezes the previous picture size.
        guard !qualityChangeAwaitingPaint else {
            RE2Log.info("WSS Noise recover skipped — quality change in flight")
            return
        }
        guard let profile = paired else { return }
        if let last = lastWSSNoiseRecoverAt, Date().timeIntervalSince(last) < 25 { return }
        guard wssNoiseRecoverCount < 2 else {
            RE2Log.error("WSS Noise recover budget exhausted — stay frozen (reconnect manually)")
            return
        }
        isRecoveringWSS = true
        defer { isRecoveringWSS = false }
        wssNoiseRecoverCount += 1
        lastWSSNoiseRecoverAt = Date()
        RE2Log.error("WSS Noise desync — full WSS re-handshake #\(wssNoiseRecoverCount)")
        statusText = String(localized: "Reconnecting…")

        recvTask?.cancel()
        recvTask = nil
        sendCipher = nil
        recvCipher = nil
        videoMedia = nil
        videoPlaneActive = false
        wssDecryptFailures = 0
        videoAssembler = VideoFrameAssembler()
        decoder.reset()
        // Keep frameImage so UI does not flash black.

        do {
            await drainStaleWSSTunnels(seconds: 1.0)
            try await runNoiseHandshakeWithDeadline(profile: profile, overUDP: false, seconds: 12)
            useWSSTunnel = true
            refreshPathLabel()
            recvTask = Task { [weak self] in await self?.receiveLoop() }

            let oldSID = sessionID
            try? await sendInner(RE2.Msg.desktopClose, RE2Codec.jsonData([
                "session_id": oldSID, "reason": "wss_noise_recover"
            ]), reliable: true)
            sessionID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(16))
            var open: [String: Any] = [
                "session_id": sessionID,
                "max_width": 640,
                "max_height": 360,
                "fps": 10,
                "bitrate_kbps": 600,
                "codec": "h264",
                "hide_cursor": true,
                "privacy_blank": privacyBlank
            ]
            open["display_id"] = desiredDisplayID
            if let pw = accessPassword, !pw.isEmpty { open["password"] = pw }
            phase = .openingDesktop
            try await sendInner(RE2.Msg.openDesktop, RE2Codec.jsonData(open), reliable: true)
            lastDecodedAt = nil
            requestKeyframe(force: true)
            scheduleKeyframeRetry()
            RE2Log.info("WSS Noise recover OPEN sent session=\(sessionID)")
        } catch {
            RE2Log.error("WSS Noise recover failed: \(error)")
            lastError = error.localizedDescription
            statusText = String(localized: "Connected — video stalled")
        }
    }

    private func keepaliveLoop() async {
        var idleTicks = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // Keep pings alive through quality/privacy reopen (openingDesktop) —
            // dropping them mid-switch let WSS go idle / peer_gone before READY.
            guard phase == .streaming || phase == .openingDesktop else {
                // The Agent releases a peer that stays silent for minutes; a live
                // tunnel without a desktop (chat / PTY only) must still check in.
                idleTicks += 1
                if hasLiveTunnel, idleTicks % 10 == 0 {
                    try? await sendInner(RE2.Msg.ping, Data(), reliable: true)
                }
                continue
            }
            // Inner ping for RTT
            stats.notePingSent()
            try? await sendInner(RE2.Msg.ping, RE2Codec.jsonData(["session_id": sessionID, "t": Date().timeIntervalSince1970]), reliable: true)
            let stalled: Bool = {
                if frameImage == nil { return true }
                // Quality reopen keeps the previous CGImage (clearFrame: false). That
                // aged timestamp must NOT count as a "freeze wipe" — WSS 80-part IDRs
                // were reset mid-assembly every ~3s and never painted (用户：切几次画质就冻住).
                if qualityChangeAwaitingPaint {
                    if videoAssembler.assemblingLargeFrame { return false }
                    if let since = qualityChangeStartedAt,
                       let t = lastDecodedAt, t >= since {
                        return Date().timeIntervalSince(t) > 1.5
                    }
                    // Still waiting for the first decode of the new rung.
                    return Date().timeIntervalSince(qualityChangeStartedAt ?? .distantPast) > 5
                }
                if let last = lastDecodedAt, Date().timeIntervalSince(last) > 1.5 {
                    // A static desktop is not a frozen transport: SCK may emit
                    // no frames for minutes, while Agent's cursor heartbeat
                    // proves the authenticated session and input path are live.
                    let cursorAlive = lastCursorHeartbeatAt.map {
                        Date().timeIntervalSince($0) < 1.5
                    } ?? false
                    return !cursorAlive
                }
                return false
            }()
            if videoPlaneActive, !useWSSTunnel,
               let repair = videoAssembler.videoRepairRequest() {
                let missing = repair.missing.map(Int.init)
                stats.noteIncompleteVideoParts(
                    missing: missing.count,
                    expected: Int(repair.expected)
                )
                RE2Log.info("video NACK frame=\(repair.frameID) missing=\(missing.count)")
                try? await sendInner(RE2.Msg.videoNACK, RE2Codec.jsonData([
                    "session_id": sessionID,
                    "frame_id": Int(repair.frameID),
                    "missing": missing,
                ]), reliable: true)
            } else if videoPlaneActive, !useWSSTunnel,
                      videoAssembler.progressLabel.hasPrefix("hold=") {
                RE2Log.info("video repair pending without request \(videoAssembler.progressLabel)")
            }
            let snap = stats.snapshot(sessionID: sessionID, stalled: stalled)
            // Until the first paint, keep telling the agent we need IDRs (and report loss so ABR shrinks).
            var statsBody = snap
            // Only pull IDRs when we have no picture or the picture is frozen —
            // constant want_keyframe on WSS thrashs the encoder and tears multi-part frames.
            // Stall concealment: keep last frameImage (never nil it here).
            if stalled {
                let assemblingFat = videoAssembler.assemblingLargeFrame
                let allowAsk = !assemblingFat &&
                    (lastKeyframeAskAt.map { Date().timeIntervalSince($0) > 3 } ?? true)
                if allowAsk {
                    statsBody["want_keyframe"] = true
                }
                statsBody["stall"] = true
                if frameImage == nil, !assemblingFat {
                    statsBody["loss_pct"] = max(snap["loss_pct"] as? Double ?? 0, 40)
                }
            }
            // Always report measured transport health. Quality-dependent RTT/loss
            // shaping made the client resolution loop and Agent bitrate ABR fight:
            // healthy UDP was forced "good" while smooth/WSS was forced "bad".
            try? await sendInner(RE2.Msg.stats, RE2Codec.jsonData(statsBody), reliable: true)
            let kbpsNow = snap["recv_kbps"] as? Int ?? 0
            let streamFPS = snap["stream_fps"] as? Double ?? 0
            let paintFPS = snap["decode_fps"] as? Double ?? 0
            if stalled {
                // kbps=0 + aged ⇒ CipherState/Agent session dead. Soft keyframe is useless
                // (Agent audit shows session_idle_timeout; input also fails). Re-handshake.
                // Never re-Noise mid quality/privacy OPEN — that left phase=handshaking with
                // the previous CGImage and E2E "smooth failed to repaint".
                if useWSSTunnel, !qualityChangeAwaitingPaint, kbpsNow < 20, frameImage != nil,
                   let last = lastDecodedAt, Date().timeIntervalSince(last) > 6 {
                    Task { await self.recoverWSSNoiseSession() }
                } else {
                    let quiet = lastKeyframeAskAt.map { Date().timeIntervalSince($0) > 3 } ?? true
                    if quiet {
                        // Never wipe an in-flight multi-part IDR — that is exactly how
                        // WSS quality switches froze (assembler reset → endless IDR storm).
                        if videoAssembler.assemblingLargeFrame {
                            RE2Log.info("frozen picture — wait multipart \(videoAssembler.progressLabel) (kbps=\(kbpsNow))")
                        } else if !qualityChangeAwaitingPaint {
                            // For ~12s after a quality OPEN, never wipe the assembler —
                            // mid-IDR resets were freezing decode at 0fps after the first paint.
                            let recentQuality = qualityChangeStartedAt.map {
                                Date().timeIntervalSince($0) < 12
                            } ?? false
                            if recentQuality {
                                RE2Log.info("post-quality soft keyframe (no assembler wipe) kbps=\(kbpsNow)")
                                requestKeyframe(force: true)
                            } else {
                                RE2Log.info("frozen picture — soft keyframe (kbps=\(kbpsNow) streamFPS=\(String(format: "%.1f", streamFPS)) paintFPS=\(String(format: "%.1f", paintFPS)) painted=\(frameImage != nil))")
                                videoAssembler = VideoFrameAssembler()
                                if frameImage == nil { decoder.reset() }
                                requestKeyframe()
                            }
                        } else {
                            RE2Log.info("quality change waiting paint — soft keyframe only (kbps=\(kbpsNow))")
                            requestKeyframe(force: true)
                        }
                    }
                }
                if frameImage == nil {
                    statsBody["want_keyframe"] = true
                    statsBody["loss_pct"] = max(snap["loss_pct"] as? Double ?? 0, 35)
                    try? await sendInner(RE2.Msg.stats, RE2Codec.jsonData(statsBody), reliable: true)
                }
                if kbpsNow > 50 {
                    recvWithoutDecodeWindows += 1
                } else {
                    recvWithoutDecodeWindows = 0
                }
            } else {
                recvWithoutDecodeWindows = 0
                // Do not invent a decode timestamp while a quality reopen is in flight —
                // that made stalled logic think paint already landed on the new rung.
                if frameImage != nil, lastDecodedAt == nil, !qualityChangeAwaitingPaint {
                    lastDecodedAt = Date()
                }
            }
            let rtt = snap["rtt_ms"] as? Int ?? 0
            let loss = snap["loss_pct"] as? Double ?? 0
            // Display as kilobytes/s (网速), not kilobits/s.
            let kbPerSec = max(0, kbpsNow / 8)
            statsKbPerSec = kbPerSec
            // Stall = paint/decode gap, NOT proof of a bad network (LAN first-frame /
            // keyframe gaps used to flash「网络较差」). PreferDirect LAN skips soft
            // RTT/jitter banners — multipart bursts look like "jitter" on a healthy link.
            let paintHealthy = paintFPS >= 8 && kbpsNow >= 200
            let onPrivateLAN = !useWSSTunnel
                && (usingP2P || endpoint?.usingDirect == true)
                && !directPeerHostPort.isEmpty
                && Self.isPrivateHostPort(directPeerHostPort)
            maybeStepQualityDownFromStats(
                loss: loss,
                stalled: stalled,
                recvKbps: kbpsNow,
                paintFPS: paintFPS
            )
            if stalled {
                weakHintBadStreak = 0
                weakHintGoodStreak = 0
                weakNetHint = frameImage == nil
                    ? String(localized: "Waiting for picture…")
                    : String(localized: "Picture stalled")
            } else if onPrivateLAN {
                weakHintBadStreak = 0
                weakHintGoodStreak = 0
                weakNetHint = ""
            } else {
                // RTT is interaction latency, not bandwidth. Jitter here follows
                // dirty-frame cadence and can be high on a healthy static desktop.
                // Require sustained packet loss plus unhealthy paint before warning.
                let deliveryPoor = loss >= 12 && !paintHealthy
                if deliveryPoor {
                    weakHintBadStreak += 1
                    weakHintGoodStreak = 0
                } else {
                    weakHintBadStreak = max(0, weakHintBadStreak - 2)
                    weakHintGoodStreak += 1
                }
                if weakHintBadStreak >= 6 {
                    let actuallyLowered = abrLastStepAt.map {
                        Date().timeIntervalSince($0) < 20
                    } ?? false
                    weakNetHint = actuallyLowered
                        ? String(localized: "Weak network · lowered quality")
                        : String(localized: "Weak network")
                } else if weakHintGoodStreak >= 3
                            || weakNetHint == String(localized: "Picture stalled")
                            || weakNetHint == String(localized: "Waiting for picture…") {
                    weakNetHint = ""
                }
            }
            refreshPathLabel()
            let path = pathLabel.isEmpty ? "—" : pathLabel
            // Keep a verbose line for debug overlays / E2E; nav uses navStatusLine.
            statsLine = String(
                format: String(localized: "%@ · %lld ms · %.1f%% · %lld kb/s · %.0ffps · %@"),
                path,
                Int64(rtt),
                loss,
                Int64(kbPerSec),
                streamFPS,
                videoQuality.title
            )
            // WSS keepalive
            try? await signaling?.writeFrame(RE2Frame(type: RE2.OuterType.ping, routeID: deviceID, payload: Data()))
        }
    }

    private func handleDisconnect(_ error: Error) async {
        RE2Log.error("transport disconnected phase=\(phase.rawValue) path=\(pathLabel): \(error)")
        if suppressDisconnectHandling {
            RE2Log.info("suppress disconnect during WSS video fallback: \(error)")
            return
        }
        // Network drop / background suspend is owned by path monitor / scenePhase.
        if awaitingNetworkRestore || suspendedForBackground || backgroundGraceTask != nil {
            // A drop while away is iOS / the network, not another client taking over:
            // keep autoReconnect so foreground rebuilds it.
            RE2Log.info("disconnect while suspended (network/background): \(error)")
            phase = .failed
            statusText = suspendedForBackground || backgroundGraceTask != nil
                ? String(localized: "Background")
                : String(localized: "Network unavailable…")
            return
        }
        if networkReconnectInFlight {
            RE2Log.info("disconnect during network reconnect (ignored): \(error)")
            return
        }
        let droppedWhileActive = hadActiveDesktop || phase == .streaming || phase == .openingDesktop
        phase = .failed
        lastError = error.localizedDescription
        statusText = String(localized: "Disconnected")
        audio.stop()

        if let e = error as? RE2Error, e.stopsAutoReconnect {
            autoReconnect = false
            recoveryHint = e.recoveryHint
            return
        }

        // Unexplained drop after an active desktop: pause auto BIND to avoid stealing
        // from another client that may have taken over without a kicked frame.
        if droppedWhileActive, autoReconnect {
            autoReconnect = false
            lastError = String(localized: "Connection lost")
            recoveryHint = String(localized: "Another client may be connected. Close it there, then tap Reconnect.")
            return
        }

        guard autoReconnect, let paired, paired.canReconnect else { return }
        reconnectAttempts += 1
        if reconnectAttempts > 8 {
            autoReconnect = false
            recoveryHint = String(localized: "Reconnect failed repeatedly. Re-scan the Agent QR if the host refreshed pairing.")
            return
        }
        // Hard backoff on early retries (avoid BIND thrash).
        let delay = min(12.0, 1.5 * pow(2.0, Double(min(reconnectAttempts - 1, 3))))
        statusText = String(format: String(localized: "Reconnecting in %.0fs…"), delay)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard autoReconnect else { return }
        do {
            try await reconnect(profile: paired, accessPassword: accessPassword)
        } catch {
            lastError = error.localizedDescription
            if let e = error as? RE2Error {
                recoveryHint = e.recoveryHint
                if e.stopsAutoReconnect { autoReconnect = false }
            }
        }
    }

    private func handleInner(_ mt: UInt8, _ body: Data) async {
        lastInboundAt = Date()
        switch mt {
        case RE2.Msg.desktopReady:
            let obj = RE2Codec.jsonObject(body)
            // Ignore stale READY from a previous OPEN (display/quality switch race).
            if let sid = obj["session_id"] as? String, !sid.isEmpty, sid != sessionID {
                RE2Log.info("DESKTOP_READY ignore stale session=\(sid) current=\(sessionID)")
                return
            }
            // Quality reopen keeps geometry; only a post-disconnect READY is "blank".
            let freshDesktop = desktopWidth <= 0 || desktopHeight <= 0
            let prevW = desktopWidth
            let prevH = desktopHeight
            desktopWidth = intVal(obj["width"]) ?? desktopWidth
            desktopHeight = intVal(obj["height"]) ?? desktopHeight
            let readyCodec = (obj["codec"] as? String ?? "h264").lowercased()
            let readyHEVC = readyCodec.contains("265") || readyCodec.contains("hevc")
            decoder.setCodec(readyHEVC ? .hevc : .h264)
            // Soft quality reopen: Agent READY size changed. Reset assembler +
            // decoder so the next IDR (sent after deferred READY) rebuilds SPS.
            // READY is now deferred until after encoder swap, so we won't see a
            // leftover pre-resize IDR after this reset.
            if qualityChangeAwaitingPaint || (!freshDesktop && (desktopWidth != prevW || desktopHeight != prevH)) {
                if let img = frameImage, desktopWidth > 1, desktopHeight > 1 {
                    let slackW = max(48, desktopWidth / 10)
                    let slackH = max(48, desktopHeight / 10)
                    if abs(img.width - desktopWidth) > slackW || abs(img.height - desktopHeight) > slackH {
                        decoder.reset()
                        videoAssembler = VideoFrameAssembler()
                        lastDecodedAt = nil
                        RE2Log.info("DESKTOP_READY size \(prevW)x\(prevH)→\(desktopWidth)x\(desktopHeight) — reset decoder (pic was \(img.width)x\(img.height))")
                    }
                }
            }
            if let did = intVal(obj["display_id"]) {
                selectedDisplayID = did
                desiredDisplayID = did
                confirmedDisplayID = did
            } else if desiredDisplayID == 0 {
                // Agent json omitempty drops display_id when primary (0).
                selectedDisplayID = 0
                confirmedDisplayID = 0
            }
            let list = RE2DisplayInfo.parseList(obj["displays"])
            if !list.isEmpty { displays = list }
            videoPlaneActive = (intVal(obj["video_plane"]) ?? 0) >= 1 && videoMedia != nil
            if let b = obj["mic_authorized"] as? Bool {
                hostMicAuthorized = b
            } else if let n = obj["mic_authorized"] as? NSNumber {
                hostMicAuthorized = n.boolValue
            }
            if let b = obj["camera_authorized"] as? Bool {
                hostCameraAuthorized = b
            } else if let n = obj["camera_authorized"] as? NSNumber {
                hostCameraAuthorized = n.boolValue
            }
            if hostMicAuthorized == false {
                audioMuted = true
                audio.isMuted = true
            }
            if hostCameraAuthorized == false, cameraOn {
                cameraOn = false
                cameraPreview = nil
            }
            phase = .streaming
            hadActiveDesktop = true
            ticketAuthFailures = 0
            setIdleTimerDisabled(true)
            statusText = frameImage == nil
                ? String(localized: "Connected — waiting for video…")
                : String(localized: "Connected")
            RE2Log.info("DESKTOP_READY \(desktopWidth)x\(desktopHeight) codec=\(readyCodec) display=\(selectedDisplayID) confirmed=\(confirmedDisplayID.map(String.init) ?? "nil") video_plane=\(videoPlaneActive) mic=\(String(describing: hostMicAuthorized)) cam=\(String(describing: hostCameraAuthorized)) — request keyframe path=\(pathLabel)")
            refreshPathLabel()
            refreshDisplays()
            if hostCameraAuthorized != false {
                requestCameraList()
            }
            // Sync absolute-touch default so Agent does not expect relative-only.
            setInputMode(game: gameMouseMode)
            // Never leave moves muted after a mid-gesture reconnect / DESKTOP_READY.
            remotePointerSuspended = false
            cursorVisible = true
            // Post-crash / post-disconnect OPEN: re-anchor overlay. Skip on quality
            // reopen so the tip does not jump to center mid-stream.
            if freshDesktop {
                cursorX = 0.5
                cursorY = 0.5
            }
            // Video is unreliable UDP; first IDR is often lost — pull a keyframe immediately.
            requestKeyframe(force: true)
            scheduleKeyframeRetry()
            maybeReopenForNativeQuality()

        case RE2.Msg.video:
            guard let parts = try? RE2Codec.decodeVideo(body) else {
                RE2Log.error("video decodeVideo() failed bodyLen=\(body.count)")
                return
            }
            debugVideoPartsRX += 1
            stats.noteVideo(frameID: parts.frameID, bytes: parts.nal.count)
            if let annexB = videoAssembler.push(
                frameID: parts.frameID, flags: parts.flags,
                part: parts.part, parts: parts.parts, nal: parts.nal
            ) {
                let isKey = parts.flags & RE2.videoFlagKeyFrame != 0
                // Soft reopen: drop P-frames until a post-READY IDR paints the new
                // rung. Old-SPS leftovers after VT reset left pic stuck (1056 vs 672).
                if qualityChangeAwaitingPaint, !isKey,
                   let img = frameImage, desktopWidth > 1, desktopHeight > 1 {
                    let slackW = max(48, desktopWidth / 10)
                    let slackH = max(48, desktopHeight / 10)
                    if abs(img.width - desktopWidth) > slackW || abs(img.height - desktopHeight) > slackH {
                        requestKeyframe(force: true)
                        return
                    }
                }
                debugFramesAssembled += 1
                stats.noteAssembled()
                debugAssemblerPeak = "assembled parts=\(parts.parts)"
                RE2Log.info("video assembled frame=\(parts.frameID) bytes=\(annexB.count) key=\(isKey) parts=\(parts.parts)")
                decoder.decode(annexB: annexB, isKey: isKey) { [weak self] image in
                    Task { @MainActor in
                        guard let self else { return }
                        let first = self.frameImage == nil
                        if first {
                            RE2Log.info("first CGImage decoded key=\(isKey) \(image.width)x\(image.height)")
                            self.statusText = String(localized: "Connected")
                        }
                        self.frameImage = image
                        self.frameEpoch &+= 1
                        self.lastDecodedAt = Date()
                        self.debugFramesDecoded += 1
                        self.stats.noteDecoded()
                        // Only clear when paint catches the *requested* rung — leftover
                        // 1056p under a 流畅 OPEN must keep qualityChangeAwaitingPaint.
                        if self.qualityChangeAwaitingPaint, !self.pictureBehindNego {
                            let target = self.videoQuality == .auto ? DesktopVideoQuality.ultra : self.videoQuality
                            if let expect = self.encodeSize(for: target) {
                                var exp = expect
                                if self.useWSSTunnel {
                                    exp.width = min(exp.width, 3840)
                                    exp.height = min(exp.height, 2160)
                                }
                                let slackW = max(48, exp.width / 10)
                                let slackH = max(48, exp.height / 10)
                                if abs(image.width - exp.width) <= slackW,
                                   abs(image.height - exp.height) <= slackH {
                                    self.qualityChangeAwaitingPaint = false
                                }
                            } else {
                                self.qualityChangeAwaitingPaint = false
                            }
                        }
                        self.syncQualityLabelFromPaint(width: image.width, height: image.height)
                        if self.pendingUDPQualityRamp {
                            self.pendingUDPQualityRamp = false
                            RE2Log.info("UDP shrink painted \(image.width)x\(image.height) — ramp to \(self.videoQuality.rawValue)")
                            self.scheduleRampToSelectedQuality()
                        } else if first {
                            self.maybeReopenForNativeQuality()
                        } else if self.pictureBehindNego, self.targetingFatEncode {
                            // Stale soft picture under a fat nego — keep pulling IDRs.
                            self.qualityChangeAwaitingPaint = true
                            if self.qualityChangeStartedAt == nil {
                                self.qualityChangeStartedAt = Date()
                            }
                            if self.keyframeRetryTask == nil {
                                self.scheduleKeyframeRetry()
                            }
                        }
                    }
                }
            } else {
                let prog = videoAssembler.progressLabel
                if prog != "-" { debugAssemblerPeak = prog }
                if parts.part == 0 || parts.part + 1 == parts.parts || parts.part == 1 || parts.part % 8 == 0 {
                    RE2Log.info("video rx frame=\(parts.frameID) part \(parts.part)/\(parts.parts) flags=0x\(String(parts.flags, radix: 16)) nal=\(parts.nal.count) \(prog)")
                }
                if videoAssembler.takeDroppedIncomplete() {
                    // Don't IDR-storm while a 5K (100s of parts) frame may still fill
                    // from mirror passes — that was keeping the viewer on a sub‑5K paint.
                    if videoAssembler.assemblingLargeFrame {
                        RE2Log.info("video incomplete \(videoAssembler.progressLabel) — wait mirror fill")
                    } else {
                        RE2Log.info("video incomplete frame dropped \(videoAssembler.progressLabel) — soft keyframe")
                        requestKeyframe()
                    }
                }
            }

        case RE2.Msg.cursor:
            let obj = RE2Codec.jsonObject(body)
            lastCursorHeartbeatAt = Date()
            remoteCursorEpoch &+= 1
            // Always keep a drawn cursor while streaming — host CGCursorIsVisible
            // flickers false (hide-while-typing / app chrome) and unreliable CURSOR
            // packets get starved by fat video on LAN, which looked like a freeze.
            // Prefer Agent position when not mid local gesture (suspend = pinch).
            // JSONSerialization yields NSNumber — `as? Double` often fails.
            if !remotePointerSuspended {
                if let x = doubleVal(obj["x"]) { cursorX = min(max(x, 0), 1) }
                if let y = doubleVal(obj["y"]) { cursorY = min(max(y, 0), 1) }
            }
            cursorVisible = true

        case RE2.Msg.displays:
            let obj = RE2Codec.jsonObject(body)
            let list = RE2DisplayInfo.parseList(obj["displays"])
            if !list.isEmpty {
                displays = list
                maybeReopenForNativeQuality()
            }

        case RE2.Msg.clipboard:
            applyRemoteClipboard(RE2Codec.jsonObject(body))

        case RE2.Msg.audio:
            let obj = RE2Codec.jsonObject(body)
            let codec = obj["codec"] as? String ?? "pcm16"
            let sr = intVal(obj["sample_rate"]) ?? 48000
            let ch = intVal(obj["channels"]) ?? 1
            if let b64 = obj["data_b64"] as? String, let data = Data(base64Encoded: b64) {
                audio.play(codec: codec, sampleRate: sr, channels: ch, data: data)
            }

        case RE2.Msg.cameraList:
            let obj = RE2Codec.jsonObject(body)
            let devices = obj["devices"] as? [[String: Any]] ?? []
            remoteCameras = devices.compactMap { d in
                guard let id = d["id"] as? String else { return nil }
                let name = d["name"] as? String ?? id
                return (id, name)
            }
            // Do NOT treat an empty list as "no camera permission". ffmpeg list can
            // fail while OPEN with a default device still works; only DESKTOP_READY
            // camera_authorized=false should disable the control.

        case RE2.Msg.phoneCamReady:
            let obj = RE2Codec.jsonObject(body)
            let ok = obj["ok"] as? Bool ?? false
            if ok {
                phoneWebcamDeviceName = obj["device"] as? String ?? "KoKo Phone Camera"
                phoneWebcamError = nil
                RE2Log.info("phoneWebcam READY device=\(phoneWebcamDeviceName)")
            } else {
                let err = obj["error"] as? String ?? "phonecam failed"
                phoneWebcamError = err
                phoneWebcamOn = false
                phoneCamera.stop()
                RE2Log.error("phoneWebcam READY failed: \(err)")
            }

        case RE2.Msg.sessionReady:
            let sid = RE2Codec.jsonObject(body)["session_id"] as? String ?? ""
            if var route = ptyRoutes[sid] {
                route.ready = true
                ptyRoutes[sid] = route
                route.onReady()
            }

        case RE2.Msg.ptyData:
            guard let (sid, data) = RE2Codec.decodePTY(body) else { return }
            ptyRoutes[sid]?.onData(data)

        case RE2.Msg.sessionClose:
            let obj = RE2Codec.jsonObject(body)
            let sid = obj["session_id"] as? String ?? ""
            if let route = ptyRoutes.removeValue(forKey: sid) {
                route.onClose(obj["reason"] as? String)
            }

        case RE2.Msg.agentChatList:
            let obj = RE2Codec.jsonObject(body)
            if let err = obj["error"] as? String, !err.isEmpty {
                RE2Log.error("agentChatList error: \(err)")
                Self.publishPendingAgentChatList(AgentChatPage(rows: [], nextOffset: 0, hasMore: false))
                return
            }
            let rows = (obj["sessions"] as? [[String: Any]] ?? []).compactMap { row -> RemoteAgentConversation? in
                guard let kindRaw = row["kind"] as? String,
                      let kind = AgentKind(rawValue: kindRaw),
                      let id = row["id"] as? String, !id.isEmpty else { return nil }
                let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let createdMs = (row["created_at_ms"] as? Double) ?? Double(row["created_at_ms"] as? Int ?? 0)
                let updatedMs = (row["updated_at_ms"] as? Double) ?? Double(row["updated_at_ms"] as? Int ?? 0)
                let created = Date(timeIntervalSince1970: createdMs / 1000)
                let updated = Date(timeIntervalSince1970: (updatedMs > 0 ? updatedMs : createdMs) / 1000)
                let screen = row["screen_name"] as? String
                    ?? TerminalSession.defaultScreenName(kind: kind, sessionKey: id)
                return RemoteAgentConversation(
                    agentKind: kind,
                    chatId: id,
                    title: (title?.isEmpty == false ? title! : String(id.prefix(8))),
                    cwd: row["cwd"] as? String,
                    createdAt: created,
                    updatedAt: updated,
                    screenName: screen,
                    screenAlive: row["screen_alive"] as? Bool ?? false,
                    source: row["source"] as? String,
                    client: row["client"] as? String
                )
            }
            Self.publishPendingAgentChatList(AgentChatPage(
                rows: rows.sorted { $0.updatedAt > $1.updatedAt },
                nextOffset: intVal(obj["next_offset"]) ?? rows.count,
                hasMore: obj["has_more"] as? Bool ?? false
            ))

        case RE2.Msg.cameraFrame:
            guard cameraOn else { return }
            let obj = RE2Codec.jsonObject(body)
            guard let b64 = obj["data_b64"] as? String, let chunk = Data(base64Encoded: b64), !chunk.isEmpty else {
                return
            }
            let parts = intVal(obj["parts"]) ?? 1
            let part = intVal(obj["part"]) ?? 0
            let fid = UInt32(intVal(obj["frame_id"]) ?? 0)
            if parts <= 1 {
                if let image = UIImage(data: chunk) { cameraPreview = image }
                return
            }
            if cameraFrameID != fid {
                cameraFrameID = fid
                cameraFrameParts = [:]
                cameraFrameExpected = parts
            }
            cameraFrameParts[part] = chunk
            guard cameraFrameParts.count == cameraFrameExpected, cameraFrameExpected > 0 else { return }
            var assembled = Data()
            assembled.reserveCapacity(cameraFrameParts.values.reduce(0) { $0 + $1.count })
            for i in 0..<cameraFrameExpected {
                guard let piece = cameraFrameParts[i] else { return }
                assembled.append(piece)
            }
            cameraFrameParts = [:]
            cameraFrameID = nil
            if let image = UIImage(data: assembled) {
                cameraPreview = image
            } else {
                RE2Log.error("camera frame assemble decode fail bytes=\(assembled.count) parts=\(cameraFrameExpected)")
            }

        case RE2.Msg.pong, RE2.Msg.ping:
            if mt == RE2.Msg.pong { stats.notePong() }
            if mt == RE2.Msg.ping {
                let payload = body
                Task { try? await self.sendInner(RE2.Msg.pong, payload, reliable: true) }
            }

        case RE2.Msg.fileAck:
            let obj = RE2Codec.jsonObject(body)
            let fileID = obj["file_id"] as? String ?? ""
            let ok = obj["ok"] as? Bool ?? true
            let errStr = obj["error"] as? String
            RE2Log.info("file RX ACK id=\(fileID.prefix(8)) ok=\(ok) pending=\(uploadAcks[fileID] != nil)")
            if let cont = uploadAcks.removeValue(forKey: fileID) {
                if !ok {
                    cont.resume(throwing: RE2Error.signaling(errStr ?? "file rejected"))
                } else {
                    cont.resume()
                }
            } else if !fileID.isEmpty {
                pendingUploadAcks[fileID] = (ok, errStr)
            }
            if let progress = obj["progress"] as? Double, let t = transfers.first(where: { $0.fileID == fileID }) {
                upsertTransfer(RE2TransferProgress(
                    fileID: fileID, name: t.name, direction: t.direction,
                    bytesDone: Int64(progress * Double(max(t.bytesTotal, 1))),
                    bytesTotal: t.bytesTotal, finished: progress >= 1
                ))
            }

        case RE2.Msg.fileOffer:
            // Agent pushing a file to us
            let obj = RE2Codec.jsonObject(body)
            let fileID = obj["file_id"] as? String ?? UUID().uuidString
            let name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fileID
            let size = int64Val(obj["size"]) ?? 0
            let dest = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RE2Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let url = dest.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: url) {
                incomingFiles[fileID] = (name, handle, size)
                upsertTransfer(RE2TransferProgress(
                    fileID: fileID, name: name, direction: .download,
                    bytesDone: 0, bytesTotal: size, finished: false
                ))
            }
            Task {
                try? await self.sendInner(RE2.Msg.fileAck, RE2Codec.jsonData([
                    "session_id": self.sessionID, "file_id": fileID, "ok": true, "offset": 0
                ]), reliable: true)
            }

        case RE2.Msg.fileChunk:
            let obj = RE2Codec.jsonObject(body)
            let fileID = obj["file_id"] as? String ?? ""
            let offset = int64Val(obj["offset"]) ?? 0
            let eof = obj["eof"] as? Bool ?? false
            if let b64 = obj["data_b64"] as? String, let chunk = Data(base64Encoded: b64),
               var entry = incomingFiles[fileID] {
                try? entry.handle.seek(toOffset: UInt64(offset))
                try? entry.handle.write(contentsOf: chunk)
                let done = offset + Int64(chunk.count)
                upsertTransfer(RE2TransferProgress(
                    fileID: fileID, name: entry.name, direction: .download,
                    bytesDone: done, bytesTotal: max(entry.total, done), finished: eof
                ))
                if eof {
                    try? entry.handle.close()
                    incomingFiles.removeValue(forKey: fileID)
                    lastDownloadURL = localDownloadURL(named: entry.name)
                }
                let sid = sessionID
                Task {
                    try? await self.sendInner(RE2.Msg.fileAck, RE2Codec.jsonData([
                        "session_id": sid, "file_id": fileID, "ok": true,
                        "offset": done, "progress": entry.total > 0 ? Double(done) / Double(entry.total) : 0
                    ]), reliable: true)
                }
            }

        case RE2.Msg.fileList:
            let obj = RE2Codec.jsonObject(body)
            if let err = obj["error"] as? String, !err.isEmpty {
                fileListError = err
                remoteFiles = []
                RE2Log.info("file RX LIST error=\(err)")
                resumeFileListWaiter(ok: true) // reply received (denied / failed list)
            } else {
                fileListError = nil
                let pathRaw = (obj["path"] as? String) ?? ""
                remotePath = (pathRaw == "." || pathRaw == "./") ? "" : pathRaw
                let entries = (obj["entries"] as? [[String: Any]]) ?? []
                let base = remotePath
                remoteFiles = entries.compactMap { e in
                    guard let name = e["name"] as? String else { return nil }
                    let isDir = e["is_dir"] as? Bool ?? false
                    let size = int64Val(e["size"]) ?? 0
                    let path = base.isEmpty ? name : base + "/" + name
                    return RE2FileListEntry(name: name, path: path, isDir: isDir, size: size)
                }
                RE2Log.info("file RX LIST path=\(remotePath) entries=\(remoteFiles.count)")
                resumeFileListWaiter(ok: true)
            }

        case RE2.Msg.holePunch:
            if Self.e2eStripLAN {
                RE2Log.info("ignore holePunch \(RE2Codec.jsonObject(body)["action"] as? String ?? "") — E2E stripLAN")
                break
            }
            let obj = RE2Codec.jsonObject(body)
            let action = obj["action"] as? String ?? ""
            let token = obj["token"] as? String ?? ""
            let udp = obj["udp_addr"] as? String ?? ""
            let remoteCands = (obj["candidates"] as? [String]) ?? []
            mergeLanCandidates(remoteCands + [udp])
            let lan = self.paired?.lanCandidates ?? []
            if action == "connected" {
                lanPeerAcked = true
            }
            if action == "candidate" || action == "answer" || action == "offer" {
                Task { await self.establishDirect(peers: lan + remoteCands + [udp], token: token) }
            } else if action == "connected" {
                Task { await self.establishDirect(peers: lan + [udp], token: token) }
            } else if action == "failed" {
                endpoint?.clearDirect()
                usingP2P = false
                lanPeerAcked = false
            }

        case RE2.Msg.desktopClose:
            let obj = RE2Codec.jsonObject(body)
            let reason = obj["reason"] as? String ?? ""
            let lower = reason.lowercased()
            let taken = lower.contains("kick")
                || lower.contains("replaced")
                || lower.contains("superseded")
                || lower.contains("took over")
            if taken {
                let err = annotated(RE2Error.peerTaken)
                lastError = err.localizedDescription
                recoveryHint = err.recoveryHint
                autoReconnect = false
            } else {
                lastError = reason.isEmpty ? String(localized: "Desktop closed") : reason
                recoveryHint = String(localized: "Reconnect from Hosts, or scan a new QR if the Agent restarted pairing.")
            }
            phase = .failed
            statusText = String(localized: "Desktop closed")
            RE2Log.info("DESKTOP_CLOSE reason=\(reason.isEmpty ? "(none)" : reason) taken=\(taken)")

        case RE2.Msg.appError:
            let obj = RE2Codec.jsonObject(body)
            let code = obj["code"] as? String ?? ""
            let message = obj["message"] as? String ?? String(data: body, encoding: .utf8) ?? "error"
            RE2Log.error("appError code=\(code) message=\(message)")
            // Peripheral failures must not tear down an otherwise healthy desktop.
            if code == "session_open_failed" {
                failPendingAgentPTYs(message)
                return
            }
            if code == "camera_open_failed" || (code.hasPrefix("camera_") && !code.hasPrefix("phonecam")) {
                cameraOn = false
                cameraPreview = nil
                cameraError = message
                statusText = String(localized: "Camera failed — check desktop Camera permission / ffmpeg.")
                return
            }
            if code == "phonecam_open_failed" || code.hasPrefix("phonecam_") {
                phoneWebcamOn = false
                phoneWebcamError = message
                phoneCamera.stop()
                statusText = String(localized: "Phone webcam failed on the desktop Agent.")
                return
            }
            var err = RE2Error.fromRelayError(code: code, message: message)
            if code == "desktop_open_failed", message.localizedCaseInsensitiveContains("capture") {
                err = .signaling(String(localized: "Host screen capture failed. On the Mac: System Settings → Privacy & Security → Screen Recording — enable runeverything / Terminal, then reconnect."))
            }
            if case .ticketRejected = err {
                err = escalateTicketFailure(err)
            }
            lastError = err.localizedDescription
            recoveryHint = err.recoveryHint
            phase = .failed
            statusText = String(localized: "Failed")
            if err.stopsAutoReconnect {
                autoReconnect = false
            }

        default:
            break
        }
    }

    private func applyRemoteClipboard(_ obj: [String: Any]) {
        let mime = obj["mime"] as? String ?? "text/plain"
        if let text = obj["text"] as? String, !text.isEmpty {
            UIPasteboard.general.string = text
        } else if mime.hasPrefix("image/"), let b64 = obj["data_b64"] as? String,
                  let data = Data(base64Encoded: b64), let image = UIImage(data: data) {
            UIPasteboard.general.image = image
        }
    }

    private func establishDirect(peers: [String], token: String) async {
        if endpoint?.usingDirect == true {
            usingP2P = true
            refreshPathLabel()
            return
        }
        // Deduplicate while preserving order.
        var seen = Set<String>()
        let ordered = peers.filter { peer in
            guard !peer.isEmpty, !peer.hasSuffix(":0") else { return false }
            if seen.contains(peer) { return false }
            seen.insert(peer)
            return true
        }
        for peer in ordered {
            guard let ok = await RE2HolePunch.tryDirect(peerHostPort: peer, token: token), !ok.isEmpty else {
                continue
            }
            do {
                try await endpoint?.preferDirect(hostPort: ok)
                usingP2P = endpoint?.usingDirect == true
                if usingP2P {
                    directPeerHostPort = ok
                    refreshPathLabel()
                    refreshLanEndpointsDisplay()
                    persistMediaPathHint()
                    // Tell Agent *our* direct listen address so it PreferDirects back (video).
                    let selfAddr = endpoint?.directListenHostPort
                        ?? endpoint?.localHostPort
                        ?? ""
                    try? await sendInner(RE2.Msg.holePunch, RE2Codec.jsonData([
                        "session_id": sessionID,
                        "action": "connected",
                        "token": token,
                        "udp_addr": selfAddr.isEmpty ? ok : selfAddr
                    ]), reliable: true)
                    requestKeyframe()
                    return
                }
            } catch {
                continue
            }
        }
    }

    private func sendInner(_ mt: UInt8, _ body: Data, reliable: Bool) async throws {
        let isFile = mt == RE2.Msg.fileOffer || mt == RE2.Msg.fileChunk
            || mt == RE2.Msg.fileAck || mt == RE2.Msg.filePull || mt == RE2.Msg.fileList
        // Under backpressure, drop non-critical unreliable traffic so video keeps the pipe.
        if !reliable, outboundDepth >= maxOutboundDepth { return }
        // Stats/ping are important but not worth clogging — skip when saturated.
        if reliable, outboundDepth >= maxOutboundDepth,
           mt == RE2.Msg.stats || mt == RE2.Msg.ping {
            return
        }
        // File RPCs jump ahead of media/control like input — otherwise a stuck
        // phone-cam / stats burst makes MENU-07/08 time out while mouse still works.
        let kind: OutboundKind = isFile ? .input : .control
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            enqueueOutbound(kind: kind) { [weak self] in
                guard let self else {
                    cont.resume(throwing: RE2Error.cancelled)
                    return
                }
                do {
                    try await self.performSend(mt, body, reliable: reliable)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func performSend(_ mt: UInt8, _ body: Data, reliable: Bool) async throws {
        let isFile = mt == RE2.Msg.fileOffer || mt == RE2.Msg.fileChunk
            || mt == RE2.Msg.fileAck || mt == RE2.Msg.filePull || mt == RE2.Msg.fileList
        let isInput = mt == RE2.Msg.inputMouse || mt == RE2.Msg.inputTouch || mt == RE2.Msg.inputKey
        let plain = RE2Codec.encodeInner(msgType: mt, body: body)
        // Input must not sit behind ordered Noise HOL on lossy UDP Relay. Reuse
        // the explicit-nonce media AEAD and send redundant copies; Agent dedups
        // discrete event_id values. This keeps clicks/gestures live while a fat
        // video burst or one missing control packet is being repaired.
        if isInput, !useWSSTunnel, videoPlaneActive,
           let videoMedia, let endpoint,
           plain.count <= RE2VideoMedia.maxPlainUDP {
            let copies = reliable ? 5 : 2
            var sent = 0
            var lastError: Error?
            for _ in 0..<copies {
                do {
                    let packet = try videoMedia.seal(plain: plain)
                    try await endpoint.sendUnreliable(packet)
                    sent += 1
                } catch {
                    lastError = error
                }
            }
            if !reliable {
                if sent > 0 { return }
                throw lastError ?? RE2Error.udp("input media-plane send failed")
            }
            // Discrete input also continues over ordered REUDP below. The media
            // copies keep tap latency low; reliable delivery closes a missing
            // event-ID gap and survives an asymmetric stale direct UDP tuple.
        }
        guard let sendCipher else {
            if mt == RE2.Msg.inputMouse || mt == RE2.Msg.inputTouch || mt == RE2.Msg.inputKey || isFile {
                RE2Log.error("send dropped — no sendCipher mt=0x\(String(mt, radix: 16))")
            }
            if isFile {
                throw RE2Error.signaling("no sendCipher for file mt=0x\(String(mt, radix: 16))")
            }
            return
        }
        if useWSSTunnel {
            let ct = try sendCipher.encrypt(plaintext: plain)
            try await signaling?.writeFrame(RE2Frame(type: RE2.OuterType.tunnel, routeID: deviceID, payload: ct))
            if isFile {
                RE2Log.info("file TX WSS mt=0x\(String(mt, radix: 16)) body=\(body.count)")
            }
            return
        }
        guard let endpoint else {
            if isFile {
                throw RE2Error.udp("no endpoint for file mt=0x\(String(mt, radix: 16))")
            }
            return
        }
        // PreferDirect/UDP: ciphertext IS the REUDP payload (cap 1200).
        // MUST size-check BEFORE encrypt — Noise nonces are one-shot; encrypting
        // then throwing burns a nonce and permanently desyncs App→Agent AEAD.
        let noiseOverhead = 16 // ChaCha20-Poly1305 tag
        if plain.count + noiseOverhead > REUDP.maxPayload {
            throw RE2Error.udp("plaintext \(plain.count)+tag > REUDP max \(REUDP.maxPayload) mt=0x\(String(mt, radix: 16))")
        }
        let ct = try sendCipher.encrypt(plaintext: plain)
        // Noise AEAD is ordered on both LAN and relay. Sending already-encrypted
        // "unreliable" stats/input with sendLatest burns the nonce whenever that
        // datagram is lost; all subsequent file/control packets then fail auth.
        // High-rate video has its own gap-tolerant VideoMedia cipher, so every
        // Noise packet can and must use reliable REUDP.
        try await endpoint.sendReliable(ct)
        if isFile {
            RE2Log.info("file TX UDP mt=0x\(String(mt, radix: 16)) body=\(body.count) direct=\(endpoint.usingDirect ? 1 : 0)")
        }
    }

    private func readSignalingSkippingPing(_ sig: RE2SignalingClient) async throws -> RE2Frame {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let remaining = max(0.5, deadline.timeIntervalSinceNow)
            let f = try await sig.readFrame(timeout: min(8, remaining))
            if f.type == RE2.OuterType.ping {
                try? await sig.writeFrame(RE2Frame(type: RE2.OuterType.pong, routeID: f.routeID, payload: f.payload))
                continue
            }
            return f
        }
        throw RE2Error.signaling("frame timeout")
    }

    private func upsertTransfer(_ t: RE2TransferProgress) {
        if let i = transfers.firstIndex(where: { $0.fileID == t.fileID }) {
            transfers[i] = t
        } else {
            transfers.insert(t, at: 0)
        }
        if transfers.count > 20 { transfers = Array(transfers.prefix(20)) }
    }

    private func annotated(_ err: RE2Error) -> RE2Error {
        recoveryHint = err.recoveryHint
        return err
    }

    private static func mapErrorPayload(_ data: Data) -> RE2Error {
        let obj = RE2Codec.jsonObject(data)
        if (obj["code"] as? String) == "controller_busy" {
            return .controllerBusy(peer: obj["peer"] as? String ?? "")
        }
        return RE2Error.fromRelayError(
            code: obj["code"] as? String ?? "",
            message: obj["message"] as? String ?? String(data: data, encoding: .utf8) ?? "error"
        )
    }

    private static func b64url(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str.append("=") }
        return Data(base64Encoded: str)
    }

    private func intVal(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private func doubleVal(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private func int64Val(_ any: Any?) -> Int64? {
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        if let n = any as? NSNumber { return n.int64Value }
        return nil
    }
}

struct VideoFrameAssembler {
    private var currentID: UInt32?
    private var expectedParts: UInt16 = 0
    private var currentFlags: UInt8 = 0
    private var currentStartedAt: Date?
    private var chunks: [UInt16: Data] = [:]
    private var droppedIncomplete = false
    private var holdID: UInt32?
    private var holdExpected: UInt16 = 0
    private var holdFlags: UInt8 = 0
    private var holdStartedAt: Date?
    private var holdChunks: [UInt16: Data] = [:]
    private var holdUntil: Date?
    private var lastRepairFrameID: UInt32?
    private var lastRepairAt: Date?

    /// e.g. `3/12` or `-` when idle — for black-screen diagnosis.
    var progressLabel: String {
        guard let id = currentID, expectedParts > 0 else {
            if let hid = holdID, holdExpected > 0 {
                return "hold=\(hid) got=\(holdChunks.count)/\(holdExpected)"
            }
            return "-"
        }
        return "frame=\(id) got=\(chunks.count)/\(expectedParts)"
    }

    /// True while a multi-part frame is mid-assembly (don't storm new IDRs).
    /// Threshold 8: even 流畅 WSS IDRs are often ~20–30 parts — the old >32 gate
    /// treated them as "small" and keyframe-retried every 2.5s, tearing assembly forever.
    var assemblingLargeFrame: Bool {
        guard let _ = currentID, expectedParts > 8 else { return false }
        return chunks.count < Int(expectedParts)
    }

    /// Any in-flight multi-part assemble (including small IDRs).
    var isAssembling: Bool {
        guard let _ = currentID, expectedParts > 1 else { return false }
        return chunks.count < Int(expectedParts)
    }

    /// Missing parts of an in-flight IDR eligible for targeted UDP repair.
    /// WSS and P-frames deliberately keep their existing keyframe recovery path.
    mutating func videoRepairRequest(now: Date = Date()) -> (frameID: UInt32, expected: UInt16, missing: [UInt16])? {
        if let until = holdUntil, now >= until {
            holdID = nil
            holdExpected = 0
            holdFlags = 0
            holdStartedAt = nil
            holdChunks = [:]
            holdUntil = nil
        }
        let candidate: (UInt32, UInt16, UInt8, Date?, [UInt16: Data])? = {
            if let id = holdID, holdExpected > 1 {
                return (id, holdExpected, holdFlags, holdStartedAt, holdChunks)
            }
            if let id = currentID, expectedParts > 1 {
                return (id, expectedParts, currentFlags, currentStartedAt, chunks)
            }
            return nil
        }()
        guard let (id, expected, flags, started, received) = candidate,
              flags & RE2.videoFlagKeyFrame != 0,
              let started, now.timeIntervalSince(started) >= 0.1 else { return nil }
        if lastRepairFrameID == id, let lastRepairAt, now.timeIntervalSince(lastRepairAt) < 0.75 {
            return nil
        }
        var missing: [UInt16] = []
        missing.reserveCapacity(min(Int(expected), 256))
        for i in 0..<expected where received[i] == nil {
            missing.append(i)
            if missing.count == 256 { break }
        }
        guard !missing.isEmpty else { return nil }
        lastRepairFrameID = id
        lastRepairAt = now
        return (id, expected, missing)
    }

    mutating func push(frameID: UInt32, flags: UInt8, part: UInt16, parts: UInt16, nal: Data) -> Data? {
        if let hid = holdID, frameID == hid, let until = holdUntil, Date() < until {
            holdChunks[part] = nal
            holdFlags |= flags
            if holdExpected == 0 { holdExpected = parts }
            if holdChunks.count == Int(holdExpected), holdExpected > 0 {
                var out = Data()
                var complete = true
                for i in 0..<holdExpected {
                    guard let c = holdChunks[i] else { complete = false; break }
                    out.append(c)
                }
                if complete {
                    holdID = nil
                    holdExpected = 0
                    holdFlags = 0
                    holdStartedAt = nil
                    holdChunks = [:]
                    holdUntil = nil
                    return out
                }
            }
            // A repaired fragment belongs exclusively to the held keyframe.
            // Falling through would compare it with the newer current frame,
            // overwrite the repair slot, and make sparse NACK repair impossible.
            return nil
        }

        if currentID != frameID {
            if let cur = currentID, chunks.count < Int(expectedParts), expectedParts > 1 {
                if currentFlags & RE2.videoFlagKeyFrame != 0 {
                    // Only keyframes are repairable. Never let a later incomplete
                    // P-frame evict the held IDR while its NACK fragments arrive.
                    let hold: TimeInterval
                    if expectedParts > 100 {
                        hold = 12
                    } else if expectedParts > 32 {
                        hold = 8
                    } else {
                        hold = 3
                    }
                    RE2Log.info("video hold incomplete keyframe=\(cur) got=\(chunks.count)/\(expectedParts) for \(hold)s")
                    holdID = cur
                    holdExpected = expectedParts
                    holdFlags = currentFlags
                    holdStartedAt = currentStartedAt
                    holdChunks = chunks
                    holdUntil = Date().addingTimeInterval(hold)
                } else {
                    droppedIncomplete = true
                }
            }
            currentID = frameID
            expectedParts = parts
            currentFlags = flags
            currentStartedAt = Date()
            chunks = [:]
        } else {
            currentFlags |= flags
        }
        chunks[part] = nal
        guard chunks.count == Int(expectedParts), expectedParts > 0 else { return nil }
        var out = Data()
        for i in 0..<expectedParts {
            guard let c = chunks[i] else {
                RE2Log.info("video holes in frame=\(frameID) got=\(chunks.count)/\(expectedParts) missing=\(i)")
                droppedIncomplete = true
                return nil
            }
            out.append(c)
        }
        let completedKeyframe = currentFlags & RE2.videoFlagKeyFrame != 0
        currentID = nil
        expectedParts = 0
        currentFlags = 0
        currentStartedAt = nil
        chunks = [:]
        // A complete P-frame does not supersede a held, incomplete IDR. Clearing
        // the repair slot here meant cellular traffic could receive 70/78 IDR
        // parts, complete one tiny P-frame before the 1s repair tick, and silently
        // lose the only repair candidate. A newer complete IDR does supersede it.
        if completedKeyframe {
            holdID = nil
            holdExpected = 0
            holdFlags = 0
            holdStartedAt = nil
            holdChunks = [:]
            holdUntil = nil
        }
        return out
    }

    mutating func takeDroppedIncomplete() -> Bool {
        let v = droppedIncomplete
        droppedIncomplete = false
        return v
    }
}
