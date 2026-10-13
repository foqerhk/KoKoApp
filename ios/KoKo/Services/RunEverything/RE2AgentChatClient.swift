import Foundation
import UIKit

/// RE2 data-channel handshake, plus a one-shot AI session list for relays / Agents
/// without separate channels (`DesktopSessionHub` otherwise uses a shared `RE2DataTunnel`).
/// Does **not** open desktop, video, mouse, or PTY — data only.
enum RE2AgentChatClient {
    static func lifecycleStatus(profile: PairedDesktop) async throws -> HostLifecycleStatus {
        let sig = RE2SignalingClient()
        try await sig.connect(relay: profile.relayURL)
        defer { sig.close() }
        await MainActor.run { RE2ControllerIdentity.stampDisplayName(DeviceMarketingName.controllerLabel) }
        try await sig.writeFrame(RE2Frame(
            type: RE2.OuterType.lifecycleQuery,
            routeID: profile.deviceID,
            payload: RE2Codec.jsonData([
                "device_id": profile.deviceID,
                "session_ticket": profile.sessionTicket,
                "client_id": RE2ControllerIdentity.id,
            ])
        ))
        let frame = try await readSkippingPing(sig)
        if frame.type == RE2.OuterType.error {
            throw relayError(frame.payload, fallback: "lifecycle query failed")
        }
        guard frame.type == RE2.OuterType.lifecycleStatus else {
            throw RE2Error.signaling("unexpected lifecycle reply")
        }
        return try HostLifecycleStatus.decode(frame.payload)
    }

