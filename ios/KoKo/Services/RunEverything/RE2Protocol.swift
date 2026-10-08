import Foundation
import CryptoKit

/// RE2 / RE2.1 constants and pairing payload (QR v3).
enum RE2 {
    static let protocolVersion = 3
    static let outerMagic0: UInt8 = 0x52 // 'R'
    static let outerMagic1: UInt8 = 0x32 // '2'
    static let outerVersion: UInt8 = 0x02
    static let maxOuterPayload = 1 << 20
    static let noisePrologue = Data("runeverything-re2-v2".utf8)

    enum OuterType {
        static let register: UInt8 = 0x01
        static let registerOK: UInt8 = 0x02
        static let pairOffer: UInt8 = 0x03
        static let pairRedeem: UInt8 = 0x04
        static let pairAck: UInt8 = 0x05
        static let bind: UInt8 = 0x06
        static let bindOK: UInt8 = 0x07
        static let noise: UInt8 = 0x10
        static let tunnel: UInt8 = 0x11
        static let ping: UInt8 = 0x1E
        static let pong: UInt8 = 0x1F
        static let error: UInt8 = 0x20
    }

    enum Msg {
        static let openSession: UInt8 = 0x01
        static let sessionReady: UInt8 = 0x02
        static let sessionClose: UInt8 = 0x03
        static let resize: UInt8 = 0x04
        static let ptyData: UInt8 = 0x05
        static let ping: UInt8 = 0x06
        static let pong: UInt8 = 0x07
        static let appError: UInt8 = 0x0F
        static let openDesktop: UInt8 = 0x20
        static let desktopReady: UInt8 = 0x21
        static let desktopClose: UInt8 = 0x22
        static let video: UInt8 = 0x23
        static let inputMouse: UInt8 = 0x24
        static let inputKey: UInt8 = 0x25
        static let inputTouch: UInt8 = 0x26
        static let audio: UInt8 = 0x30
        static let clipboard: UInt8 = 0x31
        static let cursor: UInt8 = 0x32
        static let displays: UInt8 = 0x33
        static let stats: UInt8 = 0x34
        static let keyframeReq: UInt8 = 0x35
        static let videoNACK: UInt8 = 0x36
        static let fileOffer: UInt8 = 0x40
        static let fileChunk: UInt8 = 0x41
        static let fileAck: UInt8 = 0x42
        static let filePull: UInt8 = 0x43
        static let fileList: UInt8 = 0x44
        static let inputMode: UInt8 = 0x45
        static let holePunch: UInt8 = 0x50
        static let pairConfirm: UInt8 = 0x51
        static let audit: UInt8 = 0x52
        static let wakeOnLAN: UInt8 = 0x60
        static let cameraOpen: UInt8 = 0x70
        static let cameraClose: UInt8 = 0x71
        static let cameraFrame: UInt8 = 0x72
        static let cameraList: UInt8 = 0x73
        /// Phone-as-webcam: phone camera → agent virtual webcam.
        static let phoneCamOpen: UInt8 = 0x74
        static let phoneCamClose: UInt8 = 0x75
        static let phoneCamFrame: UInt8 = 0x76
        static let phoneCamReady: UInt8 = 0x77
        /// AI chat inventory (Cursor/Claude/Codex/Gemini) — data only, no desktop.
        static let agentChatList: UInt8 = 0xA0
        static let agentChatDetail: UInt8 = 0xA1 // reserved hook
        static let usbList: UInt8 = 0x80
        static let usbAttach: UInt8 = 0x81
        static let usbDetach: UInt8 = 0x82
        static let usbData: UInt8 = 0x83
        static let printerList: UInt8 = 0x90
        static let printerJob: UInt8 = 0x91
        static let printerAck: UInt8 = 0x92
    }

    static let videoFlagKeyFrame: UInt8 = 1 << 0

    /// SHA256("re2-psk-v1|" + pairingToken) → 32 bytes.
    static func derivePSK(pairingToken: String) -> Data {
        Data(SHA256.hash(data: Data(("re2-psk-v1|" + pairingToken).utf8)))
    }

    static func ensureRE2URL(_ raw: String) -> URL? {
        guard var c = URLComponents(string: raw), c.scheme != nil else { return nil }
        c.path = "/re2"
        c.query = nil
        c.fragment = nil
        return c.url
    }

