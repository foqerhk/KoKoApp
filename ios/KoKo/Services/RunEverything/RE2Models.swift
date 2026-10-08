import Foundation

/// Client-requested encode ladder for OPEN_DESKTOP / mid-session reopen.
/// Tiers follow common CN remote-desktop products (ToDesk / Oray / Sunflower):
/// 自动 → 流畅 → 标清 → 高清 → 超清（近原画）.
enum DesktopVideoQuality: String, CaseIterable, Identifiable {
    /// Highest quality the current path budget allows (not a fixed 标清/高清).
    case auto
    case smooth
    case balanced
    case high
    case ultra

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .smooth: return String(localized: "Smooth")
        case .balanced: return String(localized: "Balanced")
        case .high: return String(localized: "High")
        case .ultra: return String(localized: "Ultra")
        }
    }

    /// Fraction of the **selected host display** (1.0 = 原画). Tiers are relative
    /// to that screen — not fixed 720p/1080p/4K buckets.
    var scaleFactor: Double {
        switch self {
        case .auto: return Self.recommendedScale
        case .smooth: return 0.35   // 流畅
        case .balanced: return 0.55 // 标清
        case .high: return 0.75     // 高清
        case .ultra: return 1.0     // 超清 / 原画
        }
    }

    /// Auto always asks for native pixels; pathBudget + Agent ABR settle to what
    /// the link can carry (LAN → full, weak WSS → ABR backs off).
    private static let recommendedScale: Double = 1.0

    /// Resolve auto → concrete rung for OPEN / UI size labels.
    func resolved(for path: EncodePath) -> DesktopVideoQuality {
        switch self {
        case .auto: return Self.recommended(for: path)
        default: return self
        }
    }

    /// Highest rung we will *request* on this path. Bitrate still capped by
    /// `pathBudget`; Agent ABR can shrink further under loss.
    static func recommended(for path: EncodePath) -> DesktopVideoQuality {
        switch path {
        case .lan: return .ultra
        case .udpRelay: return .ultra
        case .wssRelay: return .ultra
        }
    }

    /// Percent of selected-display pixels (for UI copy).
    var scalePercent: Int { Int((scaleFactor * 100).rounded()) }

    var subtitle: String {
        let label: String
        switch self {
        case .auto: label = String(localized: "Best for this link")
        case .smooth: label = String(localized: "Weak network · snappy")
        case .balanced: label = String(localized: "Everyday office")
        case .high: label = String(localized: "Recommended")
        case .ultra: label = String(localized: "Best quality")
        }
        if self == .auto {
            return label
        }
        return String(format: String(localized: "%@ · %d%% · %dfps"), label, scalePercent, fps)
    }

    var fps: Int {
        switch self {
        case .auto: return 30
        case .smooth: return 20
        case .balanced: return 24
        case .high: return 30
        case .ultra: return 30
        }
    }

    /// Absolute encoder safety ceiling only (never a quality-tier target).
    /// HEVC up to 16K; H.264 stays ≤1440p (iOS VT -12909 at 5120).
    /// Path budgets + ABR still settle on weak last-mile links.
    static let encoderMaxWidth = 15360
    static let encoderMaxHeight = 8640
    static let encoderMaxWidthH264 = 2560
    static let encoderMaxHeightH264 = 1440
    static let encoderMaxWidthHEVC = 15360
    static let encoderMaxHeightHEVC = 8640

    /// ABR / weak-net step order: 超清 → 高清 → 标清 → 流畅 (never invent sizes).
    static let abrLadder: [DesktopVideoQuality] = [.ultra, .high, .balanced, .smooth]

    /// Next lower discrete tier, or nil at 流畅 floor.
    func nextLowerTier() -> DesktopVideoQuality? {
        switch self {
        case .auto, .ultra: return .high
        case .high: return .balanced
        case .balanced: return .smooth
        case .smooth: return nil
        }
    }

    /// Next higher discrete tier toward 超清.
    func nextHigherTier() -> DesktopVideoQuality? {
        switch self {
        case .smooth: return .balanced
        case .balanced: return .high
        case .high: return .ultra
        case .auto, .ultra: return nil
        }
    }

    /// Map a painted encode size to the nearest configured quality rung.
    static func nearestTier(
        paintWidth: Int, paintHeight: Int,
        nativeWidth: Int, nativeHeight: Int
    ) -> DesktopVideoQuality {
        let nw = max(nativeWidth, 2)
        let nh = max(nativeHeight, 2)
        var best: DesktopVideoQuality = .smooth
        var bestDist = Int.max
        for t in abrLadder {
            let s = t.maxSize(nativeWidth: nw, nativeHeight: nh)
            let d = abs(s.width - paintWidth) + abs(s.height - paintHeight)
            if d < bestDist {
                bestDist = d
                best = t
            }
        }
        return best
    }

    /// Prefer HEVC when the selected display is ≥4K (true 5K needs h265).
    static func preferHEVC(nativeWidth: Int, nativeHeight: Int) -> Bool {
        nativeWidth >= 3840 || nativeHeight >= 2160
    }

    /// Encode size = `scaleFactor` × selected display. Never upscale past native;
    /// no fixed 1080p/4K floors that hijack a 5K panel into "标清 buckets".
    func maxSize(nativeWidth: Int, nativeHeight: Int, hevc: Bool? = nil) -> (width: Int, height: Int) {
        let nw = max(nativeWidth, 2)
        let nh = max(nativeHeight, 2)
        var w = Int((Double(nw) * scaleFactor).rounded())
        var h = Int((Double(nh) * scaleFactor).rounded())
        // Tiny readable floor as a fraction of *this* screen, not absolute pixels.
        let floorScale = 0.20
        let floorW = Int((Double(nw) * floorScale).rounded())
        let floorH = Int((Double(nh) * floorScale).rounded())
        w = min(max(w, min(floorW, nw)), nw)
        h = min(max(h, min(floorH, nh)), nh)
        let useHEVC = hevc ?? Self.preferHEVC(nativeWidth: nw, nativeHeight: nh)
        let maxW = useHEVC ? Self.encoderMaxWidthHEVC : Self.encoderMaxWidthH264
        let maxH = useHEVC ? Self.encoderMaxHeightHEVC : Self.encoderMaxHeightH264
        let fitted = Self.fitEncodeSize(width: w, height: h, maxW: maxW, maxH: maxH)
        return (max(fitted.width, 2), max(fitted.height, 2))
    }

    /// Path-aware bitrate / fps budgets only — resolution comes from `maxSize`.
    enum EncodePath {
        case lan
        case udpRelay
        case wssRelay
    }

    func pathBudget(path: EncodePath) -> (maxBR: Int, maxFPS: Int) {
        // Relay = datacenter symmetric pipe (hundreds of Mbps), not volunteer
        // home uplink. Cap for encode/decode headroom; ABR still backs off on
        // lossy phone Wi‑Fi / weak host last-mile.
        let rung = resolved(for: path)
        switch path {
        case .wssRelay:
            // Datacenter WSS: allow up to 16K class; ABR backs off on HOL/loss.
            switch rung {
            case .auto, .ultra: return (150_000, 30)
            case .smooth:   return (6_000, 20)
            case .balanced: return (20_000, 24)
            case .high:     return (80_000, 30)
            }
        case .udpRelay:
            switch rung {
            case .auto, .ultra: return (200_000, 30)
            case .smooth:   return (8_000, 20)
            case .balanced: return (30_000, 24)
            case .high:     return (100_000, 30)
            }
        case .lan:
            switch rung {
            case .auto, .ultra: return (300_000, 30)
            case .smooth:   return (12_000, 24)
            case .balanced: return (40_000, 30)
            case .high:     return (150_000, 30)
            }
        }
    }

    /// Shrink encode size to fit a max box while preserving aspect ratio.
    static func fitEncodeSize(
        width: Int, height: Int, maxW: Int, maxH: Int
    ) -> (width: Int, height: Int) {
        var w = max(width, 2)
        var h = max(height, 2)
        if maxW > 0, w > maxW {
            h = max(2, (h * maxW) / w)
            w = maxW
        }
        if maxH > 0, h > maxH {
            w = max(2, (w * maxH) / h)
            h = maxH
        }
        return (w & ~1, h & ~1)
    }

    /// Bitrate scales with pixel count × fps (bits-per-pixel style).
    func bitrateKbps(width: Int, height: Int) -> Int {
        let rung = self == .auto ? DesktopVideoQuality.ultra : self
        let bpp: Double
        switch rung {
        case .auto, .ultra: bpp = 0.20
        case .smooth: bpp = 0.11
        case .balanced: bpp = 0.13
        case .high: bpp = 0.16
        }
        var kbps = Int((Double(width * height * fps) * bpp / 1000.0).rounded())
        // Soft per-class caps for desktop HEVC on DC relay / good last-mile.
        // (Old 8–10 Mbps 5K caps assumed weak volunteer relay.)
        let px = width * height
        if px >= 12000 * 6700 {          // ~16K class
            kbps = min(kbps, 250_000)
        } else if px >= 7000 * 3900 {    // ~8K class
            kbps = min(kbps, 150_000)
        } else if px >= 4800 * 2700 {    // ~5K class
            kbps = min(kbps, 80_000)
        } else if px >= 3840 * 2160 {    // 4K
            kbps = min(kbps, 50_000)
        } else if px >= 2560 * 1440 {
            kbps = min(kbps, 30_000)
        }
        return min(300_000, max(800, kbps))
    }

    /// Fallback before we know the host display size.
    var provisionalNative: (width: Int, height: Int) { (1920, 1080) }

    private static let defaultsKey = "re2.desktopVideoQuality"

    static var stored: DesktopVideoQuality {
        // Migrate prior E2E / fixed-tier defaults → Auto (max for link).
        let repairKey = "re2.qualityAutoDefault_v2"
        if !UserDefaults.standard.bool(forKey: repairKey) {
            UserDefaults.standard.set(true, forKey: repairKey)
            let raw = UserDefaults.standard.string(forKey: defaultsKey)
            // Only rewrite presets we previously forced; keep explicit user ultra/smooth.
            if raw == nil
                || raw == DesktopVideoQuality.balanced.rawValue
                || raw == DesktopVideoQuality.high.rawValue {
                UserDefaults.standard.set(DesktopVideoQuality.auto.rawValue, forKey: defaultsKey)
            }
        }
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let q = DesktopVideoQuality(rawValue: raw) {
            return q
        }
        return .auto
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Paired remote desktop (no account — QR only).
struct PairedDesktop: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var deviceID: String
    var relayURL: String
    var udpHostPort: String
    var sessionTicket: String
    /// Noise PSK material from the QR that produced this session (not gated by QR TTL after redeem).
    var pairingToken: String
    /// Agent static public key (base64url) for pinning.
    var noisePub: String?
    /// QR pairing-window expiry (unix seconds). Gates **first** PairRedeem only.
    var expiresAt: Int64
    var createdAt: Date
    /// Last successful media path hint for reconnect (`wss` / `udp` / `p2p`).
    var lastMediaPath: String?
    /// From QR `lan`: Agent LAN host:port list for same-subnet direct UDP.
    var lanCandidates: [String] = []
    /// Alternate relays from QR for reconnect / failover.
    var alternateRelays: [RE2RelayCandidate] = []

    /// Identity-only — `navigationDestination(item:)` must not pop when
    /// `lastMediaPath` / ticket fields churn mid-connect (was killing WSS → peer_gone).
    static func == (lhs: PairedDesktop, rhs: PairedDesktop) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Whether this saved pair can BIND/ASSOC again (session_ticket + PSK).
    /// QR `expires_at` must NOT block reconnect after a successful PairRedeem.
    var canReconnect: Bool {
        !sessionTicket.isEmpty && !pairingToken.isEmpty
    }

    /// Legacy UI flag: never treat QR TTL as "session expired" once we hold a ticket.
    var isExpired: Bool { !canReconnect }

    enum CodingKeys: String, CodingKey {
        case id, name, deviceID, relayURL, udpHostPort, sessionTicket
        case pairingToken, noisePub, expiresAt, createdAt, lastMediaPath, lanCandidates, alternateRelays
    }

    init(
        id: UUID,
        name: String,
        deviceID: String,
        relayURL: String,
        udpHostPort: String,
        sessionTicket: String,
        pairingToken: String,
        noisePub: String? = nil,
        expiresAt: Int64,
        createdAt: Date,
        lastMediaPath: String? = nil,
        lanCandidates: [String] = [],
        alternateRelays: [RE2RelayCandidate] = []
    ) {
        self.id = id
        self.name = name
        self.deviceID = deviceID
        self.relayURL = relayURL
        self.udpHostPort = udpHostPort
        self.sessionTicket = sessionTicket
        self.pairingToken = pairingToken
        self.noisePub = noisePub
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.lastMediaPath = lastMediaPath
        self.lanCandidates = lanCandidates
        self.alternateRelays = alternateRelays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        relayURL = try c.decode(String.self, forKey: .relayURL)
        udpHostPort = try c.decode(String.self, forKey: .udpHostPort)
        sessionTicket = try c.decode(String.self, forKey: .sessionTicket)
        pairingToken = try c.decode(String.self, forKey: .pairingToken)
        noisePub = try c.decodeIfPresent(String.self, forKey: .noisePub)
        expiresAt = try c.decode(Int64.self, forKey: .expiresAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastMediaPath = try c.decodeIfPresent(String.self, forKey: .lastMediaPath)
        lanCandidates = try c.decodeIfPresent([String].self, forKey: .lanCandidates) ?? []
        alternateRelays = try c.decodeIfPresent([RE2RelayCandidate].self, forKey: .alternateRelays) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(relayURL, forKey: .relayURL)
        try c.encode(udpHostPort, forKey: .udpHostPort)
        try c.encode(sessionTicket, forKey: .sessionTicket)
        try c.encode(pairingToken, forKey: .pairingToken)
        try c.encodeIfPresent(noisePub, forKey: .noisePub)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastMediaPath, forKey: .lastMediaPath)
        try c.encode(lanCandidates, forKey: .lanCandidates)
        try c.encode(alternateRelays, forKey: .alternateRelays)
    }
}