    /// Fetch Cursor / Claude / Codex / Gemini chats from a paired Agent.
    static func listChats(
        profile: PairedDesktop,
        projectPath: String? = nil,
        kind: AgentKind? = nil,
        force: Bool = false,
        channel: Bool = true
    ) async throws -> [RemoteAgentConversation] {
        let link = try await handshake(profile: profile, force: force, channel: channel)
        let (sig, send, recv, route) = (link.sig, link.send, link.recv, link.route)
        defer { sig.close() }

        var offset = 0
        var all: [RemoteAgentConversation] = []
        var seen = Set<String>()
        for _ in 0..<256 {
            var req: [String: Any] = ["action": "list", "offset": offset]
            if let projectPath, !projectPath.isEmpty { req["project_path"] = projectPath }
            if let kind { req["kind"] = kind.rawValue }
            let ct = try send.encrypt(plaintext: RE2Codec.encodeInner(
                msgType: RE2.Msg.agentChatList,
                body: RE2Codec.jsonData(req)
            ))
            try await sig.writeFrame(RE2Frame(type: RE2.OuterType.tunnel, routeID: route, payload: ct))

            let deadline = Date().addingTimeInterval(20)
            var page: AgentChatPage?
            while Date() < deadline {
                let f = try await readSkippingPing(sig)
                guard f.type == RE2.OuterType.tunnel else { continue }
                let plain = try recv.decrypt(ciphertext: f.payload)
                let (mt, body) = try RE2Codec.decodeInner(plain)
                if mt == RE2.Msg.appError {
                    let obj = RE2Codec.jsonObject(body)
                    throw RE2Error.signaling(obj["message"] as? String ?? "agent chat list failed")
                }
                guard mt == RE2.Msg.agentChatList else { continue }
                page = try parseList(body)
                break
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

    struct DataLink {
        var sig: RE2SignalingClient
        var send: NoiseCipherState
        var recv: NoiseCipherState
        /// RouteID for tunnel frames: the data channel's, or the bare device id on old relays.
        var route: String
        /// `false` on a relay that ignored the channel: this link holds the desktop slot.
        var separate: Bool
    }

    /// BIND the data channel with the session ticket and run Noise XX+PSK over WSS
    /// (no PairRedeem, no desktop). `force` takes over from another phone;
    /// `channel: false` is the pre-channel bind for old relays / Agents.
    static func handshake(profile: PairedDesktop, force: Bool = false, channel: Bool = true) async throws -> DataLink {
        guard profile.canReconnect else {
            throw RE2Error.signaling(String(localized: "Re-pair required — scan a fresh Agent QR."))
        }
        let sig = RE2SignalingClient()
        try await sig.connect(relay: profile.relayURL)
        do {
            return try await bindAndHandshake(sig: sig, profile: profile, force: force, channel: channel)
        } catch {
            sig.close()
            throw error
        }
    }

    private static func bindAndHandshake(
        sig: RE2SignalingClient,
        profile: PairedDesktop,
        force: Bool,
        channel: Bool
    ) async throws -> DataLink {
        let deviceID = profile.deviceID
        await MainActor.run { RE2ControllerIdentity.stampDisplayName(DeviceMarketingName.controllerLabel) }
        try await sig.writeFrame(RE2Frame(
            type: RE2.OuterType.bind,
            routeID: deviceID,
            payload: RE2ControllerIdentity.bindPayload(
                deviceID: deviceID, sessionTicket: profile.sessionTicket, force: force,
                channel: channel ? RE2Channel.data : nil
            )
        ))
        let bindFrame = try await readSkippingPing(sig)
        if bindFrame.type == RE2.OuterType.error {
            throw relayError(bindFrame.payload, fallback: "bind failed")
        }
        guard bindFrame.type == RE2.OuterType.bindOK else {
            throw RE2Error.signaling("unexpected bind reply")
        }
        let separate = (RE2Codec.jsonObject(bindFrame.payload)["channel"] as? String) == RE2Channel.data
        let route = separate ? RE2Channel.route(deviceID: deviceID, channel: RE2Channel.data) : deviceID

        // Noise XX+PSK over WSS.
        let psk = RE2.derivePSK(pairingToken: profile.pairingToken)
        let hs = try NoiseXXPSK3(psk: psk)
        let msg1 = try hs.writeMessage1()
        try await sig.writeFrame(RE2Frame(type: RE2.OuterType.noise, routeID: route, payload: msg1))
        var msg2: Data?
        for _ in 0..<8 {
            let f = try await readSkippingPing(sig)
            if f.type == RE2.OuterType.error {
                throw relayError(f.payload, fallback: "noise failed")
            }
            if f.type == RE2.OuterType.noise {
                msg2 = f.payload
                break
            }
        }
        guard let msg2 else {
            throw RE2Error.noise(String(localized: "Agent did not answer the data channel handshake. If the remote desktop is open on another phone, close it there and retry."))
        }
        try hs.readMessage2(msg2)
        let (msg3, send, recv) = try hs.writeMessage3()
        try await sig.writeFrame(RE2Frame(type: RE2.OuterType.noise, routeID: route, payload: msg3))
        return DataLink(sig: sig, send: send, recv: recv, route: route, separate: separate)
    }

    /// Relay error frame → RE2Error, keeping the busy / takeover controller's name.
    static func relayError(_ payload: Data, fallback: String) -> RE2Error {
        let obj = RE2Codec.jsonObject(payload)
        let code = (obj["code"] as? String ?? "").lowercased()
        let peer = RE2ControllerIdentity.peerLabel(
            peer: obj["peer"] as? String ?? "",
            since: (obj["since"] as? Int64) ?? Int64(obj["since"] as? Int ?? 0)
        )
        if code == "controller_busy" {
            return .controllerBusy(peer: peer)
        }
        if code == "kicked" || code == "superseded" || code == "replaced" {
            return .peerTaken(peer: peer)
        }
        var mapped = RE2Error.fromRelayError(code: obj["code"] as? String ?? "", message: obj["message"] as? String ?? fallback)
        if case .peerTaken = mapped, !peer.isEmpty {
            mapped = .peerTaken(peer: peer)
        }
        return mapped
    }

    private static func readSkippingPing(_ sig: RE2SignalingClient) async throws -> RE2Frame {
        for _ in 0..<20 {
            let f = try await sig.readFrame(timeout: 8)
            if f.type == RE2.OuterType.ping {
                try? await sig.writeFrame(RE2Frame(type: RE2.OuterType.pong, routeID: f.routeID, payload: f.payload))
                continue
            }
            if f.type == RE2.OuterType.pong { continue }
            return f
        }
        throw RE2Error.signaling("frame timeout")
    }

    fileprivate struct AgentChatPage {
        var rows: [RemoteAgentConversation]
        var nextOffset: Int
        var hasMore: Bool
    }

    fileprivate static func parseList(_ body: Data) throws -> AgentChatPage {
        let obj = RE2Codec.jsonObject(body)
        if let err = obj["error"] as? String, !err.isEmpty {
            throw RE2Error.signaling(err)
        }
        let rows = obj["sessions"] as? [[String: Any]] ?? []
        let parsed = rows.compactMap { row -> RemoteAgentConversation? in
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
        .sorted { $0.updatedAt > $1.updatedAt }
        return AgentChatPage(
            rows: parsed,
            nextOffset: (obj["next_offset"] as? Int) ?? parsed.count,
            hasMore: obj["has_more"] as? Bool ?? false
        )
    }
}

// MARK: - Agent PTY (AI CLI terminal on a paired desktop)

/// Agent `OpenSessionPayload` without the session id.
struct AgentPTYOpenRequest {
    var cmd: [String]
    var cols: Int
    var rows: Int

    func payload(sessionID: String) -> Data {
        RE2Codec.jsonData([
            "session_id": sessionID,
            "cmd": cmd,
            "cols": cols,
            "rows": rows,
        ])
    }

    /// Keep each reliable control message well under one REUDP datagram.
    static func chunks(of data: Data, size: Int = 1024) -> [Data] {
        guard data.count > size else { return [data] }
        return stride(from: 0, to: data.count, by: size).map {
            data.subdata(in: $0..<min($0 + size, data.count))
        }
    }
}

@MainActor
protocol AgentPTYTransport: AnyObject {
    var label: String { get }
    func open(
        id: String,
        request: AgentPTYOpenRequest,
        onReady: @escaping () -> Void,
        onData: @escaping (Data) -> Void,
        onClose: @escaping (String?) -> Void
    ) async throws
    func write(id: String, data: Data) async throws
    func resize(id: String, cols: Int, rows: Int) async
    func close(id: String) async
    func shutdown()
}

/// Long-lived data-only WSS tunnel: PTY bytes without desktop video.
@MainActor
final class RE2DataTunnel: AgentPTYTransport {
    private struct Route {
        var ready = false
        var onReady: () -> Void
        var onData: (Data) -> Void
        var onClose: (String?) -> Void
    }

    private let profile: PairedDesktop
    private var sig: RE2SignalingClient?
    private var sendCipher: NoiseCipherState?
    private var recvCipher: NoiseCipherState?
    private var route: String
    private var readTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    /// Noise nonces must reach the Agent in encryption order.
    private var sendTail: Task<Void, Error>?
    private var routes: [String: Route] = [:]
    /// `false` when an old relay/Agent put this tunnel in the desktop slot, so a
    /// desktop connect replaces it.
    private(set) var isSeparateChannel = false
    /// Owned by `DesktopSessionHub` and shared by every user of this Agent:
    /// `shutdown()` from a single user is ignored.
    var isShared = false
    private var chatWaiter: CheckedContinuation<Data, Error>?
    private var chatTimeout: Task<Void, Never>?
    private var chatTail: Task<Void, Never>?
    private var healthWaiter: CheckedContinuation<Data, Error>?
    private var healthTimeout: Task<Void, Never>?
    private var healthTail: Task<Void, Never>?
    var onPowerEvent: ((Data) -> Void)?
    /// Hub clears its cache when this shared tunnel dies (half-open WSS, relay drop).
    var onDead: (() -> Void)?
    private var consecutiveReadTimeouts = 0

    init(profile: PairedDesktop) {
        self.profile = profile
        route = profile.deviceID
    }

    /// Requires a live WebSocket task — `sig != nil` alone stays true on half-open sockets
    /// and made session reconnect reuse a dead data channel while desktop still worked.
    var isOpen: Bool { sig?.isOpen == true && sendCipher != nil }
    var hasSessions: Bool { !routes.isEmpty }
    var sessionTicket: String { profile.sessionTicket }

    var label: String { String(localized: "encrypted data channel") }

    func connect(force: Bool = false, channel: Bool = true) async throws {
        let link = try await RE2AgentChatClient.handshake(profile: profile, force: force, channel: channel)
        sig = link.sig
        sendCipher = link.send
        recvCipher = link.recv
        route = link.route
        isSeparateChannel = link.separate
        readTask = Task { [weak self] in await self?.readLoop() }
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.sig?.sendKeepalivePing()
                try? await self.sendInner(RE2.Msg.ping, Data())
            }
        }
    }

    func open(
        id: String,
        request: AgentPTYOpenRequest,
        onReady: @escaping () -> Void,
        onData: @escaping (Data) -> Void,
        onClose: @escaping (String?) -> Void
    ) async throws {
        routes[id] = Route(onReady: onReady, onData: onData, onClose: onClose)
        do {
            try await sendInner(RE2.Msg.openSession, request.payload(sessionID: id))
        } catch {
            routes.removeValue(forKey: id)
            throw error
        }
    }

    func write(id: String, data: Data) async throws {
        for chunk in AgentPTYOpenRequest.chunks(of: data) {
            try await sendInner(RE2.Msg.ptyData, RE2Codec.encodePTY(sessionID: id, data: chunk))
        }
    }

    func resize(id: String, cols: Int, rows: Int) async {
        try? await sendInner(RE2.Msg.resize, RE2Codec.jsonData([
            "session_id": id, "cols": cols, "rows": rows,
        ]))
    }

    func close(id: String) async {
        guard routes.removeValue(forKey: id) != nil else { return }
        try? await sendInner(RE2.Msg.sessionClose, RE2Codec.jsonData([
            "session_id": id, "reason": "client_detach",
        ]))
    }

    func shutdown() {
        guard !isShared else { return }
        teardown()
    }

    /// Close the link for every user.
    func teardown(reason: String? = nil) {
        readTask?.cancel()
        keepaliveTask?.cancel()
        readTask = nil
        keepaliveTask = nil
        consecutiveReadTimeouts = 0
        sig?.close()
        sig = nil
        sendCipher = nil
        recvCipher = nil
        resumeChat(.failure(RE2Error.signaling(reason ?? String(localized: "Not connected to Agent"))))
        resumeHealth(.failure(RE2Error.signaling(reason ?? String(localized: "Not connected to Agent"))))
        let pending = routes
        routes.removeAll()
        if let reason { pending.values.forEach { $0.onClose(reason) } }
        let dead = onDead
        onDead = nil
        dead?()
    }

    /// All AI sessions, paged. Requests are serialized: the Agent answers in order
    /// and pages carry no request id.
    func listChats(projectPath: String? = nil, kind: AgentKind? = nil) async throws -> [RemoteAgentConversation] {
        let previous = chatTail
        let task = Task { @MainActor [weak self] () async throws -> [RemoteAgentConversation] in
            _ = await previous?.value
            guard let self else { throw RE2Error.cancelled }
            return try await self.fetchChatPages(projectPath: projectPath, kind: kind)
        }
        chatTail = Task { _ = await task.result }
        return try await task.value
    }

    func fetchHostHealth() async throws -> HostHealthSnapshot {
        let previous = healthTail
        let task = Task { @MainActor [weak self] () async throws -> HostHealthSnapshot in
            _ = await previous?.value
            guard let self else { throw RE2Error.cancelled }
            return try await self.performHostHealthRequest()
        }
        healthTail = Task { _ = await task.result }
        return try await task.value
    }

    private func performHostHealthRequest() async throws -> HostHealthSnapshot {
        guard isOpen else { throw RE2Error.signaling(String(localized: "Not connected to Agent")) }
        let data: Data = try await withCheckedThrowingContinuation { cont in
            healthWaiter = cont
            healthTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled else { return }
                self?.resumeHealth(.failure(RE2Error.signaling(String(localized: "Timed out waiting for host health"))))
            }
            Task { [weak self] in
                do {
                    try await self?.sendInner(RE2.Msg.hostHealth, RE2Codec.jsonData(["action": "get", "health_v": 1]))
                } catch {
                    self?.resumeHealth(.failure(error))
                }
            }
        }
        return try HostHealthSnapshot.decode(data)
    }

    private func fetchChatPages(projectPath: String?, kind: AgentKind?) async throws -> [RemoteAgentConversation] {
        var offset = 0
        var all: [RemoteAgentConversation] = []
        var seen = Set<String>()
        for _ in 0..<256 {
            var req: [String: Any] = ["action": "list", "offset": offset]
            if let projectPath, !projectPath.isEmpty { req["project_path"] = projectPath }
            if let kind { req["kind"] = kind.rawValue }
            let page = try RE2AgentChatClient.parseList(
                try await chatRequest(RE2Codec.jsonData(req), timeout: 20)
            )
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

    private func chatRequest(_ body: Data, timeout: TimeInterval) async throws -> Data {
        guard isOpen else { throw RE2Error.signaling(String(localized: "Not connected to Agent")) }
        return try await withCheckedThrowingContinuation { cont in
            // Waiter first: the reply may be read while the send is still suspended.
            chatWaiter = cont
            chatTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.resumeChat(.failure(RE2Error.signaling(String(localized: "Timed out waiting for AI session list"))))
            }
            Task { [weak self] in
                do {
                    try await self?.sendInner(RE2.Msg.agentChatList, body)
                } catch {
                    self?.resumeChat(.failure(error))
                }
            }
        }
    }

    private func resumeChat(_ result: Result<Data, Error>) {
        guard let waiter = chatWaiter else { return }
        chatWaiter = nil
        chatTimeout?.cancel()
        chatTimeout = nil
        waiter.resume(with: result)
    }

    private func resumeHealth(_ result: Result<Data, Error>) {
        guard let waiter = healthWaiter else { return }
        healthWaiter = nil
        healthTimeout?.cancel()
        healthTimeout = nil
        waiter.resume(with: result)
    }

    private func sendInner(_ mt: UInt8, _ body: Data) async throws {
        let previous = sendTail
        let task = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self, let sig = self.sig, let cipher = self.sendCipher else {
                throw RE2Error.signaling(String(localized: "Not connected to Agent"))
            }
            let ct = try cipher.encrypt(plaintext: RE2Codec.encodeInner(msgType: mt, body: body))
            try await sig.writeFrame(RE2Frame(type: RE2.OuterType.tunnel, routeID: self.route, payload: ct))
        }
        sendTail = task
        do {
            try await task.value
        } catch {
            // Half-open send failure must invalidate the shared tunnel so the next
            // session open rebinds instead of spinning on "Opening encrypted data channel…".
            teardown(reason: error.localizedDescription)
            throw error
        }
    }

    private func readLoop() async {
        while !Task.isCancelled {
            guard let sig else { return }
            let frame: RE2Frame
            do {
                frame = try await sig.readFrame(timeout: 30)
            } catch {
                if Task.isCancelled { return }
                if case RE2Error.signaling(let m) = error, m == "frame timeout" {
                    consecutiveReadTimeouts += 1
                    // ~2 min of silence on a half-open WS: drop so Hub will BIND again.
                    if consecutiveReadTimeouts >= 4 {
                        teardown(reason: String(localized: "Data channel timed out"))
                        return
                    }
                    continue
                }
                teardown(reason: error.localizedDescription)
                return
            }
            consecutiveReadTimeouts = 0
            switch frame.type {
            case RE2.OuterType.tunnel:
                guard let cipher = recvCipher,
                      let plain = try? cipher.decrypt(ciphertext: frame.payload),
                      let (mt, body) = try? RE2Codec.decodeInner(plain) else { continue }
                handleInner(mt, body)
            case RE2.OuterType.error:
                let err = RE2AgentChatClient.relayError(frame.payload, fallback: "relay error")
                teardown(reason: err.errorDescription ?? "relay error")
                return
            default:
                continue
            }
        }
    }

    private func handleInner(_ mt: UInt8, _ body: Data) {
        switch mt {
        case RE2.Msg.sessionReady:
            let sid = RE2Codec.jsonObject(body)["session_id"] as? String ?? ""
            guard var route = routes[sid] else { return }
            route.ready = true
            routes[sid] = route
            route.onReady()
        case RE2.Msg.ptyData:
            guard let (sid, data) = RE2Codec.decodePTY(body) else { return }
            routes[sid]?.onData(data)
        case RE2.Msg.sessionClose:
            let obj = RE2Codec.jsonObject(body)
            let sid = obj["session_id"] as? String ?? ""
            routes.removeValue(forKey: sid)?.onClose(obj["reason"] as? String)
        case RE2.Msg.agentChatList:
            resumeChat(.success(body))
        case RE2.Msg.hostHealth:
            resumeHealth(.success(body))
        case RE2.Msg.powerEvent:
            onPowerEvent?(body)
        case RE2.Msg.appError:
            let obj = RE2Codec.jsonObject(body)
            let message = obj["message"] as? String ?? "session open failed"
            guard (obj["code"] as? String) == "session_open_failed" else {
                resumeChat(.failure(RE2Error.signaling(message)))
                return
            }
            for (id, route) in routes where !route.ready {
                routes.removeValue(forKey: id)
                route.onClose(message)
            }
        default:
            break
        }
    }
}

/// Builds the Agent-side launch of an AI CLI inside a persistent GNU screen,
/// so detaching (background, network change, desktop reopen) never kills the AI.
enum DesktopAgentLaunch {
    static func ptySessionID(for chat: DesktopAgentChat) -> String {
        "koko-ai-" + chat.id.uuidString.prefix(8).lowercased()
    }

