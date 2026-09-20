import Citadel
import Foundation
import NIO
import NIOSSH

struct RemoteAgentConversation: Equatable, Sendable {
    var agentKind: AgentKind
    var chatId: String
    var title: String
    var cwd: String?
    var createdAt: Date
    var updatedAt: Date
    var screenName: String
    var screenAlive: Bool
}

enum AgentSessionSyncError: LocalizedError {
    case missingCredentials
    case commandFailed(String)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return String(localized: "Host has no password or usable key")
        case .commandFailed(let detail):
            return detail
        case .decodeFailed:
            return String(localized: "Could not parse agent session list from server")
        }
    }
}

/// Lists Cursor / Claude / Codex / Gemini sessions plus live `screen -ls` rows tagged `koko-*`.
enum AgentSessionSync {
    static func listConversations(
        server: ServerProfile,
        keyPair: SSHKeyPair?,
        projectPath: String,
        onHostKeyUnknown: (@Sendable (String) -> Void)? = nil
    ) async throws -> [RemoteAgentConversation] {
        let auth: SSHAuthenticationMethod
        do {
            auth = try SSHAuthBuilder.makeAuthenticationMethod(profile: server, keyPair: keyPair)
        } catch {
            throw AgentSessionSyncError.missingCredentials
        }

        let validator: SSHHostKeyValidator = .custom(
            TOFUHostKeyValidator(expectedFingerprint: server.hostKeyFingerprint) { fingerprint in
                onHostKeyUnknown?(fingerprint)
            }
        )

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: server.host,
                port: server.port,
                authenticationMethod: auth,
                hostKeyValidator: validator,
                reconnect: .never,
                algorithms: .all
            )
        } catch {
            throw AgentSessionSyncError.commandFailed(SSHErrorMapper.message(for: error))
        }
        defer { Task { try? await client.close() } }

        let script = listScript(projectPath: projectPath)
        let scriptB64 = Data(script.utf8).base64EncodedString()
        let command = "echo \(scriptB64) | (base64 -d 2>/dev/null || base64 -D 2>/dev/null || base64 --decode) | python3 - \(shellEscape(projectPath))"
        let outputData: ByteBuffer
        do {
            outputData = try await client.executeCommand(command, mergeStreams: true)
        } catch {
            throw AgentSessionSyncError.commandFailed(SSHErrorMapper.message(for: error))
        }
        let output = outputData.getString(at: outputData.readerIndex, length: outputData.readableBytes) ?? ""
        return try parseJSONList(output)
    }

    @MainActor
    static func apply(
        conversations: [RemoteAgentConversation],
        to store: AppStore,
        serverId: UUID,
        projectId: UUID,
        preferredBindingSessionId: UUID? = nil
    ) {
        let projectSessions = store.sessions.filter {
            $0.serverId == serverId && $0.projectId == projectId
        }
        let otherSessions = store.sessions.filter {
            $0.serverId != serverId || $0.projectId != projectId
        }

        var boundByChatId: [String: TerminalSession] = [:]
        var placeholders: [TerminalSession] = []
        for session in projectSessions {
            if let chatId = session.agentChatId {
                boundByChatId[chatId] = session
            } else {
                placeholders.append(session)
            }
        }

        let dedupedRemotes = dedupeConversations(conversations)
        var merged: [TerminalSession] = []
        var usedPlaceholderIds = Set<UUID>()
        var unmatchedRemotes: [RemoteAgentConversation] = []

        for chat in dedupedRemotes {
            if let existing = boundByChatId[chat.chatId] {
                merged.append(mergeRemote(chat, into: existing))
                continue
            }

            if let placeholder = pickPlaceholder(
                for: chat,
                placeholders: placeholders,
                usedIds: usedPlaceholderIds,
                preferredSessionId: preferredBindingSessionId
            ) {
                usedPlaceholderIds.insert(placeholder.id)
                merged.append(mergeRemote(chat, into: placeholder))
                continue
            }

            unmatchedRemotes.append(chat)
        }

        pairUnmatchedPlaceholders(
            placeholders: placeholders,
            remotes: unmatchedRemotes,
            usedPlaceholderIds: &usedPlaceholderIds,
            merged: &merged,
            preferredSessionId: preferredBindingSessionId
        )

        let stillUnmatchedRemotes = unmatchedRemotes.filter { remote in
            !merged.contains { $0.agentChatId == remote.chatId }
        }
        for chat in stillUnmatchedRemotes {
            guard !merged.contains(where: { $0.agentChatId == chat.chatId }) else { continue }
            merged.append(makeRemoteSession(chat, serverId: serverId, projectId: projectId))
        }

        for placeholder in placeholders where !usedPlaceholderIds.contains(placeholder.id) {
            if shouldKeepUnmatchedPlaceholder(placeholder, merged: merged) {
                merged.append(placeholder)
            }
        }

        store.replaceSessions(otherSessions + merged)
    }

    @MainActor
    static func applyForSession(
        _ session: TerminalSession,
        to store: AppStore,
        server: ServerProfile,
        keyPair: SSHKeyPair?,
        projectPath: String,
        onHostKeyUnknown: (@Sendable (String) -> Void)? = nil
    ) async {
        do {
            let conversations = try await listConversations(
                server: server,
                keyPair: keyPair,
                projectPath: projectPath,
                onHostKeyUnknown: onHostKeyUnknown
            )
            apply(
                conversations: conversations,
                to: store,
                serverId: session.serverId,
                projectId: session.projectId,
                preferredBindingSessionId: session.id
            )
        } catch {
            // Best-effort after connect; list refresh will retry.
        }
    }

    private static func mergeRemote(
        _ chat: RemoteAgentConversation,
        into local: TerminalSession
    ) -> TerminalSession {
        var updated = local
        updated.agentChatId = chat.chatId
        updated.remoteSessionName = chat.screenName
        let latest = max(local.lastConnectedAt ?? chat.updatedAt, chat.updatedAt)
        updated.lastConnectedAt = latest
        return updated
    }

    private static func makeRemoteSession(
        _ chat: RemoteAgentConversation,
        serverId: UUID,
        projectId: UUID
    ) -> TerminalSession {
        let stableId = UUID(uuidString: chat.chatId) ?? UUID()
        return TerminalSession(
            id: stableId,
            serverId: serverId,
            projectId: projectId,
            displayName: chat.title,
            agentKind: chat.agentKind,
            remoteSessionName: chat.screenName,
            agentChatId: chat.chatId,
            createdAt: chat.createdAt,
            lastConnectedAt: chat.updatedAt
        )
    }

    private static func pickPlaceholder(
        for chat: RemoteAgentConversation,
        placeholders: [TerminalSession],
        usedIds: Set<UUID>,
        preferredSessionId: UUID?
    ) -> TerminalSession? {
        let candidates = placeholders.filter { placeholder in
            !usedIds.contains(placeholder.id) && matchesPlaceholder(placeholder, remote: chat)
        }
        if let preferredSessionId,
           let preferred = candidates.first(where: { $0.id == preferredSessionId }) {
            return preferred
        }
        return candidates.max { lhs, rhs in
            (lhs.lastConnectedAt ?? lhs.createdAt) < (rhs.lastConnectedAt ?? rhs.createdAt)
        }
    }

    private static func pairUnmatchedPlaceholders(
        placeholders: [TerminalSession],
        remotes: [RemoteAgentConversation],
        usedPlaceholderIds: inout Set<UUID>,
        merged: inout [TerminalSession],
        preferredSessionId: UUID?
    ) {
        for kind in AgentKind.allCases {
            let localCandidates = placeholders
                .filter { $0.agentKind == kind && !usedPlaceholderIds.contains($0.id) }
                .sorted { ($0.lastConnectedAt ?? $0.createdAt) > ($1.lastConnectedAt ?? $1.createdAt) }
            let remoteCandidates = remotes
                .filter { $0.agentKind == kind }
                .filter { remote in !merged.contains { $0.agentChatId == remote.chatId } }
                .sorted { $0.updatedAt > $1.updatedAt }

            guard !localCandidates.isEmpty, !remoteCandidates.isEmpty else { continue }

            var locals = localCandidates
            if let preferredSessionId,
               let index = locals.firstIndex(where: { $0.id == preferredSessionId }) {
                let preferred = locals.remove(at: index)
                locals.insert(preferred, at: 0)
            }

            for (local, remote) in zip(locals, remoteCandidates) {
                usedPlaceholderIds.insert(local.id)
                merged.append(mergeRemote(remote, into: local))
            }
        }
    }

    private static func shouldKeepUnmatchedPlaceholder(
        _ placeholder: TerminalSession,
        merged: [TerminalSession]
    ) -> Bool {
        if placeholder.lastConnectedAt == nil {
            return true
        }
        let hasSameKindRemote = merged.contains {
            $0.agentKind == placeholder.agentKind && $0.agentChatId != nil
        }
        return !hasSameKindRemote
    }

    private static func matchesPlaceholder(
        _ local: TerminalSession,
        remote: RemoteAgentConversation
    ) -> Bool {
        guard local.agentKind == remote.agentKind else { return false }

        if local.remoteSessionName == remote.screenName {
            return true
        }

        let remoteId = remote.chatId.lowercased()
        let localUUID = local.id.uuidString.lowercased()
        if localUUID.hasPrefix(remoteId) {
            return true
        }
        if remoteId.hasPrefix(String(localUUID.prefix(24))) {
            return true
        }
        if local.remoteSessionName.lowercased().hasSuffix(remoteId) {
            return true
        }

        let expectedScreen = TerminalSession.defaultScreenName(
            kind: remote.agentKind,
            sessionKey: local.id.uuidString
        )
        return remote.screenName == expectedScreen
    }

    private static func dedupeConversations(
        _ conversations: [RemoteAgentConversation]
    ) -> [RemoteAgentConversation] {
        var bestByScreen: [String: RemoteAgentConversation] = [:]
        for chat in conversations {
            let key = "\(chat.agentKind.rawValue):\(chat.screenName)"
            if let existing = bestByScreen[key] {
                bestByScreen[key] = preferredConversation(existing, chat)
            } else {
                bestByScreen[key] = chat
            }
        }
        return bestByScreen.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func preferredConversation(
        _ lhs: RemoteAgentConversation,
        _ rhs: RemoteAgentConversation
    ) -> RemoteAgentConversation {
        if lhs.screenAlive != rhs.screenAlive {
            return lhs.screenAlive ? lhs : rhs
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt ? lhs : rhs
        }
        return lhs.title.count >= rhs.title.count ? lhs : rhs
    }

    private static func parseJSONList(_ output: String) throws -> [RemoteAgentConversation] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonLine: String = {
            if let start = trimmed.firstIndex(of: "["), let end = trimmed.lastIndex(of: "]"), start <= end {
                return String(trimmed[start...end])
            }
            return trimmed
        }()
        guard let data = jsonLine.data(using: .utf8) else { throw AgentSessionSyncError.decodeFailed }

        struct Row: Decodable {
            var kind: String
            var id: String
            var title: String?
            var cwd: String?
            var createdAtMs: Double?
            var updatedAtMs: Double?
            var screenName: String?
            var screenAlive: Bool?
        }

        let rows: [Row]
        do {
            rows = try JSONDecoder().decode([Row].self, from: data)
        } catch {
            throw AgentSessionSyncError.decodeFailed
        }

        return rows.compactMap { row in
            guard let kind = AgentKind(rawValue: row.kind) else { return nil }
            let created = Date(timeIntervalSince1970: (row.createdAtMs ?? 0) / 1000)
            let updated = Date(timeIntervalSince1970: (row.updatedAtMs ?? row.createdAtMs ?? 0) / 1000)
            let title = (row.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? String(row.id.prefix(8))
            let screenName = row.screenName
                ?? TerminalSession.defaultScreenName(kind: kind, sessionKey: row.id)
            return RemoteAgentConversation(
                agentKind: kind,
                chatId: row.id,
                title: title,
                cwd: row.cwd,
                createdAt: created,
                updatedAt: updated,
                screenName: screenName,
                screenAlive: row.screenAlive ?? false
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func listScript(projectPath: String) -> String {
        """
        import json, hashlib, os, pathlib, sys, subprocess, re, time

        def real(p):
            try:
                return os.path.realpath(p)
            except Exception:
                return os.path.abspath(p)

        project = real(sys.argv[1] if len(sys.argv) > 1 else ".")
        out = []
        seen = set()

        alive = set()
        try:
            proc = subprocess.run(["screen", "-ls"], capture_output=True, text=True, timeout=5)
            text = (proc.stdout or "") + (proc.stderr or "")
            for line in text.splitlines():
                m = re.search(r"\\t(\\d+)\\.(koko-[a-z]+-[^\\s\\t]+)", line)
                if m:
                    alive.add(m.group(2))
        except Exception:
            pass

        def add(kind, sid, title, cwd=None, created_ms=None, updated_ms=None, screen_name=None):
            key = (kind, sid)
            if key in seen:
                return
            seen.add(key)
            sid_str = str(sid)
            screen = screen_name or ("koko-" + kind + "-" + sid_str[:8])
            out.append({
                "kind": kind,
                "id": sid_str,
                "title": title or sid_str[:8],
                "cwd": cwd,
                "createdAtMs": created_ms,
                "updatedAtMs": updated_ms or created_ms,
                "screenName": screen,
                "screenAlive": screen in alive,
            })

        def cwd_matches(meta_cwd):
            if not meta_cwd:
                return False
            try:
                return real(meta_cwd) == project
            except Exception:
                return False

        chats_root = pathlib.Path.home() / ".cursor" / "chats"

        def add_cursor_dir(d, require_cwd_match=False):
            meta_path = d / "meta.json"
            if not meta_path.is_file():
                return
            try:
                meta = json.loads(meta_path.read_text())
            except Exception:
                return
            if meta.get("isSubagent"):
                return
            if meta.get("hasConversation") is False:
                return
            chat_id = d.name
            cwd = meta.get("cwd")
            if require_cwd_match and not cwd_matches(cwd):
                return
            add(
                "cursor",
                chat_id,
                meta.get("title") or chat_id[:8],
                cwd=cwd,
                created_ms=meta.get("createdAtMs"),
                updated_ms=meta.get("updatedAtMs") or meta.get("createdAtMs"),
            )

        primary = chats_root / hashlib.md5(project.encode()).hexdigest()
        if primary.is_dir():
            for d in primary.iterdir():
                if d.is_dir():
                    add_cursor_dir(d)

        if chats_root.is_dir():
            for ws in chats_root.iterdir():
                if not ws.is_dir() or ws == primary:
                    continue
                for d in ws.iterdir():
                    if d.is_dir():
                        add_cursor_dir(d, require_cwd_match=True)

        claude_root = pathlib.Path.home() / ".claude" / "projects"
        if claude_root.is_dir():
            for proj_dir in claude_root.iterdir():
                if not proj_dir.is_dir():
                    continue
                for f in proj_dir.iterdir():
                    if f.suffix == ".jsonl" and f.is_file():
                        sid = f.stem
                        mtime = f.stat().st_mtime * 1000
                        title = sid[:8]
                        add("claude", sid, title, updated_ms=mtime)

        codex_root = pathlib.Path.home() / ".codex" / "sessions"
        if codex_root.is_dir():
            for d in codex_root.iterdir():
                if not d.is_dir():
                    continue
                sid = d.name
                mtime = d.stat().st_mtime * 1000
                jsonl = d / "session.jsonl"
                if jsonl.is_file():
                    mtime = max(mtime, jsonl.stat().st_mtime * 1000)
                add("codex", sid, sid[:8], updated_ms=mtime)

        gemini_root = pathlib.Path.home() / ".gemini"
        for sub in ["chats", "tmp"]:
            root = gemini_root / sub
            if not root.is_dir():
                continue
            for f in root.rglob("*.json"):
                try:
                    data = json.loads(f.read_text())
                except Exception:
                    continue
                if not isinstance(data, dict):
                    continue
                sid = data.get("sessionId") or data.get("id") or f.stem
                title = data.get("title") or str(sid)[:8]
                mtime = f.stat().st_mtime * 1000
                add("gemini", str(sid), title, updated_ms=mtime)

        for name in sorted(alive):
            parts = name.split("-", 2)
            if len(parts) < 3 or parts[0] != "koko":
                continue
            kind = parts[1]
            if kind not in ("cursor", "claude", "codex", "gemini"):
                continue
            sid = parts[2]
            add(kind, sid, f"Screen {name}", updated_ms=time.time() * 1000, screen_name=name)

        out.sort(key=lambda r: r.get("updatedAtMs") or 0, reverse=True)
        print(json.dumps(out, ensure_ascii=False))
        """
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
