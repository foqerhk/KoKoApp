import Foundation

/// Short-lived RE2 WSS client for AI session inventory.
/// Does **not** open desktop, video, mouse, or PTY — data only.
enum RE2AgentChatClient {
    /// Fetch Cursor / Claude / Codex / Gemini chats from a paired Agent.
    static func listChats(
        profile: PairedDesktop,
        projectPath: String? = nil,
        kind: AgentKind? = nil
    ) async throws -> [RemoteAgentConversation] {
        let deviceID = profile.deviceID
        let (sig, send, recv) = try await handshake(profile: profile)
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
            try await sig.writeFrame(RE2Frame(type: RE2.OuterType.tunnel, routeID: deviceID, payload: ct))

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

    /// BIND with the session ticket and run Noise XX+PSK over WSS (no PairRedeem, no desktop).
    static func handshake(
        profile: PairedDesktop
    ) async throws -> (RE2SignalingClient, NoiseCipherState, NoiseCipherState) {
        guard profile.canReconnect else {
            throw RE2Error.signaling(String(localized: "Re-pair required — scan a fresh Agent QR."))
        }
        let deviceID = profile.deviceID
        let sig = RE2SignalingClient()
        try await sig.connect(relay: profile.relayURL)
        do {
            let (send, recv) = try await bindAndHandshake(sig: sig, profile: profile, deviceID: deviceID)
            return (sig, send, recv)
        } catch {
            sig.close()
            throw error
        }
    }

    private static func bindAndHandshake(
        sig: RE2SignalingClient,
        profile: PairedDesktop,
        deviceID: String
    ) async throws -> (NoiseCipherState, NoiseCipherState) {
        // BIND with session ticket (no PairRedeem).
        try await sig.writeFrame(RE2Frame(
            type: RE2.OuterType.bind,
            routeID: deviceID,
            payload: RE2Codec.jsonData([
                "device_id": deviceID,
                "session_ticket": profile.sessionTicket,
            ])
        ))
        let bindFrame = try await readSkippingPing(sig)
        if bindFrame.type == RE2.OuterType.error {
            throw RE2Error.fromRelayError(
                code: RE2Codec.jsonObject(bindFrame.payload)["code"] as? String ?? "",
                message: RE2Codec.jsonObject(bindFrame.payload)["message"] as? String ?? "bind failed"
            )
        }
        guard bindFrame.type == RE2.OuterType.bindOK else {
            throw RE2Error.signaling("unexpected bind reply")
        }

        // Noise XX+PSK over WSS.
        let psk = RE2.derivePSK(pairingToken: profile.pairingToken)
        let hs = try NoiseXXPSK3(psk: psk)
        let msg1 = try hs.writeMessage1()
        try await sig.writeFrame(RE2Frame(type: RE2.OuterType.noise, routeID: deviceID, payload: msg1))
        var msg2: Data?
        for _ in 0..<8 {
            let f = try await readSkippingPing(sig)
            if f.type == RE2.OuterType.error {
                throw RE2Error.fromRelayError(
                    code: RE2Codec.jsonObject(f.payload)["code"] as? String ?? "",
                    message: RE2Codec.jsonObject(f.payload)["message"] as? String ?? "noise failed"
                )
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
        try await sig.writeFrame(RE2Frame(type: RE2.OuterType.noise, routeID: deviceID, payload: msg3))
        return (send, recv)
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

    private struct AgentChatPage {
        var rows: [RemoteAgentConversation]
        var nextOffset: Int
        var hasMore: Bool
    }

    private static func parseList(_ body: Data) throws -> AgentChatPage {
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

/// Shares the streaming remote-desktop tunnel (Agent allows one Noise peer).
@MainActor
final class DesktopTunnelPTYTransport: AgentPTYTransport {
    private let session: RE2DesktopSession

    init(session: RE2DesktopSession) {
        self.session = session
    }

    var label: String { String(localized: "remote desktop tunnel") }

    func open(
        id: String,
        request: AgentPTYOpenRequest,
        onReady: @escaping () -> Void,
        onData: @escaping (Data) -> Void,
        onClose: @escaping (String?) -> Void
    ) async throws {
        try await session.openAgentPTY(id: id, request: request, onReady: onReady, onData: onData, onClose: onClose)
    }

    func write(id: String, data: Data) async throws {
        try await session.writeAgentPTY(id: id, data: data)
    }

    func resize(id: String, cols: Int, rows: Int) async {
        await session.resizeAgentPTY(id: id, cols: cols, rows: rows)
    }

    func close(id: String) async {
        await session.closeAgentPTY(id: id)
    }

    func shutdown() {}
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
    private var readTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    /// Noise nonces must reach the Agent in encryption order.
    private var sendTail: Task<Void, Error>?
    private var routes: [String: Route] = [:]

    init(profile: PairedDesktop) {
        self.profile = profile
    }

    var label: String { String(localized: "encrypted data channel") }

    func connect() async throws {
        let (sig, send, recv) = try await RE2AgentChatClient.handshake(profile: profile)
        self.sig = sig
        sendCipher = send
        recvCipher = recv
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
        readTask?.cancel()
        keepaliveTask?.cancel()
        readTask = nil
        keepaliveTask = nil
        sig?.close()
        sig = nil
        sendCipher = nil
        recvCipher = nil
        routes.removeAll()
    }

    private func sendInner(_ mt: UInt8, _ body: Data) async throws {
        let previous = sendTail
        let task = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self, let sig = self.sig, let cipher = self.sendCipher else {
                throw RE2Error.signaling(String(localized: "Not connected to Agent"))
            }
            let ct = try cipher.encrypt(plaintext: RE2Codec.encodeInner(msgType: mt, body: body))
            try await sig.writeFrame(RE2Frame(type: RE2.OuterType.tunnel, routeID: self.profile.deviceID, payload: ct))
        }
        sendTail = task
        try await task.value
    }

    private func readLoop() async {
        while !Task.isCancelled {
            guard let sig else { return }
            let frame: RE2Frame
            do {
                frame = try await sig.readFrame(timeout: 30)
            } catch {
                if Task.isCancelled { return }
                if case RE2Error.signaling(let m) = error, m == "frame timeout" { continue }
                failAll(error.localizedDescription)
                return
            }
            switch frame.type {
            case RE2.OuterType.tunnel:
                guard let cipher = recvCipher,
                      let plain = try? cipher.decrypt(ciphertext: frame.payload),
                      let (mt, body) = try? RE2Codec.decodeInner(plain) else { continue }
                handleInner(mt, body)
            case RE2.OuterType.error:
                let obj = RE2Codec.jsonObject(frame.payload)
                failAll(obj["message"] as? String ?? obj["code"] as? String ?? "relay error")
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
        case RE2.Msg.appError:
            let obj = RE2Codec.jsonObject(body)
            guard (obj["code"] as? String) == "session_open_failed" else { return }
            let message = obj["message"] as? String ?? "session open failed"
            for (id, route) in routes where !route.ready {
                routes.removeValue(forKey: id)
                route.onClose(message)
            }
        default:
            break
        }
    }

    private func failAll(_ reason: String) {
        let pending = routes
        routes.removeAll()
        pending.values.forEach { $0.onClose(reason) }
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
            return ideMirrorScript(chat: chat)
        }
        let name = q(chat.screenName)
        let cwd = q(chat.cwd ?? "")
        let quit = mode == .forceNew ? "screen -S \(name) -X quit >/dev/null 2>&1\n" : ""
        return """
        export LANG="${LANG:-en_US.UTF-8}" TERM=xterm-256color
        LOGIN_PATH="$("${SHELL:-/bin/zsh}" -lic 'printf "__KOKO_PATH__%s\\n" "$PATH"' 2>/dev/null | sed -n 's/^__KOKO_PATH__//p' | tail -n 1)"
        export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:${LOGIN_PATH:+$LOGIN_PATH:}$PATH"
        \(quit)if screen -ls 2>/dev/null | awk '{print $1}' | sed 's/^[0-9]*[.]//' | grep -Fxq \(name); then exec screen -x \(name); fi
        cd \(cwd) 2>/dev/null || cd "$HOME"
        exec screen -S \(name) -h 10000 /bin/bash -c \(q(innerScript(chat: chat, mode: mode)))
        """
    }

    /// Agents that ship `ide-mirror` export RE_AGENT_BIN into their PTYs; older ones cannot mirror IDE chats.
    private static func ideMirrorScript(chat: DesktopAgentChat) -> String {
        let lang = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
        let outdated = String(localized: "The RunEverything Agent on this computer is too old to sync IDE chats. Update the Agent, then choose Reconnect.")
        let target = chat.chatId.isEmpty
            ? "--new \(q(chat.cwd ?? "")) cursor"
            : "cursor \(q(chat.chatId))"
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
        }
    }

    private static func resumeArgs(kind: AgentKind, chatId: String) -> String {
        let id = q(chatId)
        switch kind {
        case .cursor: return "--resume=\(id)"
        case .claude: return "--resume \(id)"
        case .codex: return "resume \(id)"
        case .gemini: return "--resume \(id)"
        }
    }

    private static func q(_ value: String) -> String {
        RemoteBootstrap.shellEscape(value)
    }
}

/// Live state of a mirrored Cursor IDE chat, published in-band by the Agent's `ide-mirror`
/// as OSC 7788 (base64 JSON). Phone actions go back as OSC 7789 on the PTY input.
struct IDEChatState: Codable, Equatable {
    struct Option: Codable, Equatable, Identifiable, Hashable {
        var id: String
        var name: String
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

    var composerId: String
    var name: String
    var cwd: String
    var mode: String
    var modes: [Option]?
    var model: String
    var models: [Option]?
    var contextPercent: Double
    var linesAdded: Int
    var linesRemoved: Int
    var files: [File]?
    var bridge: Bridge

    var modeName: String { modes?.first(where: { $0.id == mode })?.name ?? mode }
    var modelName: String { models?.first(where: { $0.id == model })?.name ?? model }

    static func actionBytes(op: String, id: String? = nil) -> Data {
        var obj: [String: String] = ["op": op]
        if let id { obj["id"] = id }
        let json = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return Data(("\u{1b}]7789;" + json.base64EncodedString() + "\u{07}").utf8)
    }
}

/// Splits OSC 7788 state frames out of the PTY byte stream; frames may straddle chunks.
struct IDEStateExtractor {
    private static let open = Data("\u{1b}]7788;".utf8)
    private static let bel: UInt8 = 0x07
    private var carry = Data()

    mutating func process(_ chunk: Data) -> (output: Data, states: [IDEChatState]) {
        var data = carry + chunk
        carry = Data()
        var output = Data()
        var states: [IDEChatState] = []
        while let start = data.range(of: Self.open) {
            output.append(data[data.startIndex..<start.lowerBound])
            guard let end = data[start.upperBound...].firstIndex(of: Self.bel) else {
                carry = Data(data[start.lowerBound...])
                return (output, states)
            }
            if let raw = Data(base64Encoded: Data(data[start.upperBound..<end])),
               let state = try? JSONDecoder().decode(IDEChatState.self, from: raw) {
                states.append(state)
            }
            data = Data(data[data.index(after: end)...])
        }
        // Hold back a tail that could be the beginning of a frame marker.
        var keep = 0
        for n in stride(from: min(Self.open.count - 1, data.count), to: 0, by: -1)
        where data.suffix(n) == Self.open.prefix(n) {
            keep = n
            break
        }
        output.append(data.prefix(data.count - keep))
        carry = Data(data.suffix(keep))
        return (output, states)
    }
}