    static func clientWebSocketURL(relay: String) -> URL? {
        guard var c = URLComponents(string: ensureRE2URL(relay)?.absoluteString ?? relay) else { return nil }
        var items = c.queryItems ?? []
        items.removeAll { $0.name == "role" }
        items.append(URLQueryItem(name: "role", value: "client"))
        c.queryItems = items
        // URLSessionWebSocketTask needs wss/ws.
        if c.scheme == "https" { c.scheme = "wss" }
        if c.scheme == "http" { c.scheme = "ws" }
        return c.url
    }

    /// True when the relay host is loopback / RFC1918 / .local — unreachable on cellular WAN.
    static func relayHostIsPrivateLAN(_ relay: String) -> Bool {
        let host = (URL(string: relay)?.host ?? URLComponents(string: relay)?.host ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !host.isEmpty else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0" {
            return true
        }
        if host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }

    static func udpHostPort(from relay: String, bindUDP: String?, qrUDP: String?) -> String? {
        if let u = bindUDP, !u.isEmpty { return u }
        if let u = qrUDP, !u.isEmpty { return u }
        guard let url = URL(string: relay), let host = url.host else { return nil }
        let port = url.port ?? 8787
        return "\(host):\(port)"
    }
}

struct RE2PairingPayload: Equatable {
    var v: Int
    var relay: String
    var deviceID: String
    var pairingToken: String
    var name: String
    var expiresAt: Int64
    var noisePub: String?
    var udp: String?
    /// Agent LAN host:port candidates from QR (`lan`) for same-subnet direct UDP.
    var lan: [String] = []
    /// Failover candidates from QR `relays` (same pairing token).
    var relays: [RE2RelayCandidate] = []

    var isExpired: Bool {
        guard expiresAt > 0 else { return false }
        return Date().timeIntervalSince1970 > TimeInterval(expiresAt)
    }

    /// Ordered try-list: primary then alternates (deduped).
    var relayTryList: [RE2RelayCandidate] {
        var out: [RE2RelayCandidate] = []
        var seen = Set<String>()
        let primary = RE2RelayCandidate(relay: relay, udp: udp)
        out.append(primary)
        seen.insert(relay)
        for c in relays where !c.relay.isEmpty && !seen.contains(c.relay) {
            seen.insert(c.relay)
            out.append(c)
        }
        return out
    }
}

struct RE2RelayCandidate: Equatable, Hashable, Codable {
    var relay: String
    var udp: String?
}

extension RE2PairingPayload {
    static func parse(_ raw: String) throws -> RE2PairingPayload {
        let trimmed = sanitizePairingInput(raw)
        if trimmed.hasPrefix("{") {
            return try parseJSON(Data(trimmed.utf8))
        }
        if trimmed.lowercased().hasPrefix("koko:") {
            // Prefer manual query parse — URL(string:) drops/ truncates when paste wraps mid-token.
            if let payload = try? parseDeepLinkString(trimmed) {
                return payload
            }
            if let url = URL(string: trimmed) {
                return try parseDeepLink(url)
            }
        }
        if let url = URL(string: trimmed), url.scheme?.lowercased() == "koko" {
            return try parseDeepLink(url)
        }
        // Some scanners wrap JSON with whitespace / BOM
        if let data = trimmed.data(using: .utf8), data.first == 0x7B {
            return try parseJSON(data)
        }
        throw RE2Error.badPairing(String(localized: "Unrecognized QR content"))
    }

    /// Strip soft line-wraps from terminal/paste (e.g. `pai\\nring_token=`).
    private static func sanitizePairingInput(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        let lower = s.lowercased()
        if lower.hasPrefix("koko:") || lower.hasPrefix("http:") || lower.hasPrefix("https:") {
            return s.components(separatedBy: .whitespacesAndNewlines).joined()
        }
        if s.hasPrefix("{") {
            return s.replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
        }
        return s
    }

