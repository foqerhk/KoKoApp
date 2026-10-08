import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var servers: [ServerProfile] = []
    @Published var keyPairs: [SSHKeyPair] = []
    @Published var sessions: [TerminalSession] = []
    @Published var desktops: [PairedDesktop] = []
    /// AI chats from paired RunEverything Agents (Cursor/Claude/Codex/Gemini).
    @Published var desktopAgentChats: [DesktopAgentChat] = []
    @Published var hostKeyPrompt: HostKeyPrompt?
    @Published var cursorLoginPrompt: CursorLoginPrompt?
    /// Simulator E2E: when set, RootView opens this session's terminal screen.
    @Published var e2eOpenSessionId: UUID?

    private let serversKey = "koko.servers"
    private let keysKey = "koko.keys"
    private let sessionsKey = "koko.sessions"
    private let desktopsKey = "koko.desktops"
    private let desktopChatsKey = "koko.desktopAgentChats"

    init() {
        load()
        if ProcessInfo.processInfo.arguments.contains("-ScreenshotDemo") ||
            ProcessInfo.processInfo.environment["KOKO_SCREENSHOT_DEMO"] == "1" {
            ensureLabHostIfNeeded()
        }
    }

    /// Lab / screenshot host only — never wipes sessions or auto-opens a terminal.
    private func ensureLabHostIfNeeded() {
        let host = "8.137.32.163"
        if servers.contains(where: { $0.host == host && $0.username == "root" }) {
            return
        }
        let project = ProjectPath(label: "home", remotePath: "/root")
        let server = ServerProfile(
            name: host,
            host: host,
            port: 22,
            username: "root",
            authType: .password,
            hostKeyFingerprint: "SHA256:m+4MHb0EeV35pcQKIvjddF6W1bFqcL+5TgVPuG7vqnI=",
            projects: [project]
        )
        upsertServer(server)
        try? KeychainService.shared.save(
            data: Data("Koko@2026".utf8),
            account: KeychainAccount.password.rawValue,
            keyId: server.id
        )
    }

    func load() {
        let decoded = Self.decode([ServerProfile].self, key: serversKey) ?? []
        servers = decoded.filter(\.isSSHConfigured)
        keyPairs = Self.decode([SSHKeyPair].self, key: keysKey) ?? []
        sessions = Self.decode([TerminalSession].self, key: sessionsKey) ?? []
        desktops = Self.decode([PairedDesktop].self, key: desktopsKey) ?? []
        let savedDesktopChats = Self.decode([DesktopAgentChat].self, key: desktopChatsKey) ?? []
        desktopAgentChats = normalizedDesktopAgentChats(savedDesktopChats)
        if desktopAgentChats != savedDesktopChats {
            persist()
        }
    }

    private func persist() {
        Self.encode(servers, key: serversKey)
        Self.encode(keyPairs, key: keysKey)
        Self.encode(sessions, key: sessionsKey)
        Self.encode(desktops, key: desktopsKey)
        Self.encode(desktopAgentChats, key: desktopChatsKey)
    }

    @discardableResult
    func upsertDesktop(_ desktop: PairedDesktop) -> PairedDesktop {
        if let index = desktops.firstIndex(where: { $0.deviceID == desktop.deviceID }) {
            var updated = desktop
            updated.id = desktops[index].id
            let existing = desktops[index]
            // Never let a probe/E2E stripLAN profile wipe known LAN peers — that forces
            // every later reconnect onto WSS·Relay.
            if updated.lanCandidates.isEmpty, !existing.lanCandidates.isEmpty {
                updated.lanCandidates = existing.lanCandidates
            }
            desktops[index] = updated
            persist()
            return updated
        } else {
            desktops.append(desktop)
            persist()
            return desktop
        }
    }

    func deleteDesktop(_ desktop: PairedDesktop) {
        desktops.removeAll { $0.id == desktop.id || $0.deviceID == desktop.deviceID }
        desktopAgentChats.removeAll { $0.desktopId == desktop.id }
        try? KeychainService.shared.delete(
            account: KeychainAccount.desktopAccessPassword.rawValue,
            keyId: desktop.id
        )
        persist()
    }

    func replaceDesktopAgentChats(desktopId: UUID, chats: [DesktopAgentChat]) {
        let canonicalId: UUID = {
            if desktops.contains(where: { $0.id == desktopId }) {
                return desktopId
            }
            let names = Set(chats.map(\.desktopName))
            let matches = desktops.filter { names.contains($0.name) }
            return matches.count == 1 ? matches[0].id : desktopId
        }()
        // Never persist rows under a transient pairing UUID. A fresh QR profile
        // gets a new local id before upsertDesktop restores the device's stable id.
        guard desktops.contains(where: { $0.id == canonicalId }) else { return }

        desktopAgentChats.removeAll { $0.desktopId == canonicalId }
        desktopAgentChats.append(contentsOf: chats.map { chat in
            var canonical = chat
            canonical.desktopId = canonicalId
            canonical.id = DesktopAgentChat.stableID(
                desktopId: canonicalId,
                kind: chat.agentKind,
                chatId: chat.chatId
            )
            return canonical
        })
        desktopAgentChats = normalizedDesktopAgentChats(desktopAgentChats)
        persist()
    }

    /// Remove chats left under obsolete pairing UUIDs and collapse duplicate rows.
    /// Identity is stable per physical desktop + agent kind + remote chat id.
    private func normalizedDesktopAgentChats(_ chats: [DesktopAgentChat]) -> [DesktopAgentChat] {
        let validDesktopIds = Set(desktops.map(\.id))
        var best: [String: DesktopAgentChat] = [:]
        for saved in chats where validDesktopIds.contains(saved.desktopId) {
            var chat = saved
            chat.id = DesktopAgentChat.stableID(
                desktopId: chat.desktopId,
                kind: chat.agentKind,
                chatId: chat.chatId
            )
            let key = "\(chat.desktopId.uuidString)|\(chat.agentKind.rawValue)|\(chat.chatId)"
            if let existing = best[key] {
                if chat.screenAlive && !existing.screenAlive || chat.updatedAt > existing.updatedAt {
                    best[key] = chat
                }
            } else {
                best[key] = chat
            }
        }
        return best.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func upsertServer(_ server: ServerProfile) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        persist()
    }

    func deleteServer(_ server: ServerProfile) {
        servers.removeAll { $0.id == server.id }
        sessions.removeAll { $0.serverId == server.id }
        try? KeychainService.shared.delete(account: KeychainAccount.password.rawValue, keyId: server.id)
        persist()
    }

    func upsertKeyPair(_ keyPair: SSHKeyPair, privateKeyData: Data) throws {
        try KeychainService.shared.save(
            data: privateKeyData,
            account: KeychainAccount.privateKey.rawValue,
            keyId: keyPair.id
        )
        if let index = keyPairs.firstIndex(where: { $0.id == keyPair.id }) {
            keyPairs[index] = keyPair
        } else {
            keyPairs.append(keyPair)
        }
        persist()
    }

    /// Update public key metadata without touching the Keychain private key.
    func updateKeyPairPublicKey(_ keyPair: SSHKeyPair, publicKeyOpenSSH: String) {
        guard let index = keyPairs.firstIndex(where: { $0.id == keyPair.id }) else { return }
        var updated = keyPairs[index]
        updated.publicKeyOpenSSH = publicKeyOpenSSH
        keyPairs[index] = updated
        keyPairs = Array(keyPairs)
        persist()
    }

    func deleteKeyPair(_ keyPair: SSHKeyPair) {
        keyPairs.removeAll { $0.id == keyPair.id }
        try? KeychainService.shared.delete(account: KeychainAccount.privateKey.rawValue, keyId: keyPair.id)
        for index in servers.indices where servers[index].keyPairId == keyPair.id {
            servers[index].keyPairId = nil
        }
        persist()
    }

    func upsertSession(_ session: TerminalSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        persist()
    }

    func replaceSessions(_ newSessions: [TerminalSession]) {
        sessions = newSessions
        persist()
    }

    func deleteSession(_ session: TerminalSession) {
        sessions.removeAll { $0.id == session.id }
        ScrollbackStore.shared.clear(sessionId: session.id)
        persist()
    }

    func touchSession(_ sessionId: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].lastConnectedAt = .now
        persist()
    }

    func saveHostKey(serverId: UUID, fingerprint: String) {
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else { return }
        var updated = servers[index]
        updated.hostKeyFingerprint = fingerprint
        servers[index] = updated
        persist()
    }

    /// Switch host auth to the given key and drop any stored password (app-side).
    func switchServerToKeyAuth(serverId: UUID, keyPairId: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else { return }
        var updated = servers[index]
        updated.authType = .key
        updated.keyPairId = keyPairId
        servers[index] = updated
        try? KeychainService.shared.delete(account: KeychainAccount.password.rawValue, keyId: serverId)
        // Force observers to refresh (array element replace is not always enough for nested views).
        servers = Array(servers)
        persist()
    }

    var sshServers: [ServerProfile] {
        servers
    }

    /// Next unused `"\(prefix) N"` among host names (also treats bare `prefix` as #1).
    func nextNumberedName(prefix: String) -> String {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Host" : trimmed
        var used = Set<Int>()
        for name in servers.map(\.name) {
            if name == base {
                used.insert(1)
            } else if name.hasPrefix(base + " "),
                      let n = Int(name.dropFirst(base.count + 1).trimmingCharacters(in: .whitespaces)) {
                used.insert(n)
            }
        }
        var n = 1
        while used.contains(n) { n += 1 }
        return "\(base) \(n)"
    }

    func makeDefaultSSHHost() -> ServerProfile {
        ServerProfile(
            name: nextNumberedName(prefix: "SSH Host"),
            host: "",
            username: "",
            authType: keyPairs.isEmpty ? .password : .key,
            keyPairId: keyPairs.first?.id,
            projects: [ProjectPath(label: "home", remotePath: "")]
        )
    }

    func assignedHostName(preferred: String) -> String {
        nextNumberedName(prefix: preferred.isEmpty ? "SSH Host" : preferred)
    }

    func server(for id: UUID) -> ServerProfile? {
        servers.first { $0.id == id }
    }

    func keyPair(for id: UUID?) -> SSHKeyPair? {
        guard let id else { return nil }
        return keyPairs.first { $0.id == id }
    }

    func project(for session: TerminalSession) -> ProjectPath? {
        guard let server = server(for: session.serverId) else { return nil }
        return server.projects.first { $0.id == session.projectId }
    }

    private static func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