enum RE2ConnectionPhase: String {
    case idle
    case pairing
    case binding
    case associating
    case handshaking
    case openingDesktop
    case streaming
    case reconnecting
    case failed
}

struct RE2DisplayInfo: Identifiable, Hashable {
    var id: Int { displayID }
    var displayID: Int
    var name: String
    var width: Int
    var height: Int
    var x: Int
    var y: Int
    var primary: Bool
    /// Helper-owned CGVirtualDisplay (Agent `virtual` / `fb_*`).
    var virtual: Bool
    var fbWidth: Int
    var fbHeight: Int

    /// Pixels used for OPEN encode sizing — prefer framebuffer on virtual screens.
    var encodeWidth: Int {
        if virtual, fbWidth > width { return fbWidth }
        return width
    }
    var encodeHeight: Int {
        if virtual, fbHeight > height { return fbHeight }
        return height
    }

    static func parseList(_ any: Any?) -> [RE2DisplayInfo] {
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let id = d["id"] as? Int ?? (d["id"] as? NSNumber)?.intValue else { return nil }
            let w = (d["width"] as? Int) ?? (d["width"] as? NSNumber)?.intValue ?? 0
            let h = (d["height"] as? Int) ?? (d["height"] as? NSNumber)?.intValue ?? 0
            let fbW = (d["fb_width"] as? Int) ?? (d["fb_width"] as? NSNumber)?.intValue ?? 0
            let fbH = (d["fb_height"] as? Int) ?? (d["fb_height"] as? NSNumber)?.intValue ?? 0
            return RE2DisplayInfo(
                displayID: id,
                name: d["name"] as? String ?? "Display \(id)",
                width: w,
                height: h,
                x: (d["x"] as? Int) ?? (d["x"] as? NSNumber)?.intValue ?? 0,
                y: (d["y"] as? Int) ?? (d["y"] as? NSNumber)?.intValue ?? 0,
                primary: d["primary"] as? Bool ?? false,
                virtual: d["virtual"] as? Bool ?? false,
                fbWidth: fbW,
                fbHeight: fbH
            )
        }
    }
}