    static let stageReadyMarker = Data("KOKO_STAGE_READY\n".utf8)

    /// The open request must fit one REUDP datagram (1200 B plaintext), so it only
    /// carries a raw-mode loader; the launch script follows as PTY bytes.
    static func request(
        chat: DesktopAgentChat,
        mode: RemoteBootstrap.LaunchMode,
        cols: Int,
        rows: Int
    ) -> (open: AgentPTYOpenRequest, script: Data) {
        let script = Data(attachScript(chat: chat, mode: mode).utf8)
        let loader = "stty raw -echo; printf 'KOKO_STAGE_READY\\n'; S=\"$(head -c \(script.count))\"; stty sane; eval \"$S\""
        return (AgentPTYOpenRequest(cmd: ["/bin/bash", "-c", loader], cols: cols, rows: rows), script)
    }

    static func terminateRequest(chat: DesktopAgentChat) -> AgentPTYOpenRequest {
        let name = q(chat.screenName)
        return AgentPTYOpenRequest(
            cmd: ["/bin/bash", "-c", "screen -S \(name) -X quit >/dev/null 2>&1; exit 0"],
            cols: 80,
            rows: 24
        )
    }

    private static func attachScript(chat: DesktopAgentChat, mode: RemoteBootstrap.LaunchMode) -> String {
        if chat.mirrorsIDEChat && mode == .preferExisting {
            return chat.agentKind == .cursor ? ideMirrorScript(chat: chat) : clientMirrorScript(chat: chat)
        }
        let name = q(chat.screenName)
        let cwd = q(chat.cwd ?? "")
        let quit = mode == .forceNew ? "screen -S \(name) -X quit >/dev/null 2>&1\n" : ""
        let wake = ensureClientAppScript(chat)
        return """
        export LANG="${LANG:-en_US.UTF-8}" TERM=xterm-256color
        LOGIN_PATH="$("${SHELL:-/bin/zsh}" -lic 'printf "__KOKO_PATH__%s\\n" "$PATH"' 2>/dev/null | sed -n 's/^__KOKO_PATH__//p' | tail -n 1)"
        export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:${LOGIN_PATH:+$LOGIN_PATH:}$PATH"
        \(wake)\(quit)if screen -ls 2>/dev/null | awk '{print $1}' | sed 's/^[0-9]*[.]//' | grep -Fxq \(name); then exec screen -x \(name); fi
        cd \(cwd) 2>/dev/null || cd "$HOME"
        exec screen -S \(name) -h 10000 /bin/bash -c \(q(innerScript(chat: chat, mode: mode)))
        """
    }

