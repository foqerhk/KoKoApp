import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class AppStore: ObservableObject {
    @Published var servers: [ServerProfile] = []
    @Published var keyPairs: [SSHKeyPair] = []
    @Published var sessions: [TerminalSession] = []
    @Published var desktops: [PairedDesktop] = []
    /// AI chats from paired RunEverything Agents (Cursor/Claude/Codex/Gemini).
    @Published var desktopAgentChats: [DesktopAgentChat] = []
    @Published var desktopHostHealth: [DesktopHostHealth] = []
    @Published var hostPowerEvents: [HostPowerEvent] = []
    @Published var hostKeyPrompt: HostKeyPrompt?
    @Published var cursorLoginPrompt: CursorLoginPrompt?
    /// Simulator E2E: when set, RootView opens this session's terminal screen.
    @Published var e2eOpenSessionId: UUID?
    /// Hosts list consumes this to push the remote-desktop viewer (wake / unlock).
    @Published var pendingOpenDesktopId: UUID?

    private let serversKey = "koko.servers"
    private let keysKey = "koko.keys"
    private let sessionsKey = "koko.sessions"
    private let desktopsKey = "koko.desktops"
    private let desktopChatsKey = "koko.desktopAgentChats"
    private let desktopHealthKey = "koko.desktopHostHealth"
    private let powerEventsKey = "koko.hostPowerEvents"
    private var canPersistDesktopMetadata = true

    init() {
        load()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ScreenshotDemo") ||
            ProcessInfo.processInfo.environment["KOKO_SCREENSHOT_DEMO"] == "1" {
            ensureLabHostIfNeeded()
        }
#endif
    }

#if DEBUG
    /// Lab / screenshot host only — never wipes sessions or auto-opens a terminal.
    private func ensureLabHostIfNeeded() {
        guard let password = ProcessInfo.processInfo.environment["KOKO_LAB_SSH_PASSWORD"],
              !password.isEmpty else {
            return
        }
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
            data: Data(password.utf8),
            account: KeychainAccount.password.rawValue,
            keyId: server.id
        )
    }