struct RE2FileListEntry: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var isDir: Bool
    var size: Int64
}

struct RE2TransferProgress: Identifiable {
    var id: String { fileID }
    var fileID: String
    var name: String
    var direction: Direction
    var bytesDone: Int64
    var bytesTotal: Int64
    var finished: Bool
    var error: String?

    enum Direction { case upload, download }

    var fraction: Double {
        guard bytesTotal > 0 else { return finished ? 1 : 0 }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }
}

/// Tracks video loss / RTT / jitter for ABR STATS, plus stream vs paint fps.
///
/// FPS meaning (remote desktop):
/// - **stream_fps**: complete assembled frames / sec (full pictures available).
/// - **paint_fps**: successfully decoded & drawn frames / sec.
/// UI "fps" uses EMA(stream_fps) — not UDP part rate, not "dirty-region" guesses.
final class RE2StatsTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFrameID: UInt32?
    private var lostFrames: Int = 0
    private var framesSeen: Int = 0
    private var incompletePartLossPct: Double = 0
    private var assembledCount: Int = 0
    private var decodeCount: Int = 0
    private var bytesWindow: Int = 0
    private var windowStart = Date()
    private var lastPingSent: Date?
    private var lastRTTMs: Int = 40
    /// Smoothed values for UI (α≈0.35 per ~2s keepalive window).
    private var emaStreamFPS: Double = 0
    private var emaPaintFPS: Double = 0
    /// Inter-arrival jitter (RFC 3550–style EMA of |Δarrival − Δexpected|).
    private var lastArriveAt: Date?
    private var lastArriveDelta: TimeInterval?
    private var emaJitterMs: Double = 0
    /// Assemble→paint delay EMA (ms).
    private var pendingAssembleAt: Date?
    private var emaDecodeDelayMs: Double = 0

    /// One UDP video part. Frame-level accounting / jitter only advance on a new `frameID`.
    /// Measuring jitter on every part false-triggers weak-net on LAN (multipart bursts).
    func noteVideo(frameID: UInt32, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        bytesWindow += max(0, bytes)
        if let last = lastFrameID, frameID == last {
            return
        }
        let now = Date()
        if let prev = lastArriveAt {
            let delta = now.timeIntervalSince(prev)
            if let lastD = lastArriveDelta {
                let transit = abs(delta - lastD) * 1000
                emaJitterMs = emaJitterMs <= 0 ? transit : 0.25 * transit + 0.75 * emaJitterMs
            }
            lastArriveDelta = delta
        }
        lastArriveAt = now
        if let last = lastFrameID, frameID > last + 1 {
            lostFrames += Int(frameID - last - 1)
        }
        lastFrameID = frameID
        framesSeen += 1
    }

    /// Feed multipart holes before the next frame-ID gap is observable.
    func noteIncompleteVideoParts(missing: Int, expected: Int) {
        guard missing > 0, expected > 0 else { return }
        lock.lock()
        incompletePartLossPct = max(
            incompletePartLossPct,
            Double(missing) / Double(expected) * 100
        )
        lock.unlock()
    }

    /// Multipart assembly produced a full Annex-B unit.
    func noteAssembled() {
        lock.lock()
        assembledCount += 1
        pendingAssembleAt = Date()
        lock.unlock()
    }

    /// VT produced a CGImage that was applied to the surface.
    func noteDecoded() {
        lock.lock()
        decodeCount += 1
        if let t = pendingAssembleAt {
            let ms = max(0, Date().timeIntervalSince(t) * 1000)
            emaDecodeDelayMs = emaDecodeDelayMs <= 0 ? ms : 0.35 * ms + 0.65 * emaDecodeDelayMs
            pendingAssembleAt = nil
        }
        lock.unlock()
    }

    func notePingSent() {
        lock.lock()
        lastPingSent = Date()
        lock.unlock()
    }

    func notePong() {
        lock.lock()
        if let t = lastPingSent {
            lastRTTMs = max(1, Int(Date().timeIntervalSince(t) * 1000))
        }
        lock.unlock()
    }

    /// Snapshot and reset window counters.
    func snapshot(sessionID: String, stalled: Bool = false) -> [String: Any] {
        lock.lock()
        let elapsed = max(0.001, Date().timeIntervalSince(windowStart))
        let denom = max(framesSeen + lostFrames, 1)
        let frameLoss = Double(lostFrames) / Double(denom) * 100.0
        let loss = max(frameLoss, incompletePartLossPct)
        let kbps = Int(Double(bytesWindow) * 8.0 / elapsed / 1000.0)
        let streamFPS = Double(assembledCount) / elapsed
        let paintFPS = Double(decodeCount) / elapsed
        let alpha = 0.35
        emaStreamFPS = emaStreamFPS <= 0 ? streamFPS : alpha * streamFPS + (1 - alpha) * emaStreamFPS
        emaPaintFPS = emaPaintFPS <= 0 ? paintFPS : alpha * paintFPS + (1 - alpha) * emaPaintFPS
        let jitter = Int(emaJitterMs.rounded())
        let decodeDelay = Int(emaDecodeDelayMs.rounded())
        let wantKF = loss > 5 || lostFrames > 2 || stalled || decodeDelay > 120
        let rtt = lastRTTMs
        let outStream = emaStreamFPS
        let outPaint = emaPaintFPS
        lostFrames = 0
        framesSeen = 0
        incompletePartLossPct = 0
        assembledCount = 0
        decodeCount = 0
        bytesWindow = 0
        windowStart = Date()
        lock.unlock()
        var out: [String: Any] = [
            "session_id": sessionID,
            "rtt_ms": rtt,
            "loss_pct": loss,
            "recv_kbps": kbps,
            // Wire name kept for Agent; value is paint rate (drawn frames/sec).
            "decode_fps": outPaint,
            "stream_fps": outStream,
            "jitter_ms": jitter,
            "decode_delay_ms": decodeDelay,
            "want_keyframe": wantKF
        ]
        if stalled { out["stall"] = true }
        return out
    }

    var wantsKeyframe: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lostFrames > 2
    }
}