    /// Claude / Codex / Gemini client chats: if the desktop app is not running,
    /// start it first (same cold-start as Cursor), then resume in the terminal.
    /// IDE-extension sessions wake Cursor; standalone apps wake themselves.
    private static func ensureClientAppScript(_ chat: DesktopAgentChat) -> String {
        guard chat.isClientSession, !chat.mirrorsIDEChat else { return "" }
        let apps = clientAppsToLaunch(chat)
        guard !apps.isEmpty else { return "" }
        let quoted = apps.map { q($0) }.joined(separator: " ")
        return """
        for app in \(quoted); do
          if [ -d "/Applications/${app}.app" ] || [ -d "$HOME/Applications/${app}.app" ]; then
            if pgrep -f "/${app}.app/Contents/MacOS/" >/dev/null 2>&1; then
              break
            fi
            open -ga "$app" 2>/dev/null || continue
            i=0
            while [ "$i" -lt 40 ]; do
              pgrep -f "/${app}.app/Contents/MacOS/" >/dev/null 2>&1 && break
              sleep 0.5
              i=$((i+1))
            done
            break
          fi
        done

        """
    }

    private static func clientAppsToLaunch(_ chat: DesktopAgentChat) -> [String] {
        let name = (chat.clientName ?? "").lowercased()
        let inIDE = name.contains("ide") || name.contains("extension")
            || name.contains("vscode") || name.contains("code assist")
        if inIDE {
            return ["Cursor", "Visual Studio Code"]
        }
        switch chat.agentKind {
        case .claude: return ["Claude", "Cursor"]
        case .codex: return ["Codex", "Cursor"]
        case .gemini: return ["Gemini", "Cursor"]
        case .trae: return ["Trae", "Trae CN", "Cursor"]
        case .qoder: return ["Qoder", "Cursor"]
        case .codebuddy: return ["CodeBuddy", "Cursor"]
        case .cursor: return ["Cursor"]
        }
    }

