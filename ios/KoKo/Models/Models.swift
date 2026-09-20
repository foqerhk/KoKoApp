import Foundation

enum SSHKeyAlgorithm: String, Codable, CaseIterable, Identifiable {
    case ed25519
    case ecdsaP256
    case ecdsaP384
    case rsa2048

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ed25519: return "Ed25519"
        case .ecdsaP256: return "ECDSA P-256"
        case .ecdsaP384: return "ECDSA P-384"
        case .rsa2048: return "RSA 2048"
        }
    }
}

struct SSHKeyPair: Identifiable, Codable, Hashable {
    var id: UUID
    var label: String
    var algorithm: SSHKeyAlgorithm
    var publicKeyOpenSSH: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        label: String,
        algorithm: SSHKeyAlgorithm,
        publicKeyOpenSSH: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.label = label
        self.algorithm = algorithm
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.createdAt = createdAt
    }
}

enum AuthType: String, Codable, CaseIterable {
    case key
    case password
}

enum AgentKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case cursor
    case claude
    case codex
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }

    /// Whether the remote session runs inside GNU screen (non-Cursor agents).
    var usesScreen: Bool {
        self != .cursor
    }

    var cliBinaryName: String {
        switch self {
        case .cursor: return "agent"
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        }
    }

    var cliSuccessToken: String {
        switch self {
        case .cursor: return "CURSOR_CLI_OK"
        case .claude: return "CLAUDE_CLI_OK"
        case .codex: return "CODEX_CLI_OK"
        case .gemini: return "GEMINI_CLI_OK"
        }
    }

    var authSuccessToken: String {
        switch self {
        case .cursor: return "CURSOR_AUTH_OK"
        case .claude: return "CLAUDE_AUTH_OK"
        case .codex: return "CODEX_AUTH_OK"
        case .gemini: return "GEMINI_AUTH_OK"
        }
    }

    /// Browser OAuth code must be pasted into the remote PTY prompt (Claude / Gemini).
    var requiresTerminalAuthCode: Bool {
        switch self {
        case .claude, .gemini: return true
        case .cursor, .codex: return false
        }
    }

    /// Install may bootstrap npm on the server when missing (Claude/Codex/Gemini).
    var needsNpmBootstrap: Bool {
        switch self {
        case .claude, .codex, .gemini: return true
        case .cursor: return false
        }
    }
}

struct ProjectPath: Identifiable, Codable, Hashable {
    var id: UUID
    var label: String
    var remotePath: String

    init(id: UUID = UUID(), label: String, remotePath: String) {
        self.id = id
        self.label = label
        self.remotePath = remotePath
    }
}

struct ServerProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authType: AuthType
    var keyPairId: UUID?
    var hostKeyFingerprint: String?
    var hostKeyBlobBase64: String?
    var projects: [ProjectPath]

    init(
        id: UUID = UUID(),
        name: String,
        host: String = "",
        port: Int = 22,
        username: String = "",
        authType: AuthType = .key,
        keyPairId: UUID? = nil,
        hostKeyFingerprint: String? = nil,
        hostKeyBlobBase64: String? = nil,
        projects: [ProjectPath] = []
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authType = authType
        self.keyPairId = keyPairId
        self.hostKeyFingerprint = hostKeyFingerprint
        self.hostKeyBlobBase64 = hostKeyBlobBase64
        self.projects = projects
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authType, keyPairId
        case hostKeyFingerprint, hostKeyBlobBase64, projects
        case transport, relayURL, deviceID, sessionToken
    }

    /// Backward-compatible decode (drops legacy RunEverything-only hosts).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        authType = try c.decodeIfPresent(AuthType.self, forKey: .authType) ?? .key
        keyPairId = try c.decodeIfPresent(UUID.self, forKey: .keyPairId)
        hostKeyFingerprint = try c.decodeIfPresent(String.self, forKey: .hostKeyFingerprint)
        hostKeyBlobBase64 = try c.decodeIfPresent(String.self, forKey: .hostKeyBlobBase64)
        projects = try c.decodeIfPresent([ProjectPath].self, forKey: .projects) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(authType, forKey: .authType)
        try c.encodeIfPresent(keyPairId, forKey: .keyPairId)
        try c.encodeIfPresent(hostKeyFingerprint, forKey: .hostKeyFingerprint)
        try c.encodeIfPresent(hostKeyBlobBase64, forKey: .hostKeyBlobBase64)
        try c.encode(projects, forKey: .projects)
    }

    var isSSHConfigured: Bool {
        !host.isEmpty && !username.isEmpty
    }
}

struct TerminalSession: Identifiable, Codable, Hashable {
    var id: UUID
    var serverId: UUID
    var projectId: UUID
    var displayName: String
    var agentKind: AgentKind
    /// Remote agent chat/session id (`agent persist --resume`, `claude --resume`, etc.).
    var agentChatId: String?
    /// GNU screen session name on the server (`koko-<kind>-<id>`).
    var remoteSessionName: String
    var createdAt: Date
    var lastConnectedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, serverId, projectId, displayName, agentKind, agentChatId, remoteSessionName
        case createdAt, lastConnectedAt, persistenceMode
    }

    init(
        id: UUID = UUID(),
        serverId: UUID,
        projectId: UUID,
        displayName: String,
        agentKind: AgentKind = .cursor,
        remoteSessionName: String? = nil,
        agentChatId: String? = nil,
        createdAt: Date = .now,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.projectId = projectId
        self.displayName = displayName
        self.agentKind = agentKind
        self.agentChatId = agentChatId
        let sessionKey = agentChatId ?? id.uuidString
        self.remoteSessionName = remoteSessionName
            ?? Self.defaultScreenName(kind: agentKind, sessionKey: sessionKey)
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        serverId = try container.decode(UUID.self, forKey: .serverId)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        displayName = try container.decode(String.self, forKey: .displayName)
        agentKind = try container.decodeIfPresent(AgentKind.self, forKey: .agentKind) ?? .cursor
        agentChatId = try container.decodeIfPresent(String.self, forKey: .agentChatId)
        let sessionKey = agentChatId ?? id.uuidString
        remoteSessionName = try container.decodeIfPresent(String.self, forKey: .remoteSessionName)
            ?? Self.defaultScreenName(kind: agentKind, sessionKey: sessionKey)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        _ = try container.decodeIfPresent(String.self, forKey: .persistenceMode)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(projectId, forKey: .projectId)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(agentKind, forKey: .agentKind)
        try container.encodeIfPresent(agentChatId, forKey: .agentChatId)
        try container.encode(remoteSessionName, forKey: .remoteSessionName)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastConnectedAt, forKey: .lastConnectedAt)
    }

    static func defaultScreenName(kind: AgentKind, sessionKey: String) -> String {
        let safe = sessionKey
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let suffix = String(safe.prefix(24))
        return "koko-\(kind.rawValue)-\(suffix)"
    }
}

enum SessionConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(String)
    case ended
}

struct LocalStatusEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case info
        case success
        case warning
        case error
    }

    let id: UUID
    let date: Date
    let kind: Kind
    let message: String

    init(id: UUID = UUID(), date: Date = Date(), kind: Kind, message: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.message = message
    }
}

struct HostKeyPrompt: Identifiable, Equatable {
    let id = UUID()
    let serverId: UUID
    let fingerprint: String
}

struct CursorLoginPrompt: Identifiable, Equatable {
    let id = UUID()
    let sessionId: UUID
    let loginURL: String
}

struct AgentInstallPrompt: Identifiable, Equatable {
    let id = UUID()
    let agentKind: AgentKind
    let serverName: String
}