#endif

    func load() {
        let decoded = Self.decode([ServerProfile].self, key: serversKey) ?? []
        servers = decoded.filter(\.isSSHConfigured)
        keyPairs = Self.decode([SSHKeyPair].self, key: keysKey) ?? []
        sessions = Self.decode([TerminalSession].self, key: sessionsKey) ?? []
        let savedDesktops = Self.decode([PairedDesktop].self, key: desktopsKey) ?? []
        var migratedLegacySecrets = false
        desktops = savedDesktops.map { saved in
            var desktop = saved
            if !saved.sessionTicket.isEmpty || !saved.pairingToken.isEmpty {
                do {
                    try saveDesktopSecrets(saved)
                    migratedLegacySecrets = true
                } catch {
                    // Never overwrite the only copy with redacted metadata.
                    canPersistDesktopMetadata = false
                    return desktop
                }
            }
            desktop.sessionTicket = loadDesktopSecret(.re2SessionTicket, desktopId: saved.id)
            desktop.pairingToken = loadDesktopSecret(.re2PairingToken, desktopId: saved.id)
            return desktop
        }
        let savedDesktopChats = Self.decode([DesktopAgentChat].self, key: desktopChatsKey) ?? []
        desktopAgentChats = normalizedDesktopAgentChats(savedDesktopChats)
        desktopHostHealth = Self.decode([DesktopHostHealth].self, key: desktopHealthKey) ?? []
        hostPowerEvents = Self.decode([HostPowerEvent].self, key: powerEventsKey) ?? []
        if migratedLegacySecrets || desktopAgentChats != savedDesktopChats {
            persist()
        }
    }

    private func persist() {
        Self.encode(servers, key: serversKey)
        Self.encode(keyPairs, key: keysKey)
        Self.encode(sessions, key: sessionsKey)
        if canPersistDesktopMetadata {
            let metadata = desktops.map { desktop -> PairedDesktop in
                var redacted = desktop
                redacted.sessionTicket = ""
                redacted.pairingToken = ""
                return redacted
            }
            Self.encode(metadata, key: desktopsKey)
        }
        Self.encode(desktopAgentChats, key: desktopChatsKey)
        Self.encode(desktopHostHealth, key: desktopHealthKey)
        Self.encode(hostPowerEvents, key: powerEventsKey)
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
            do {
                try saveDesktopSecrets(updated)
            } catch {
                canPersistDesktopMetadata = false
            }
            desktops[index] = updated
            persist()
            return updated
        } else {
            do {
                try saveDesktopSecrets(desktop)
            } catch {
                canPersistDesktopMetadata = false
            }
            desktops.append(desktop)
            persist()
            return desktop
        }
    }

    func deleteDesktop(_ desktop: PairedDesktop) {
        let chatIds = desktopAgentChats
            .filter { $0.desktopId == desktop.id }
            .map(\.id)
        for id in chatIds {
            WorkspaceRegistry.shared.prepareForDeletion(sessionId: id)
            WorkspaceRegistry.shared.remove(sessionId: id)
        }
        desktops.removeAll { $0.id == desktop.id || $0.deviceID == desktop.deviceID }
        desktopAgentChats.removeAll { $0.desktopId == desktop.id }
        desktopHostHealth.removeAll { $0.desktopId == desktop.id }
        hostPowerEvents.removeAll { $0.desktopId == desktop.id }
        try? KeychainService.shared.delete(
            account: KeychainAccount.desktopAccessPassword.rawValue,
            keyId: desktop.id
        )
        try? KeychainService.shared.delete(
            account: KeychainAccount.re2SessionTicket.rawValue,
            keyId: desktop.id
        )
        try? KeychainService.shared.delete(
            account: KeychainAccount.re2PairingToken.rawValue,
            keyId: desktop.id
        )
        persist()
    }

    private func saveDesktopSecrets(_ desktop: PairedDesktop) throws {
        try KeychainService.shared.save(
            data: Data(desktop.sessionTicket.utf8),
            account: KeychainAccount.re2SessionTicket.rawValue,
            keyId: desktop.id
        )
        try KeychainService.shared.save(
            data: Data(desktop.pairingToken.utf8),
            account: KeychainAccount.re2PairingToken.rawValue,
            keyId: desktop.id
        )
    }

    private func loadDesktopSecret(_ account: KeychainAccount, desktopId: UUID) -> String {
        guard let data = try? KeychainService.shared.load(account: account.rawValue, keyId: desktopId) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func hostHealth(for desktopId: UUID) -> DesktopHostHealth? {
        desktopHostHealth.first { $0.desktopId == desktopId }
    }

    func updateDesktopName(desktopId: UUID, computerName: String?) {
        guard let computerName = computerName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !computerName.isEmpty,
              let index = desktops.firstIndex(where: { $0.id == desktopId }),
              desktops[index].name != computerName else { return }
        let currentName = desktops[index].name
        // Older Agents could report a shortened network fallback such as
        // "Mac" in host-health responses. Do not let that downgrade the
        // descriptive identity obtained from the pairing QR code.
        if Self.isGenericDesktopName(computerName),
           !Self.isGenericDesktopName(currentName) {
            return
        }
        desktops[index].name = computerName
        for chatIndex in desktopAgentChats.indices where desktopAgentChats[chatIndex].desktopId == desktopId {
            desktopAgentChats[chatIndex].desktopName = computerName
        }
        persist()
    }

    private static func isGenericDesktopName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "mac"
            || normalized == "mac.lan"
            || normalized == "mac.local"
            || normalized == "localhost"
            || normalized == "runeverything"
    }

    func updateHostHealth(
        desktopId: UUID,
        snapshot: HostHealthSnapshot?,
        reachability: HostHealthReachability,
        reason: String? = nil
    ) {
        let value = DesktopHostHealth(
            desktopId: desktopId, snapshot: snapshot, fetchedAt: .now,
            reachability: reachability, offlineReason: reason
        )
        if let index = desktopHostHealth.firstIndex(where: { $0.desktopId == desktopId }) {
            desktopHostHealth[index] = value
        } else {
            desktopHostHealth.append(value)
        }
        desktopHostHealth = Array(desktopHostHealth)
        persist()
    }

    func recordPowerEvent(_ event: HostPowerEvent, hostName: String) {
        hostPowerEvents.append(event)
        if hostPowerEvents.count > 100 {
            hostPowerEvents.removeFirst(hostPowerEvents.count - 100)
        }
        persist()
        guard event.critical == true || event.event == "power.ac_lost" || event.event == "power.ac_restored" else {
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = hostName
            content.body = event.detail ?? event.event
            if event.critical == true { content.sound = .default }
            center.add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
        }
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
                // Same Cursor id can be listed as both CLI and IDE. Keep the
                // client row so the list stays 客户端 and open goes through IDE.
                if chat.isClientSession && !existing.isClientSession {
                    best[key] = chat
                } else if existing.isClientSession && !chat.isClientSession {
                    continue
                } else if chat.screenAlive && !existing.screenAlive || chat.updatedAt > existing.updatedAt {
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