    /// Agents that ship `client-mirror` export RE_AGENT_BIN into their PTYs.
    private static func clientMirrorScript(chat: DesktopAgentChat) -> String {
        let lang = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
        let outdated = String(localized: "The RunEverything Agent on this computer is too old to sync IDE chats. Update the Agent, then choose Reconnect.")
        let folder = chat.cwd ?? ""
        let client = chat.clientName ?? ""
        let kind = chat.agentKind.rawValue
        var args = "--lang \(lang)"
        if !folder.isEmpty { args += " --folder \(q(folder))" }
        if !client.isEmpty { args += " --client \(q(client))" }
        args += " \(kind) \(q(chat.chatId))"
        return """
        export LANG="${LANG:-en_US.UTF-8}" TERM=xterm-256color
        if [ -n "$RE_AGENT_BIN" ] && [ -x "$RE_AGENT_BIN" ]; then
          exec "$RE_AGENT_BIN" client-mirror \(args)
        fi
        echo \(q("[KoKo] " + outdated))
        exec "${SHELL:-/bin/zsh}" -l
        """
    }

    /// Agents that ship `ide-mirror` export RE_AGENT_BIN into their PTYs; older ones cannot mirror IDE chats.
    private static func ideMirrorScript(chat: DesktopAgentChat) -> String {
        let lang = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
        let outdated = String(localized: "The RunEverything Agent on this computer is too old to sync IDE chats. Update the Agent, then choose Reconnect.")
        let folder = chat.cwd ?? ""
        let target: String = {
            if chat.chatId.isEmpty {
                return "--new \(q(folder)) cursor"
            }
            if folder.isEmpty {
                return "cursor \(q(chat.chatId))"
            }
            return "--folder \(q(folder)) cursor \(q(chat.chatId))"
        }()
        return """
        export LANG="${LANG:-en_US.UTF-8}" TERM=xterm-256color
        if [ -n "$RE_AGENT_BIN" ] && [ -x "$RE_AGENT_BIN" ]; then
          exec "$RE_AGENT_BIN" ide-mirror --lang \(lang) \(target)
        fi
        echo \(q("[KoKo] " + outdated))
        exec "${SHELL:-/bin/zsh}" -l
        """
    }