    private static func parseJSON(_ data: Data) throws -> RE2PairingPayload {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RE2Error.badPairing(String(localized: "Invalid pairing JSON"))
        }
        return try fromDict(obj)
    }

    private static func parseDeepLink(_ url: URL) throws -> RE2PairingPayload {
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty {
            return try fromDict(dictFromQueryItems(items))
        }
        return try parseDeepLinkString(url.absoluteString)
    }

    private static func parseDeepLinkString(_ raw: String) throws -> RE2PairingPayload {
        guard let qIndex = raw.firstIndex(of: "?") else {
            throw RE2Error.badPairing(String(localized: "Empty pairing link"))
        }
        let query = String(raw[raw.index(after: qIndex)...])
        var dict: [String: Any] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let nameRaw = parts.first, !nameRaw.isEmpty else { continue }
            let name = String(nameRaw).removingPercentEncoding ?? String(nameRaw)
            let valueRaw = parts.count > 1 ? String(parts[1]) : ""
            let value = valueRaw.removingPercentEncoding ?? valueRaw
            if name == "v" || name == "expires_at" {
                dict[name] = Int64(value) ?? value
            } else if name == "lan" || name == "relays" {
                dict[name] = value // parsed later via list helpers
            } else {
                dict[name] = value
            }
        }
        // Recover paste wraps that split a key across lines before sanitize (legacy path).
        if dict["pairing_token"] == nil, dict["pairingToken"] == nil {
            if let pai = dict["pai"] as? String, let rest = dict["ring_token"] as? String {
                dict["pairing_token"] = pai + rest
            }
        }
        guard !dict.isEmpty else {
            throw RE2Error.badPairing(String(localized: "Empty pairing link"))
        }
        return try fromDict(dict)
    }

    private static func dictFromQueryItems(_ items: [URLQueryItem]) -> [String: Any] {
        var dict: [String: Any] = [:]
        for item in items {
            guard let value = item.value else { continue }
            if item.name == "v" || item.name == "expires_at" {
                dict[item.name] = Int64(value) ?? value
            } else {
                dict[item.name] = value
            }
        }
        return dict
    }

    private static func fromDict(_ obj: [String: Any]) throws -> RE2PairingPayload {
        let v = intValue(obj["v"]) ?? 0
        guard v == RE2.protocolVersion else {
            throw RE2Error.badPairing(
                String(
                    format: String(localized: "Unsupported pairing version %lld (need %lld)"),
                    Int64(v),
                    Int64(RE2.protocolVersion)
                )
            )
        }
        let relay = obj["relay"] as? String ?? ""
        let deviceID = (obj["device_id"] as? String) ?? (obj["deviceID"] as? String) ?? ""
        let token = (obj["pairing_token"] as? String) ?? (obj["pairingToken"] as? String) ?? ""
        guard !relay.isEmpty, !deviceID.isEmpty, !token.isEmpty else {
            var missing: [String] = []
            if relay.isEmpty { missing.append("relay") }
            if deviceID.isEmpty { missing.append("device_id") }
            if token.isEmpty { missing.append("pairing_token") }
            throw RE2Error.badPairing(
                String(
                    format: String(localized: "Pairing code is missing %@"),
                    missing.joined(separator: ", ")
                )
            )
        }
        let name = (obj["name"] as? String) ?? ""
        let exp = intValue(obj["expires_at"]) ?? intValue(obj["expiresAt"]) ?? 0
        let noise = obj["noise_pub"] as? String ?? obj["noisePub"] as? String
        let udp = obj["udp"] as? String
        let lan = parseLANList(obj["lan"])
        let relays = parseRelayList(obj["relays"])
        return RE2PairingPayload(
            v: Int(v),
            relay: relay,
            deviceID: deviceID,
            pairingToken: token,
            name: name,
            expiresAt: exp,
            noisePub: noise,
            udp: udp,
            lan: lan,
            relays: relays
        )
    }

    private static func parseRelayList(_ any: Any?) -> [RE2RelayCandidate] {
        if let arr = any as? [[String: Any]] {
            return arr.compactMap { row in
                guard let r = row["relay"] as? String, !r.isEmpty else { return nil }
                return RE2RelayCandidate(relay: r, udp: row["udp"] as? String)
            }
        }
        if let arr = any as? [String] {
            return arr.compactMap { parseRelayCandidateToken($0) }
        }
        if let s = any as? String, !s.isEmpty {
            return s.split(separator: ",").compactMap { parseRelayCandidateToken(String($0)) }
        }
        return []
    }

    private static func parseRelayCandidateToken(_ raw: String) -> RE2RelayCandidate? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let bar = t.firstIndex(of: "|") {
            let relay = String(t[..<bar]).trimmingCharacters(in: .whitespaces)
            let udp = String(t[t.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
            guard !relay.isEmpty else { return nil }
            return RE2RelayCandidate(relay: relay, udp: udp.isEmpty ? nil : udp)
        }
        return RE2RelayCandidate(relay: t, udp: nil)
    }

    private static func parseLANList(_ any: Any?) -> [String] {
        if let arr = any as? [String] {
            return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let arr = any as? [Any] {
            return arr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let s = any as? String {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return []
    }

    private static func intValue(_ any: Any?) -> Int64? {
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String { return Int64(s) }
        return nil
    }
}

struct RE2Frame {
    var type: UInt8
    var routeID: String
    var payload: Data

    func encode() throws -> Data {
        guard payload.count <= RE2.maxOuterPayload else { throw RE2Error.frameTooLarge }
        let route = Data(routeID.utf8)
        var out = Data(capacity: 12 + route.count + payload.count)
        out.append(RE2.outerMagic0)
        out.append(RE2.outerMagic1)
        out.append(RE2.outerVersion)
        out.append(type)
        out.appendUInt32BE(UInt32(route.count))
        out.append(route)
        out.appendUInt32BE(UInt32(payload.count))
        out.append(payload)
        return out
    }

    static func decode(_ data: Data) throws -> RE2Frame {
        guard data.count >= 8 else { throw RE2Error.badFrame }
        guard data[0] == RE2.outerMagic0, data[1] == RE2.outerMagic1 else { throw RE2Error.badFrame }
        guard data[2] == RE2.outerVersion else { throw RE2Error.badFrame }
        let type = data[3]
        let routeLen = Int(data.readUInt32BE(at: 4))
        guard routeLen <= 512, data.count >= 8 + routeLen + 4 else { throw RE2Error.badFrame }
        let routeStart = 8
        let routeEnd = routeStart + routeLen
        let routeID = String(data: data[routeStart..<routeEnd], encoding: .utf8) ?? ""
        let plen = Int(data.readUInt32BE(at: routeEnd))
        guard plen <= RE2.maxOuterPayload, data.count >= routeEnd + 4 + plen else { throw RE2Error.badFrame }
        let payload = data[(routeEnd + 4)..<(routeEnd + 4 + plen)]
        return RE2Frame(type: type, routeID: routeID, payload: Data(payload))
    }
}

enum RE2Codec {
    static func encodeInner(msgType: UInt8, body: Data) -> Data {
        var out = Data(capacity: 5 + body.count)
        out.append(msgType)
        out.appendUInt32BE(UInt32(body.count))
        out.append(body)
        return out
    }

    static func decodeInner(_ data: Data) throws -> (UInt8, Data) {
        guard data.count >= 5 else { throw RE2Error.badInner }
        let mt = data[0]
        let n = Int(data.readUInt32BE(at: 1))
        guard data.count >= 5 + n else { throw RE2Error.badInner }
        return (mt, Data(data[5..<(5 + n)]))
    }

    static func decodeVideo(_ body: Data) throws -> (sessionID: String, frameID: UInt32, flags: UInt8, part: UInt16, parts: UInt16, nal: Data) {
        guard !body.isEmpty else { throw RE2Error.badVideo }
        let n = Int(body[0])
        guard body.count >= 1 + n + 4 + 1 + 2 + 2 else { throw RE2Error.badVideo }
        let sid = String(data: body[1..<(1 + n)], encoding: .utf8) ?? ""
        var o = 1 + n
        let frameID = body.readUInt32BE(at: o); o += 4
        let flags = body[o]; o += 1
        let part = body.readUInt16BE(at: o); o += 2
        let parts = body.readUInt16BE(at: o); o += 2
        return (sid, frameID, flags, part, parts, Data(body[o...]))
    }

    /// Binary phone-cam part (Agent `re2.EncodePhoneCam`). Magic `P1`.
    static let phoneCamFlagKey: UInt8 = 1 << 0
    static let phoneCamCodecJPEG: UInt8 = 0
    static let phoneCamCodecH264: UInt8 = 1

    static func encodePhoneCam(
        sessionID: String,
        frameID: UInt32,
        flags: UInt8,
        part: UInt16,
        parts: UInt16,
        width: Int,
        height: Int,
        codec: UInt8,
        raw: Data
    ) -> Data {
        var sid = Data(sessionID.utf8)
        if sid.count > 255 { sid = sid.prefix(255) }
        var out = Data(capacity: 2 + 1 + sid.count + 4 + 1 + 2 + 2 + 2 + 2 + 1 + raw.count)
        out.append(0x50) // 'P'
        out.append(0x31) // '1'
        out.append(UInt8(sid.count))
        out.append(sid)
        out.appendUInt32BE(frameID)
        out.append(flags)
        out.appendUInt16BE(part)
        out.appendUInt16BE(parts)
        out.appendUInt16BE(UInt16(clamping: width))
        out.appendUInt16BE(UInt16(clamping: height))
        out.append(codec)
        out.append(raw)
        return out
    }

    /// Max raw bytes/part for VideoMedia UDP (matches Agent `PhoneCamChunkSize`).
    static func phoneCamChunkRaw(sessionID: String) -> Int {
        let sid = min(255, sessionID.utf8.count)
        // seal 30 + EncodeInner 5 + P1 hdr (2+1+sid+4+1+2+2+2+2+1)
        let hdr = 30 + 5 + 2 + 1 + sid + 4 + 1 + 2 + 2 + 2 + 2 + 1
        return max(64, REUDP.maxPayload - hdr)
    }

    /// Agent `re2.EncodePTY`: 1-byte id length, session id, raw PTY bytes.
    static func encodePTY(sessionID: String, data: Data) -> Data {
        var sid = Data(sessionID.utf8)
        if sid.count > 255 { sid = sid.prefix(255) }
        var out = Data(capacity: 1 + sid.count + data.count)
        out.append(UInt8(sid.count))
        out.append(sid)
        out.append(data)
        return out
    }

    static func decodePTY(_ body: Data) -> (String, Data)? {
        guard let n = body.first.map(Int.init), body.count >= 1 + n else { return nil }
        let start = body.startIndex
        let sid = String(data: body[(start + 1)..<(start + 1 + n)], encoding: .utf8) ?? ""
        return (sid, Data(body[(start + 1 + n)...]))
    }

    static func jsonData(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    static func jsonObject(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

enum RE2Error: LocalizedError {
    case badPairing(String)
    case badFrame
    case frameTooLarge
    case badInner
    case badVideo
    case signaling(String)
    case noise(String)
    case udp(String)
    case pinMismatch
    /// Agent rotated pairing / Noise PSK — must scan a fresh QR (never re-Redeem old token).
    case needsRescan
    /// BIND/ASSOC rejected the session_ticket once (may be flaky; retryable).
    case ticketRejected
    /// Repeated ticket rejection — relay likely restarted (in-memory sessions cleared).
    case relayRestarted
    /// Another client took the session (kick / replaced).
    case peerTaken
    case expired
    case relayFull
    case agentOffline
    case cancelled
    case desktopOpenTimeout

    var errorDescription: String? {
        switch self {
        case .badPairing(let m): return m
        case .badFrame: return String(localized: "Invalid RE2 frame")
        case .frameTooLarge: return String(localized: "RE2 frame too large")
        case .badInner: return String(localized: "Invalid RE2 inner message")
        case .badVideo: return String(localized: "Invalid video fragment")
        case .signaling(let m): return m
        case .noise(let m): return m
        case .udp(let m): return m
        case .pinMismatch: return String(localized: "Agent identity mismatch (noise_pub)")
        case .needsRescan:
            return String(localized: "Agent re-paired or session credentials no longer match. Scan a fresh QR.")
        case .ticketRejected:
            return String(localized: "Session ticket rejected by relay")
        case .relayRestarted:
            return String(localized: "Relay restarted — session ticket is gone. Scan a fresh Agent QR.")
        case .peerTaken:
            return String(localized: "Disconnected — another client took over this session.")
        case .expired: return String(localized: "Pairing QR expired — scan again")
        case .relayFull: return String(localized: "Relay is full — try another node or later")
        case .agentOffline: return String(localized: "Agent is offline")
        case .cancelled: return String(localized: "Cancelled")
        case .desktopOpenTimeout:
            return String(localized: "Desktop did not open in time. Confirm the prompt on the host, then reconnect.")
        }
    }

    static func fromRelayError(code: String, message: String) -> RE2Error {
        let c = code.lowercased()
        let m = message.lowercased()
        switch c {
        case "relay_full": return .relayFull
        case "agent_offline", "offline": return .agentOffline
        case "expired", "pairing_expired":
            return .expired
        case "pair_failed":
            // PairRedeem-only path; reconnect must never hit this.
            return .signaling(
                message.isEmpty
                    ? String(localized: "Pairing token unknown or superseded. Refresh the QR on the Agent and scan again.")
                    : message
            )
        case "auth_failed", "invalid_session", "bad_ticket":
            return .ticketRejected
        case "kicked", "superseded", "replaced":
            return .peerTaken
        default:
            if m.contains("kick") || m.contains("replaced") || m.contains("took over") || m.contains("superseded") {
                return .peerTaken
            }
            if m.contains("ticket") || (m.contains("session") && m.contains("invalid")) {
                return .ticketRejected
            }
            return .signaling(message.isEmpty ? code : message)
        }
    }

    var recoveryHint: String {
        switch self {
        case .relayFull:
            return String(localized: "This volunteer relay is full. Ask the Agent to pick another node, or try again later.")
        case .agentOffline:
            return String(localized: "Agent is offline. Wake the PC or re-scan when it is online.")
        case .expired:
            return String(localized: "Pairing QR expired. Generate a new QR on the Agent and scan again.")
        case .pinMismatch, .needsRescan:
            return String(localized: "Do not reuse the old pairing code. Delete this desktop and scan a new Agent QR.")
        case .ticketRejected:
            return String(localized: "Retry reconnect. If it keeps failing, the relay may have restarted — scan a new QR.")
        case .relayRestarted:
            return String(localized: "Relay memory was cleared. Pair again with a fresh Agent QR.")
        case .peerTaken:
            return String(localized: "Another client is using this Agent. Close it there, then tap Reconnect.")
        case .desktopOpenTimeout:
            return String(localized: "If the host shows a permission / privacy dialog, accept it, then tap Reconnect.")
        case .noise:
            return String(localized: "Network glitch during encryption handshake. Tap Reconnect to retry.")
        case .signaling(let m) where m.localizedCaseInsensitiveContains("superseded")
            || m.localizedCaseInsensitiveContains("unknown")
            || m.localizedCaseInsensitiveContains("pair"):
            return String(localized: "Ask the Agent to print a fresh QR (do not reuse an old terminal QR after reconnect).")
        default:
            return localizedDescription ?? ""
        }
    }

    /// Failures that must stop auto-reconnect (manual rescan / reconnect only).
    var stopsAutoReconnect: Bool {
        switch self {
        case .pinMismatch, .needsRescan, .relayRestarted, .peerTaken, .expired:
            return true
        default:
            return false
        }
    }
}

extension Data {
    mutating func appendUInt16BE(_ v: UInt16) {
        append(UInt8((v >> 8) & 0xff))
        append(UInt8(v & 0xff))
    }

    mutating func appendUInt32BE(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8(v & 0xff))
    }

    mutating func appendUInt64BE(_ v: UInt64) {
        appendUInt32BE(UInt32(v >> 32))
        appendUInt32BE(UInt32(v & 0xffff_ffff))
    }

    func readUInt16BE(at i: Int) -> UInt16 {
        (UInt16(self[i]) << 8) | UInt16(self[i + 1])
    }

    func readUInt32BE(at i: Int) -> UInt32 {
        (UInt32(self[i]) << 24) | (UInt32(self[i + 1]) << 16) | (UInt32(self[i + 2]) << 8) | UInt32(self[i + 3])
    }

    func readUInt64BE(at i: Int) -> UInt64 {
        (UInt64(readUInt32BE(at: i)) << 32) | UInt64(readUInt32BE(at: i + 4))
    }
}