    private static func innerScript(chat: DesktopAgentChat, mode: RemoteBootstrap.LaunchMode) -> String {
        let kind = chat.agentKind
        let candidates = binaryCandidates(kind).joined(separator: " ")
        let resume = mode == .preferExisting && chat.resumableInTerminal
            ? resumeArgs(kind: kind, chatId: chat.chatId)
            : ""
        return """
        BIN=""
        for c in \(candidates); do
          [ -n "$BIN" ] && break
          if [ -x "$c" ] && [ ! -d "$c" ]; then BIN="$c"; continue; fi
          p="$(command -v "$c" 2>/dev/null)"
          if [ -n "$p" ] && [ -x "$p" ]; then BIN="$p"; fi
        done
        if [ -n "$BIN" ]; then
          "$BIN" \(resume)
          status=$?
          echo
          echo "[KoKo] \(kind.displayName) exited ($status)."
        else
          echo "[KoKo] \(kind.displayName) CLI not found on this computer. Install it here, then choose Reconnect."
        fi
        exec "${SHELL:-/bin/zsh}" -l
        """
    }

    /// PATH first, then CLIs bundled with desktop / IDE clients that share the same session store.
    private static func binaryCandidates(_ kind: AgentKind) -> [String] {
        switch kind {
        case .cursor:
            return ["\"$HOME/.local/bin/agent\"", "\"$HOME/.local/bin/cursor-agent\"", "cursor-agent", "agent"]
        case .claude:
            return [
                "claude",
                "\"$HOME/.claude/local/claude\"",
                "\"$HOME\"/.cursor/extensions/anthropic.claude-code-*/resources/native-binary/claude",
                "\"$HOME\"/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude",
            ]
        case .codex:
            return [
                "codex",
                "/Applications/Codex.app/Contents/Resources/codex",
                "\"$HOME\"/.cursor/extensions/openai.chatgpt-*/bin/*/codex",
                "\"$HOME\"/.vscode/extensions/openai.chatgpt-*/bin/*/codex",
            ]
        case .gemini:
            return ["gemini"]
        case .trae:
            return ["traex", "traecli", "\"$HOME/.local/bin/traex\"", "\"$HOME/.local/bin/traecli\""]
        case .qoder:
            return ["qoder", "\"$HOME/.local/bin/qoder\""]
        case .codebuddy:
            return ["codebuddy", "\"$HOME/.local/bin/codebuddy\""]
        }
    }

    private static func resumeArgs(kind: AgentKind, chatId: String) -> String {
        let id = q(chatId)
        switch kind {
        case .cursor: return "--resume=\(id)"
        case .claude: return "--resume \(id)"
        case .codex: return "resume \(id)"
        case .gemini: return "--resume \(id)"
        case .trae: return "resume \(id)"
        case .qoder: return "-r \(id)"
        case .codebuddy: return "--resume \(id)"
        }
    }

    private static func q(_ value: String) -> String {
        RemoteBootstrap.shellEscape(value)
    }
}

/// Live state of a mirrored Cursor IDE chat, published in-band by the Agent's `ide-mirror`
/// as OSC 7788 (base64 JSON). Phone actions go back as OSC 7789 on the PTY input.
struct IDEChatState: Codable, Equatable {
    struct ModelParameterValue: Codable, Equatable, Identifiable, Hashable {
        var id: String
        var name: String
    }
    struct ModelParameter: Codable, Equatable, Identifiable, Hashable {
        var id: String
        var name: String
        var tooltip: String?
        var kind: String
        var selected: String?
        var values: [ModelParameterValue]

        var selectedName: String {
            values.first(where: { $0.id == selected })?.name ?? selected ?? ""
        }
    }
    struct Option: Codable, Equatable, Identifiable, Hashable {
        var id: String
        var name: String
        var parameters: [ModelParameter]?
    }
    struct File: Codable, Equatable, Identifiable, Hashable {
        var path: String
        var new: Bool
        var id: String { path }
    }
    struct Bridge: Codable, Equatable {
        var ready: Bool
        var needsReload: Bool
    }
    struct SubChat: Codable, Equatable, Identifiable, Hashable {
        var composerId: String
        var name: String
        var id: String { composerId }
    }
    struct Queued: Codable, Equatable, Identifiable, Hashable {
        var id: String
        var text: String
    }

    var composerId: String
    var name: String
    var cwd: String
    /// `cursor-ide`, `claude-client`, `codex-client`, `gemini-client`.
    var kind: String? = nil
    var mode: String
    var modes: [Option]?
    var model: String
    var models: [Option]?
    var contextPercent: Double
    var linesAdded: Int
    var linesRemoved: Int
    var files: [File]?
    /// Cursor's Files chip count (filesChangedCount). May be > files.count when
    /// the path list is still catching up.
    var filesChangedCount: Int?
    var subChats: [SubChat]?
    var generating: Bool?
    /// True while Cursor is still showing Keep All / Undo All for unaccepted edits.
    var pendingReview: Bool?
    var queued: [Queued]?
    /// Set when a queue edit, delete, or send-now did not reach Cursor.
    var actionError: String?
    var bridge: Bridge
    /// Non-zero when the mirror also publishes structured messages (OSC 7790).
    var chat: Int?

    var modeName: String { modes?.first(where: { $0.id == mode })?.name ?? mode }
    var modelName: String { models?.first(where: { $0.id == model })?.name ?? model }
    var supportsNativeChat: Bool { (chat ?? 0) > 0 }

    static func actionBytes(op: String, id: String? = nil, text: String? = nil, bubbleId: String? = nil) -> Data {
        var obj: [String: Any] = ["op": op]
        if let id { obj["id"] = id }
        if let text { obj["text"] = text }
        if let bubbleId { obj["bubbleId"] = bubbleId }
        return actionBytes(obj)
    }

    static func actionBytes(_ obj: [String: Any]) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return Data(("\u{1b}]7789;" + json.base64EncodedString() + "\u{07}").utf8)
    }
}

/// One conversation row of a mirrored Cursor IDE chat, published as OSC 7790.
struct IDEChatMessage: Codable, Equatable, Identifiable {
    enum Role: String, Codable {
        case user, assistant, thought, tool, question
        /// Cursor's own injected turn (background task finished); text is the task title.
        case notice

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Role(rawValue: raw) ?? .assistant
        }
    }
    struct Tool: Codable, Equatable {
        struct DiffLine: Codable, Equatable {
            var kind: String
            var oldLine: Int?
            var newLine: Int?
            var text: String

            private enum CodingKeys: String, CodingKey {
                case kind, oldLine = "old", newLine = "new", text
            }
        }
        struct Diff: Codable, Equatable {
            var path: String
            var language: String?
            var additions: Int
            var deletions: Int
            var truncated: Bool?
            var binary: Bool?
            var lines: [DiffLine]
        }

        var name: String
        var label: String
        var summary: String?
        var status: String?
        /// The tool's own one-line description (shell commandDescription).
        var title: String?
        /// Tail of a shell command's output.
        var output: String?
        var outputBytes: Int?
        var outputTruncated: Bool?
        var toolCallId: String?
        var userDecision: String?
        var diff: Diff?

        var isRunning: Bool {
            ["loading", "pending", "running", "in_progress", "streaming"].contains(status ?? "")
        }
        var isFailed: Bool { ["error", "failed"].contains(status ?? "") }
        var isPendingApproval: Bool {
            status == "pending" && (userDecision?.isEmpty ?? true)
        }
    }
    struct Option: Codable, Equatable, Identifiable, Hashable {
        var id: String
        var label: String
    }
    struct QuestionItem: Codable, Equatable, Identifiable {
        var id: String
        var prompt: String
        var allowMultiple: Bool?
        var options: [Option]
    }
    struct Answer: Codable, Equatable {
        var questionId: String
        var selectedOptionIds: [String]
        var freeformText: String?
    }
    struct Question: Codable, Equatable {
        var toolCallId: String
        var title: String?
        /// pending | answered (from this phone) | submitted | cancelled
        var status: String
        var questions: [QuestionItem]
        var answers: [Answer]?

        var isOpen: Bool { status == "pending" }
    }

    var idx: Int
    var bubbleId: String
    var role: Role
    var text: String?
    var tool: Tool?
    var question: Question?
    /// Thinking time for `.thought` rows.
    var durationMs: Int?
    /// ISO-8601 timestamp from Cursor (footer “20m ago”).
    var createdAt: String?

    var id: Int { idx }

    private enum CodingKeys: String, CodingKey {
        case idx, bubbleId = "id", role, text, tool, question, durationMs, createdAt
    }
}

struct IDEChatFrame: Codable {
    var reset: Bool?
    var composerId: String?
    var messages: [IDEChatMessage]?
}

struct IDEFilePreviewFrame: Codable, Equatable {
    var path: String
    var diff: IDEChatMessage.Tool.Diff?
    var error: String?
}

/// Splits the mirror's OSC 7788 (state) and OSC 7790 (chat) frames out of the PTY byte
/// stream; frames may straddle chunks.
struct IDEStateExtractor {
    private static let open = Data("\u{1b}]77".utf8)
    private static let stateTag = Data("88;".utf8)
    private static let chatTag = Data("90;".utf8)
    private static let fileTag = Data("91;".utf8)
    private static let bel: UInt8 = 0x07
    private var carry = Data()

    struct Result {
        var output = Data()
        var states: [IDEChatState] = []
        var chats: [IDEChatFrame] = []
        var filePreviews: [IDEFilePreviewFrame] = []
    }

    mutating func process(_ chunk: Data) -> Result {
        var data = carry + chunk
        carry = Data()
        var result = Result()
        var searchFrom = data.startIndex
        while let start = data[searchFrom...].range(of: Self.open) {
            let tagStart = start.upperBound
            guard data.distance(from: tagStart, to: data.endIndex) >= Self.stateTag.count else {
                result.output.append(data[data.startIndex..<start.lowerBound])
                carry = Data(data[start.lowerBound...])
                return result
            }
            let tag = data[tagStart..<data.index(tagStart, offsetBy: Self.stateTag.count)]
            let isState = tag == Self.stateTag
            let isChat = tag == Self.chatTag
            let isFile = tag == Self.fileTag
            guard isState || isChat || isFile else {
                searchFrom = tagStart
                continue
            }
            result.output.append(data[data.startIndex..<start.lowerBound])
            let bodyStart = data.index(tagStart, offsetBy: Self.stateTag.count)
            guard let end = data[bodyStart...].firstIndex(of: Self.bel) else {
                carry = Data(data[start.lowerBound...])
                return result
            }
            if let raw = Data(base64Encoded: Data(data[bodyStart..<end])) {
                if isState, let state = try? JSONDecoder().decode(IDEChatState.self, from: raw) {
                    result.states.append(state)
                } else if isChat, let frame = try? JSONDecoder().decode(IDEChatFrame.self, from: raw) {
                    result.chats.append(frame)
                } else if isFile, let preview = try? JSONDecoder().decode(IDEFilePreviewFrame.self, from: raw) {
                    result.filePreviews.append(preview)
                }
            }
            data = Data(data[data.index(after: end)...])
            searchFrom = data.startIndex
        }
        // Hold back a tail that could be the beginning of a frame marker.
        var keep = 0
        for n in stride(from: min(Self.open.count, data.count), to: 0, by: -1)
        where data.suffix(n) == Self.open.prefix(n) {
            keep = n
            break
        }
        result.output.append(data.prefix(data.count - keep))
        carry = Data(data.suffix(keep))
        return result
    }
}
