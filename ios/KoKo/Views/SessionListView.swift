import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class WorkspaceRegistry: ObservableObject {
    static let shared = WorkspaceRegistry()
    private var workspaces: [UUID: TerminalWorkspace] = [:]

    func workspace(for sessionId: UUID) -> TerminalWorkspace {
        if let existing = workspaces[sessionId] {
            return existing
        }
        let workspace = TerminalWorkspace(sessionId: sessionId)
        workspaces[sessionId] = workspace
        return workspace
    }

    func remove(sessionId: UUID) {
        workspaces.removeValue(forKey: sessionId)
    }

    func prepareForDeletion(sessionId: UUID) {
        workspaces[sessionId]?.disconnect()
    }
}

private let sessionGroupPreviewLimit = 5

/// Terminal = CLI in GNU screen; client = desktop app mirror (bubbles).
private enum DesktopNewSessionSurface {
    case terminal
    case client
}

private func makeNewDesktopAgentChat(
    desk: PairedDesktop,
    kind: AgentKind,
    surface: DesktopNewSessionSurface,
    title: String,
    directory: String,
    tag: String
) -> DesktopAgentChat {
    if surface == .client, kind == .cursor {
        return DesktopAgentChat(
            id: UUID(),
            desktopId: desk.id,
            desktopName: desk.name,
            agentKind: .cursor,
            chatId: "",
            title: title,
            cwd: directory,
            updatedAt: Date(),
            screenName: "koko-cursor-ide-\(tag)",
            screenAlive: false,
            source: "client",
            clientName: "Cursor IDE"
        )
    }
    return DesktopAgentChat(
        id: DesktopAgentChat.stableID(desktopId: desk.id, kind: kind, chatId: tag),
        desktopId: desk.id,
        desktopName: desk.name,
        agentKind: kind,
        chatId: tag,
        title: title,
        cwd: directory,
        updatedAt: Date(),
        screenName: "koko-\(kind.rawValue)-\(tag)",
        screenAlive: false,
        source: "cli"
    )
}

private struct DesktopRepoGroup: Identifiable {
    var id: String
    var desktopId: UUID
    var path: String
    var title: String
    var subtitle: String?
    var chats: [DesktopAgentChat]
    var mixedAgents: Bool
    /// Folder quick-add mirrors the newest row when it is a Cursor client (IDE) chat.
    var quickCreateAsCursorClient: Bool
    var agentKind: AgentKind
}

private struct SSHDirectoryGroup: Identifiable {
    var id: String
    var serverId: UUID
    var projectId: UUID
    var path: String
    var title: String
    var subtitle: String?
    var sessions: [TerminalSession]
    var agentKind: AgentKind
    var mixedAgents: Bool
}

private enum RepositoryListItem: Identifiable {
    case header(DesktopRepoGroup)
    case chat(DesktopAgentChat, mixed: Bool)
    case more(groupID: String, remaining: Int)

    var id: String {
        switch self {
        case .header(let group): return "repo-\(group.id)"
        case .chat(let chat, _): return "repo-chat-\(chat.id.uuidString)"
        case .more(let groupID, _): return "repo-more-\(groupID)"
        }
    }
}

private enum SSHListItem: Identifiable {
    case header(SSHDirectoryGroup)
    case session(TerminalSession, mixed: Bool)
    case more(groupID: String, remaining: Int)

    var id: String {
        switch self {
        case .header(let group): return "ssh-\(group.id)"
        case .session(let session, _): return "ssh-session-\(session.id.uuidString)"
        case .more(let groupID, _): return "ssh-more-\(groupID)"
        }
    }
}

private enum SessionPathGroup {
    static func normalize(_ raw: String?) -> String {
        var path = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    static func folderName(_ path: String) -> String {
        if path.isEmpty || path == "~" { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? path : name
    }
}

private struct SessionGroupHeader: View {
    let title: String
    var subtitle: String? = nil
    var showsAdd: Bool
    let addLabel: String
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "folder")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.caption2)
                        .foregroundStyle(.primary.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if showsAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(addLabel)
            }
        }
    }
}

private struct ConversationLine: View {
    let title: String
    let date: Date
    var isCurrent: Bool = false
    var isLive: Bool = false
    var detail: String? = nil

    private var dotColor: Color {
        if isCurrent { return .accentColor }
        if isLive { return .green }
        return Color.secondary.opacity(0.55)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(SessionAge.compact(date))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 1)
    }
}

private enum SessionAge {
    static func compact(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 45 { return String(localized: "Just now") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(minutes, 1))m" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(hours)h" }
        let days = Int(seconds / 86_400)
        return "\(max(days, 1))d"
    }
}

struct SessionListView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var desktopHub = DesktopSessionHub.shared
    var serverFilter: UUID?
    var desktopFilter: UUID?
    var selectedSessionId: Binding<UUID?>? = nil
    var embedded: Bool = false
    var onPickSession: ((TerminalSession) -> Void)? = nil
    var onOpenInNewWindow: ((TerminalSession) -> Void)? = nil
    var highlightedSessionIds: Set<UUID> = []
    var sessionPath: Binding<NavigationPath>? = nil
    @State private var showingCreator = false
    @State private var sessionsPendingDelete: [TerminalSession] = []
    @State private var showDeleteConfirm = false
    @State private var isRefreshing = false
    /// False until the first server sync finishes (success or failure).
    @State private var hasCompletedInitialFetch = false
    @State private var syncError: String?
    @State private var hostKeyPrompt: HostKeyPrompt?
    @State private var deleteJob: SessionDeleteJob?
    @State private var selectedDesktopChat: DesktopAgentChat?
    @State private var pendingNewDesktopChat: DesktopAgentChat?
    @State private var newDesktopChatId: UUID?
    @State private var takeoverDesk: PairedDesktop?
    @State private var takeoverPeer = ""
    @State private var expandedGroupIDs: Set<String> = []
    @State private var createdSession: TerminalSession?

    private static let groupHeaderInsets = EdgeInsets(top: 8, leading: 16, bottom: 2, trailing: 8)
    private static let conversationInsets = EdgeInsets(top: 8, leading: 28, bottom: 8, trailing: 16)
    private static let moreInsets = EdgeInsets(top: 2, leading: 44, bottom: 8, trailing: 16)

    private var filteredSessions: [TerminalSession] {
        if desktopFilter != nil { return [] }
        let all = store.sessions.sorted { ($0.lastConnectedAt ?? $0.createdAt) > ($1.lastConnectedAt ?? $1.createdAt) }
        guard let serverFilter else { return all }
        return all.filter { $0.serverId == serverFilter }
    }

    private var desktopChats: [DesktopAgentChat] {
        if serverFilter != nil { return [] }
        let chats = store.desktopAgentChats.sorted { $0.updatedAt > $1.updatedAt }
        guard let desktopFilter else { return chats }
        return chats.filter { $0.desktopId == desktopFilter }
    }

    private var listIsEmpty: Bool {
        filteredSessions.isEmpty && desktopChats.isEmpty
    }

    var body: some View {
        List {
            if let syncError {
                Text(syncError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if listIsEmpty {
                if isRefreshing || !hasCompletedInitialFetch {
                    EmptyListStatusView(
                        showProgress: true,
                        description: "Loading conversations… Please wait."
                    )
                } else {
                    EmptyListStatusView(
                        title: "No Conversations",
                        systemImage: "bubble.left.and.bubble.right",
                        description: "Pull to refresh — KoKo loads agent sessions from SSH hosts and paired desktops"
                    )
                }
            } else {
                if !repositoryItems.isEmpty {
                    Section {
                        ForEach(repositoryItems) { item in
                            repositoryRow(item)
                        }
                    } header: {
                        Text(String(localized: "Repositories"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .textCase(nil)
                    }
                }
                if !sshItems.isEmpty {
                    Section {
                        ForEach(sshItems) { item in
                            sshRow(item)
                        }
                    } header: {
                        Text(String(localized: "SSH"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .textCase(nil)
                    }
                }
            }
        }
        .navigationTitle(embedded ? "Other Sessions" : "Sessions")
        .navigationBarTitleDisplayMode(embedded ? .inline : .large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isRefreshing {
                    ProgressView()
                } else {
                    Button {
                        Task { await refreshFromServers() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCreator = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable {
            await refreshFromServers()
        }
        .task {
            await refreshFromServers()
        }
        .navigationDestination(item: $createdSession) { session in
            TerminalScreenView(session: store.sessions.first(where: { $0.id == session.id }) ?? session)
        }
        .sheet(isPresented: $showingCreator, onDismiss: {
            if let chat = pendingNewDesktopChat {
                pendingNewDesktopChat = nil
                newDesktopChatId = chat.id
                selectedDesktopChat = chat
            }
        }) {
            SessionCreatorView(
                serverFilter: serverFilter,
                desktopFilter: desktopFilter,
                onCreate: { session in store.upsertSession(session) },
                onCreateDesktop: { chat in pendingNewDesktopChat = chat }
            )
        }
        .sheet(isPresented: $showDeleteConfirm, onDismiss: {
            sessionsPendingDelete = []
        }) {
            CountdownDeleteConfirmView(
                title: String(localized: "Delete Session?"),
                message: sessionDeleteMessage,
                confirmLabel: String(localized: "Delete Session"),
                onConfirm: {
                    let targets = sessionsPendingDelete
                    sessionsPendingDelete = []
                    showDeleteConfirm = false
                    guard !targets.isEmpty else { return }
                    let job = SessionDeleteJob(sessions: targets)
                    deleteJob = job
                    job.start(store: store)
                },
                onCancel: {
                    sessionsPendingDelete = []
                    showDeleteConfirm = false
                }
            )
        }
        .fullScreenCover(item: $selectedDesktopChat, onDismiss: { newDesktopChatId = nil }) { chat in
            DesktopAgentChatTerminalView(
                workspace: WorkspaceRegistry.shared.workspace(for: chat.id),
                chat: chat,
                initialMode: chat.id == newDesktopChatId && !chat.mirrorsIDEChat ? .forceNew : .preferExisting,
                onClose: { selectedDesktopChat = nil }
            )
            .environmentObject(store)
        }
        .sheet(item: $deleteJob) { job in
            SessionDeleteProgressView(job: job)
                .environmentObject(store)
        }
        .alert(
            "Host Fingerprint",
            isPresented: Binding(
                get: { hostKeyPrompt != nil },
                set: { if !$0 { hostKeyPrompt = nil } }
            )
        ) {
            Button("Trust & Continue") {
                if let prompt = hostKeyPrompt {
                    store.saveHostKey(serverId: prompt.serverId, fingerprint: prompt.fingerprint)
                    HostKeyApprovalGate.shared.approve()
                }
                hostKeyPrompt = nil
            }
            Button("Reject", role: .cancel) {
                HostKeyApprovalGate.shared.reject()
                hostKeyPrompt = nil
            }
        } message: {
            if let prompt = hostKeyPrompt {
                Text(prompt.fingerprint)
            }
        }
        .alert(
            "Computer In Use",
            isPresented: Binding(
                get: { takeoverDesk != nil },
                set: { if !$0 { takeoverDesk = nil } }
            )
        ) {
            Button("Take Over") {
                if let desk = takeoverDesk {
                    Task { await takeOver(desk) }
                }
                takeoverDesk = nil
            }
            Button("Cancel", role: .cancel) {
                takeoverDesk = nil
            }
        } message: {
            Text(RE2Error.controllerBusy(peer: takeoverPeer).localizedDescription)
        }
    }

    private var sessionDeleteMessage: String {
        if sessionsPendingDelete.count == 1, let session = sessionsPendingDelete.first {
            return String(
                format: String(localized: "Delete %@ on the server and on this device? This cannot be undone."),
                session.displayName
            )
        }
        return String(localized: "Delete the selected conversations on the server and on this device? This cannot be undone.")
    }

    private func refreshFromServers() async {
        let targets: [(ServerProfile, ProjectPath)] = {
            if desktopFilter != nil {
                return []
            }
            if let serverFilter, let server = store.server(for: serverFilter) {
                return server.projects.map { (server, $0) }
            }
            return store.servers.flatMap { server in server.projects.map { (server, $0) } }
        }()
        let desktops: [PairedDesktop] = {
            if serverFilter != nil { return [] }
            let reconnectable = store.desktops.filter(\.canReconnect)
            guard let desktopFilter else { return reconnectable }
            return reconnectable.filter { $0.id == desktopFilter }
        }()

        guard !targets.isEmpty || !desktops.isEmpty else {
            syncError = String(localized: "Add an SSH host or pair a desktop Agent first")
            hasCompletedInitialFetch = true
            return
        }

        isRefreshing = true
        syncError = nil
        defer {
            isRefreshing = false
            hasCompletedInitialFetch = true
        }

        var errors: [String] = []
        for (server, project) in targets {
            do {
                let keyPair = store.keyPair(for: server.keyPairId)
                let conversations = try await AgentSessionSync.listConversations(
                    server: server,
                    keyPair: keyPair,
                    projectPath: project.remotePath,
                    onHostKeyUnknown: { fingerprint in
                        Task { @MainActor in
                            hostKeyPrompt = HostKeyPrompt(serverId: server.id, fingerprint: fingerprint)
                        }
                    }
                )
                AgentSessionSync.apply(
                    conversations: conversations,
                    to: store,
                    serverId: server.id,
                    projectId: project.id
                )
            } catch {
                errors.append("\(server.name)/\(project.label): \(error.localizedDescription)")
            }
        }

        // Paired Agents: over the relay's data channel, independent of any desktop session.
        for desk in desktops {
            do {
                try await syncDesktopChats(desk, force: false)
            } catch RE2Error.controllerBusy(let peer) {
                if takeoverDesk == nil {
                    takeoverPeer = peer
                    takeoverDesk = desk
                }
                errors.append("\(desk.name): \(RE2Error.controllerBusy(peer: peer).localizedDescription)")
            } catch {
                errors.append("\(desk.name): \(error.localizedDescription)")
            }
        }

        if !errors.isEmpty {
            syncError = errors.joined(separator: "\n")
        }
    }

    private func syncDesktopChats(_ desk: PairedDesktop, force: Bool) async throws {
        let conversations = try await desktopHub.listAgentChats(for: desk, force: force)
        let rows = conversations.map { c in
            DesktopAgentChat(
                id: DesktopAgentChat.stableID(desktopId: desk.id, kind: c.agentKind, chatId: c.chatId),
                desktopId: desk.id,
                desktopName: desk.name,
                agentKind: c.agentKind,
                chatId: c.chatId,
                title: c.title,
                cwd: c.cwd,
                updatedAt: c.updatedAt,
                screenName: c.screenName,
                screenAlive: c.screenAlive,
                source: c.source,
                clientName: c.client
            )
        }
        store.replaceDesktopAgentChats(desktopId: desk.id, chats: rows)
    }

    private func takeOver(_ desk: PairedDesktop) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await syncDesktopChats(desk, force: true)
            syncError = nil
        } catch {
            syncError = "\(desk.name): \(error.localizedDescription)"
        }
    }

    private var repositoryItems: [RepositoryListItem] {
        desktopRepoGroups.flatMap { group in
            var items = [RepositoryListItem.header(group)]
            let shown = visibleChats(in: group)
            items.append(contentsOf: shown.map { .chat($0, mixed: group.mixedAgents) })
            let hidden = group.chats.count - shown.count
            if hidden > 0 {
                items.append(.more(groupID: group.id, remaining: hidden))
            }
            return items
        }
    }

    private var sshItems: [SSHListItem] {
        sshDirectoryGroups.flatMap { group in
            var items = [SSHListItem.header(group)]
            let shown = visibleSessions(in: group)
            items.append(contentsOf: shown.map { .session($0, mixed: group.mixedAgents) })
            let hidden = group.sessions.count - shown.count
            if hidden > 0 {
                items.append(.more(groupID: group.id, remaining: hidden))
            }
            return items
        }
    }

    private var desktopRepoGroups: [DesktopRepoGroup] {
        let chats = desktopChats
        let desktopCount = Set(chats.map(\.desktopId)).count
        struct Key: Hashable {
            var desktopId: UUID
            var path: String
        }
        var buckets: [Key: [DesktopAgentChat]] = [:]
        for chat in chats {
            let path = SessionPathGroup.normalize(chat.cwd)
            buckets[Key(desktopId: chat.desktopId, path: path), default: []].append(chat)
        }
        return buckets.map { key, rows in
            let sorted = rows.sorted { $0.updatedAt > $1.updatedAt }
            let folder = SessionPathGroup.folderName(key.path)
            let title = key.path.isEmpty ? String(localized: "No project folder") : folder
            var subtitle: [String] = []
            if desktopCount > 1, let name = sorted.first?.desktopName, !name.isEmpty {
                subtitle.append(name)
            }
            if !key.path.isEmpty {
                subtitle.append(DesktopPath.abbreviate(key.path))
            }
            let newest = sorted[0]
            let kinds = Set(sorted.map { $0.mirrorsIDEChat ? "ide" : $0.agentKind.rawValue })
            return DesktopRepoGroup(
                id: "\(key.desktopId.uuidString)|\(key.path)",
                desktopId: key.desktopId,
                path: key.path,
                title: title,
                subtitle: subtitle.isEmpty ? nil : subtitle.joined(separator: " · "),
                chats: sorted,
                mixedAgents: kinds.count > 1,
                quickCreateAsCursorClient: newest.agentKind == .cursor && newest.isClientSession,
                agentKind: newest.agentKind
            )
        }
        .sorted { ($0.chats.first?.updatedAt ?? .distantPast) > ($1.chats.first?.updatedAt ?? .distantPast) }
    }

    private var sshDirectoryGroups: [SSHDirectoryGroup] {
        let sessions = sshSessionsForList
        let serverCount = Set(sessions.map(\.serverId)).count
        struct Key: Hashable {
            var serverId: UUID
            var path: String
        }
        var buckets: [Key: [TerminalSession]] = [:]
        for session in sessions {
            buckets[Key(serverId: session.serverId, path: sshWorkingDirectory(session)), default: []].append(session)
        }
        return buckets.map { key, rows in
            let sorted = rows.sorted {
                ($0.lastConnectedAt ?? $0.createdAt) > ($1.lastConnectedAt ?? $1.createdAt)
            }
            let title = key.path.isEmpty ? "~" : DesktopPath.abbreviate(key.path)
            let serverName = store.server(for: key.serverId)?.name ?? ""
            let newest = sorted[0]
            let kinds = Set(sorted.map(\.agentKind))
            return SSHDirectoryGroup(
                id: "\(key.serverId.uuidString)|\(key.path)",
                serverId: key.serverId,
                projectId: sshProjectID(serverId: key.serverId, path: key.path, fallback: newest.projectId),
                path: key.path,
                title: title,
                subtitle: serverCount > 1 && !serverName.isEmpty ? serverName : nil,
                sessions: sorted,
                agentKind: newest.agentKind,
                mixedAgents: kinds.count > 1
            )
        }
        .sorted {
            let left = $0.sessions.first?.lastConnectedAt ?? $0.sessions.first?.createdAt ?? .distantPast
            let right = $1.sessions.first?.lastConnectedAt ?? $1.sessions.first?.createdAt ?? .distantPast
            return left > right
        }
    }

    /// The same remote chat can be filed under more than one host project. Keep one row.
    private var sshSessionsForList: [TerminalSession] {
        var best: [UUID: TerminalSession] = [:]
        for session in filteredSessions {
            if let existing = best[session.id] {
                best[session.id] = preferredSSHSession(existing, session)
            } else {
                best[session.id] = session
            }
        }
        return best.values.sorted {
            ($0.lastConnectedAt ?? $0.createdAt) > ($1.lastConnectedAt ?? $1.createdAt)
        }
    }

    private func preferredSSHSession(_ lhs: TerminalSession, _ rhs: TerminalSession) -> TerminalSession {
        let leftFits = configuredProjectPath(lhs) == sshWorkingDirectory(lhs)
        let rightFits = configuredProjectPath(rhs) == sshWorkingDirectory(rhs)
        if leftFits != rightFits { return leftFits ? lhs : rhs }
        let leftDate = lhs.lastConnectedAt ?? lhs.createdAt
        let rightDate = rhs.lastConnectedAt ?? rhs.createdAt
        return leftDate >= rightDate ? lhs : rhs
    }

    private func sshWorkingDirectory(_ session: TerminalSession) -> String {
        let cwd = SessionPathGroup.normalize(session.agentCwd)
        if !cwd.isEmpty { return cwd }
        return configuredProjectPath(session)
    }

    private func configuredProjectPath(_ session: TerminalSession) -> String {
        SessionPathGroup.normalize(store.project(for: session)?.remotePath)
    }

    private func sshProjectID(serverId: UUID, path: String, fallback: UUID) -> UUID {
        guard let server = store.server(for: serverId) else { return fallback }
        if let match = server.projects.first(where: { SessionPathGroup.normalize($0.remotePath) == path }) {
            return match.id
        }
        return fallback
    }

    private func visibleChats(in group: DesktopRepoGroup) -> [DesktopAgentChat] {
        guard !expandedGroupIDs.contains(group.id), group.chats.count > sessionGroupPreviewLimit else {
            return group.chats
        }
        return Array(group.chats.prefix(sessionGroupPreviewLimit))
    }

    private func visibleSessions(in group: SSHDirectoryGroup) -> [TerminalSession] {
        guard !expandedGroupIDs.contains(group.id), group.sessions.count > sessionGroupPreviewLimit else {
            return group.sessions
        }
        return Array(group.sessions.prefix(sessionGroupPreviewLimit))
    }

    @ViewBuilder
    private func repositoryRow(_ item: RepositoryListItem) -> some View {
        switch item {
        case .header(let group):
            SessionGroupHeader(
                title: group.title,
                subtitle: group.subtitle,
                showsAdd: !group.path.isEmpty,
                addLabel: String(format: String(localized: "New conversation in %@"), group.title),
                onAdd: { quickCreateDesktop(group) }
            )
            .listRowInsets(Self.groupHeaderInsets)
            .listRowSeparator(.hidden, edges: .bottom)
        case .chat(let chat, _):
            Button {
                selectedDesktopChat = chat
            } label: {
                DesktopAgentChatRow(chat: chat, detail: chat.listModeLabel)
            }
            .buttonStyle(.plain)
            .listRowInsets(Self.conversationInsets)
        case .more(let groupID, _):
            moreSessionsButton(groupID)
        }
    }

    @ViewBuilder
    private func sshRow(_ item: SSHListItem) -> some View {
        switch item {
        case .header(let group):
            SessionGroupHeader(
                title: group.title,
                subtitle: group.subtitle,
                showsAdd: true,
                addLabel: String(format: String(localized: "New conversation in %@"), group.title),
                onAdd: { quickCreateSSH(group) }
            )
            .listRowInsets(Self.groupHeaderInsets)
            .listRowSeparator(.hidden, edges: .bottom)
        case .session(let session, _):
            sessionRow(for: session, detail: session.listModeLabel)
                .listRowInsets(Self.conversationInsets)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        sessionsPendingDelete = [session]
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Session", systemImage: "trash")
                    }
                    .tint(.red)
                }
        case .more(let groupID, _):
            moreSessionsButton(groupID)
        }
    }

    private func moreSessionsButton(_ groupID: String) -> some View {
        Button {
            expandedGroupIDs.insert(groupID)
        } label: {
            Text(String(localized: "More"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .listRowInsets(Self.moreInsets)
    }

    private func quickCreateDesktop(_ group: DesktopRepoGroup) {
        guard !group.path.isEmpty,
              let desk = store.desktops.first(where: { $0.id == group.desktopId }) else { return }
        let title = String(localized: "New Agent Chat")
        let tag = String(UUID().uuidString.prefix(8)).lowercased()
        let surface: DesktopNewSessionSurface = group.quickCreateAsCursorClient ? .client : .terminal
        let chat = makeNewDesktopAgentChat(
            desk: desk,
            kind: group.agentKind,
            surface: surface,
            title: title,
            directory: group.path,
            tag: tag
        )
        newDesktopChatId = chat.id
        selectedDesktopChat = chat
    }

    private func quickCreateSSH(_ group: SSHDirectoryGroup) {
        let session = TerminalSession(
            serverId: group.serverId,
            projectId: group.projectId,
            displayName: String(localized: "New Agent Chat"),
            agentKind: group.agentKind,
            agentChatId: nil,
            agentCwd: group.path.isEmpty ? nil : group.path
        )
        store.upsertSession(session)
        if let onPickSession {
            onPickSession(session)
        } else if let selectedSessionId {
            selectedSessionId.wrappedValue = session.id
        } else if let sessionPath {
            sessionPath.wrappedValue.append(session.id)
        } else {
            createdSession = session
        }
    }

    private func isCurrentSSH(_ session: TerminalSession) -> Bool {
        if highlightedSessionIds.contains(session.id) { return true }
        return selectedSessionId?.wrappedValue == session.id
    }

    @ViewBuilder
    private func sessionRow(for session: TerminalSession, detail: String? = nil) -> some View {
        if let onPickSession {
            Button {
                onPickSession(session)
            } label: {
                SessionRowView(session: session, isCurrent: isCurrentSSH(session), detail: detail)
            }
            .buttonStyle(.plain)
            .modifier(SessionRowHighlight(isHighlighted: isCurrentSSH(session)))
            .contextMenu {
                if let onOpenInNewWindow {
                    Button {
                        onOpenInNewWindow(session)
                    } label: {
                        Label("Open in New Window", systemImage: "square.on.square")
                    }
                }
            }
        } else if let selectedSessionId {
            Button {
                selectedSessionId.wrappedValue = session.id
            } label: {
                SessionRowView(session: session, isCurrent: isCurrentSSH(session), detail: detail)
            }
            .buttonStyle(.plain)
            .modifier(SessionRowHighlight(isHighlighted: isCurrentSSH(session)))
        } else {
            NavigationLink(value: session.id) {
                SessionRowView(session: session, isCurrent: isCurrentSSH(session), detail: detail)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Only override row background when highlighted — keep system black/white list chrome otherwise.
struct SessionRowHighlight: ViewModifier {
    var isHighlighted: Bool

    func body(content: Content) -> some View {
        if isHighlighted {
            content.listRowBackground(Color.accentColor.opacity(0.12))
        } else {
            content
        }
    }
}

private struct SessionRowView: View {
    let session: TerminalSession
    var isCurrent: Bool = false
    var detail: String? = nil

    var body: some View {
        ConversationLine(
            title: session.displayName,
            date: session.lastConnectedAt ?? session.createdAt,
            isCurrent: isCurrent,
            detail: detail
        )
    }
}

struct SessionCreatorView: View {
    enum HostChoice: Hashable {
        case ssh(UUID)
        case desktop(UUID)
    }

    /// Matches session list badges: terminal = CLI in screen; client = desktop app mirror.
    private enum SessionSurfacePicker: String, CaseIterable, Hashable {
        case terminal
        case client

        var desktopSurface: DesktopNewSessionSurface {
            switch self {
            case .terminal: return .terminal
            case .client: return .client
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    let serverFilter: UUID?
    let desktopFilter: UUID?
    let onCreate: (TerminalSession) -> Void
    var onCreateDesktop: ((DesktopAgentChat) -> Void)? = nil

    @State private var name = ""
    @State private var host: HostChoice?
    @State private var selectedProjectId: UUID?
    /// Desktop project directory; empty means "other folder" typed into `customDirectory`.
    @State private var desktopDirectory = ""
    @State private var customDirectory = ""
    @State private var agentKind: AgentKind = .cursor
    @State private var surface: SessionSurfacePicker = .terminal

    private var availableServers: [ServerProfile] {
        if desktopFilter != nil { return [] }
        if let serverFilter, let server = store.server(for: serverFilter) {
            return [server]
        }
        return store.servers
    }

    private var availableDesktops: [PairedDesktop] {
        guard serverFilter == nil else { return [] }
        guard let desktopFilter else { return store.desktops }
        return store.desktops.filter { $0.id == desktopFilter }
    }

    private var availableProjects: [ProjectPath] {
        guard case .ssh(let id) = host, let server = store.server(for: id) else { return [] }
        return server.projects
    }

    /// Project directories known on a desktop, most recently used first.
    private var desktopDirectories: [String] {
        guard case .desktop(let id) = host else { return [] }
        var seen = Set<String>()
        return store.desktopAgentChats
            .filter { $0.desktopId == id }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { $0.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var isDesktop: Bool {
        if case .desktop = host { return true }
        return false
    }

    private var chosenDirectory: String {
        let dir = desktopDirectory.isEmpty ? customDirectory : desktopDirectory
        return dir.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveSurface: DesktopNewSessionSurface {
        isDesktop ? surface.desktopSurface : .terminal
    }

    private var canCreateNewClientChat: Bool {
        agentKind == .cursor
    }

    private var canCreate: Bool {
        switch host {
        case .ssh:
            return selectedProjectId != nil
        case .desktop:
            if chosenDirectory.isEmpty { return false }
            if effectiveSurface == .client && !canCreateNewClientChat { return false }
            return true
        case nil:
            return false
        }
    }

    @ViewBuilder
    private var creatorFooter: some View {
        if !isDesktop {
            Text(String(localized: "Linux SSH servers have no desktop client to mirror. Sessions always use the CLI on the server (Cursor: agent persist; others: GNU screen)."))
        } else if effectiveSurface == .client {
            if canCreateNewClientChat {
                Text(String(localized: "Starts a new Cursor IDE chat for this folder and mirrors it here (client · bubbles)."))
            } else {
                Text(String(format: String(localized: "KoKo cannot start a new %@ desktop-app chat from here. Open the chat in the app on your computer, then pick it from the list (client badge), or choose Terminal to start the CLI."), agentKind.displayName))
            }
        } else {
            Text(String(localized: "Starts the agent CLI in a GNU screen session in this folder on the desktop. It keeps running after the phone disconnects."))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title (optional)", text: $name)
                    Picker("Host", selection: $host) {
                        ForEach(availableServers) { server in
                            Text(server.name).tag(Optional(HostChoice.ssh(server.id)))
                        }
                        ForEach(availableDesktops) { desk in
                            Label(desk.name, systemImage: "desktopcomputer").tag(Optional(HostChoice.desktop(desk.id)))
                        }
                    }
                }
                Section {
                    if isDesktop {
                        Picker("Project", selection: $desktopDirectory) {
                            ForEach(desktopDirectories, id: \.self) { dir in
                                Text(verbatim: DesktopPath.abbreviate(dir)).tag(dir)
                            }
                            Text(String(localized: "Other folder…")).tag("")
                        }
                        if desktopDirectory.isEmpty {
                            TextField(String(localized: "Folder path on the desktop"), text: $customDirectory)
                                .font(.callout.monospaced())
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    } else {
                        Picker("Project", selection: $selectedProjectId) {
                            ForEach(availableProjects) { project in
                                Text(verbatim: project.displayPath).tag(Optional(project.id))
                            }
                        }
                    }
                    Picker("Agent", selection: $agentKind) {
                        ForEach(AgentKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    if isDesktop {
                        Picker(String(localized: "Session type"), selection: $surface) {
                            Text(String(localized: "Terminal")).tag(SessionSurfacePicker.terminal)
                            Text(String(localized: "Client")).tag(SessionSurfacePicker.client)
                        }
                        .pickerStyle(.segmented)
                    } else if host != nil {
                        LabeledContent(String(localized: "Session type")) {
                            Text(String(localized: "Terminal"))
                        }
                    }
                } footer: {
                    creatorFooter
                }
            }
            .navigationTitle("New Conversation")
            .onAppear {
                if host == nil {
                    host = availableServers.first.map { .ssh(serverFilter ?? $0.id) }
                        ?? availableDesktops.first.map { .desktop($0.id) }
                }
                resetProject()
                if name.isEmpty {
                    name = String(localized: "New Agent Chat")
                }
            }
            .onChange(of: host) { _, _ in
                resetProject()
                if !isDesktop { surface = .terminal }
            }
            .onChange(of: agentKind) { _, _ in
                if surface == .client && !canCreateNewClientChat {
                    surface = .terminal
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(!canCreate)
                }
            }
        }
    }

    private func resetProject() {
        selectedProjectId = availableProjects.first?.id
        desktopDirectory = desktopDirectories.first ?? ""
    }

    private func create() {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "New Agent Chat")
            : name
        switch host {
        case .ssh(let serverId):
            guard let selectedProjectId else { return }
            onCreate(TerminalSession(
                serverId: serverId,
                projectId: selectedProjectId,
                displayName: title,
                agentKind: agentKind,
                agentChatId: nil
            ))
        case .desktop(let deskId):
            guard let desk = store.desktops.first(where: { $0.id == deskId }) else { return }
            let tag = UUID().uuidString.prefix(8).lowercased()
            let chat = makeNewDesktopAgentChat(
                desk: desk,
                kind: agentKind,
                surface: effectiveSurface,
                title: title,
                directory: chosenDirectory,
                tag: String(tag)
            )
            onCreateDesktop?(chat)
        case nil:
            return
        }
        dismiss()
    }
}

private struct DesktopAgentChatRow: View {
    let chat: DesktopAgentChat
    var detail: String? = nil

    var body: some View {
        ConversationLine(
            title: chat.displayTitle,
            date: chat.updatedAt,
            isLive: chat.screenAlive,
            detail: detail
        )
    }
}

/// AI conversation on a paired desktop, attached in the same terminal editor as SSH.
private struct DesktopAgentChatTerminalView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var workspace: TerminalWorkspace
    let chat: DesktopAgentChat
    var initialMode: RemoteBootstrap.LaunchMode = .preferExisting
    var onClose: () -> Void = {}

    @State private var showTerminateConfirm = false
    @State private var showForceNewConfirm = false
    @State private var showInfo = false
    @State private var didInitialConnect = false
    @State private var showLoginSheet = false
    @State private var showRenameChat = false
    @State private var renameChatDraft = ""
    @State private var openSubChat: IDEChatState.SubChat?
    /// Model search and the other bar sheets need the keyboard; the chat composer must let go.
    @State private var suspendComposerAutofocus = false
    /// Set by the Disconnect menu item: coming back to the app must not silently reattach.
    @State private var userDisconnected = false
    @State private var guiBlocker: HostGUIBlocker?
    @State private var guiGateReady = false
    @State private var bypassedGUIGate = false

    private var desk: PairedDesktop? {
        store.desktops.first(where: { $0.id == chat.desktopId })
    }

    private var projectPath: String {
        if let cwd = workspace.ideState?.cwd, !cwd.isEmpty { return cwd }
        return chat.cwd ?? ""
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    if chat.mirrorsIDEChat, chat.agentKind == .cursor || workspace.isIDETurnBusy {
                        IDEChatBar(
                            state: workspace.ideState,
                            workspace: workspace,
                            openSubChat: $openSubChat,
                            suspendComposerAutofocus: $suspendComposerAutofocus,
                            showsCursorChrome: chat.agentKind == .cursor
                        )
                        Divider()
                    }
                    connectionBanner
                    if chat.mirrorsIDEChat {
                        IDEChatView(workspace: workspace, suspendComposerAutofocus: suspendComposerAutofocus)
                    } else {
                        TerminalContainerView(workspace: workspace)
                    }
                }
                if chat.mirrorsIDEChat, let guiBlocker, guiGateReady {
                    ClientGUIGateOverlay(
                        blocker: guiBlocker,
                        onOpenDesktop: jumpToRemoteDesktop,
                        onContinue: continueClientAnyway
                    )
                } else if chat.mirrorsIDEChat, !guiGateReady {
                    ClientGUIGateCheckingOverlay()
                }
            }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "Close")) {
                            userDisconnected = true
                            // Nil the cover item ourselves. Environment.dismiss()
                            // inside this NavigationStack often only flickers —
                            // the binding stays set and onAppear reconnects.
                            onClose()
                            workspace.close()
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            HStack(spacing: 6) {
                                connectionBadge
                                Text(workspace.ideState.map { $0.name.isEmpty ? chat.displayTitle : $0.name } ?? chat.displayTitle)
                                    .font(.headline)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            if !projectPath.isEmpty {
                                Text(verbatim: DesktopPath.abbreviate(projectPath))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Reconnect") { connect(mode: .preferExisting) }
                            if chat.mirrorsIDEChat {
                                Button(String(localized: "New CLI Session in This Project")) { showForceNewConfirm = true }
                                if chat.agentKind == .cursor {
                                    Button("Rename Chat") {
                                        renameChatDraft = workspace.ideState?.name ?? chat.displayTitle
                                        showRenameChat = true
                                    }
                                }
                            } else {
                                Button("New Agent Session") { showForceNewConfirm = true }
                            }
                            Button(String(localized: "Session Info")) { showInfo = true }
                            Button("Disconnect") {
                                userDisconnected = true
                                workspace.disconnect()
                            }
                            if !chat.mirrorsIDEChat {
                                Button("Terminate Session", role: .destructive) { showTerminateConfirm = true }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Session")
                    }
                }
        }
        .onAppear {
            if chat.mirrorsIDEChat {
                Task { await prepareClientSession() }
            } else if !didInitialConnect, initialMode == .forceNew {
                didInitialConnect = true
                connect(mode: .forceNew)
            } else if workspace.connectionNote != nil {
                connect(mode: .preferExisting)
            } else {
                ensureConnected()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: workspace.enterBackground()
            case .active:
                workspace.enterForeground()
                if chat.mirrorsIDEChat {
                    Task { await prepareClientSession(fromForeground: true) }
                } else {
                    ensureConnected()
                }
            default: break
            }
        }
        .onChange(of: workspace.detectedLoginURL) { _, url in
            if url != nil { showLoginSheet = true }
        }
        .onChange(of: workspace.detectedLoginCode) { _, code in
            if code != nil { showLoginSheet = true }
        }
        .confirmationDialog("Terminate Session?", isPresented: $showTerminateConfirm) {
            Button("Terminate", role: .destructive) { workspace.terminateSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(String(localized: "Stops the AI process on the desktop. Disconnect only closes this phone's link; the AI keeps running."))
        }
        .confirmationDialog("Start a new agent?", isPresented: $showForceNewConfirm) {
            Button("New Agent Session", role: .destructive) { connect(mode: .forceNew) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops the current remote session and starts a fresh one.")
        }
        .navigationDestination(item: $openSubChat) { sub in
            IDESubChatScreen(workspace: workspace, sub: sub)
        }
        .alert("Rename Chat", isPresented: $showRenameChat) {
            TextField(String(localized: "Title"), text: $renameChatDraft)
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Save")) { workspace.renameIDEChat(renameChatDraft) }
        }
        .sheet(isPresented: $showLoginSheet) {
            AgentLoginView(
                agentKind: workspace.loginAgentKind ?? chat.agentKind,
                loginURL: workspace.detectedLoginURL ?? "",
                loginCode: workspace.detectedLoginCode,
                onPasteCodeToTerminal: { workspace.submitLoginCode($0) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showInfo) {
            DesktopAgentChatInfoView(chat: chat)
                .presentationDetents([.medium])
        }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch workspace.connectionState {
        case .connected:
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green)
        case .connecting, .reconnecting:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
        case .ended:
            Image(systemName: "moon.fill").font(.system(size: 11)).foregroundStyle(.secondary)
        case .disconnected:
            Image(systemName: "circle").font(.system(size: 7)).foregroundStyle(.secondary)
        }
    }

    /// Says why the chat is not live and offers a reconnect; hidden while connected.
    @ViewBuilder
    private var connectionBanner: some View {
        let state = workspace.connectionState
        let hasHistory = !workspace.ideMessages.isEmpty
        let content: (text: String, busy: Bool, retry: Bool)? = {
            switch state {
            case .connected:
                return nil
            case .connecting:
                return (hasHistory ? String(localized: "Reconnecting…") : String(localized: "Connecting…"), true, false)
            case .reconnecting:
                return (String(localized: "Connection lost — reconnecting…"), true, false)
            case .disconnected:
                return (workspace.connectionNote ?? String(localized: "Disconnected. Messages won't update until you reconnect."), false, true)
            case .failed(let message):
                return (String(format: String(localized: "Couldn't connect: %@"), message), false, true)
            case .ended:
                return (String(localized: "The session on the computer has ended."), false, true)
            }
        }()
        if let content {
            HStack(spacing: 8) {
                if content.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "bolt.horizontal.circle")
                        .foregroundStyle(.orange)
                }
                Text(content.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if content.retry {
                    Button(String(localized: "Reconnect")) { connect(mode: .preferExisting) }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .secondarySystemBackground))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func ensureConnected() {
        if chat.mirrorsIDEChat, guiBlocker != nil { return }
        switch workspace.connectionState {
        case .connected, .connecting, .reconnecting:
            return
        case .disconnected, .failed, .ended:
            guard !userDisconnected, workspace.connectionNote == nil else { return }
            connect(mode: .preferExisting)
        }
    }

    private func prepareClientSession(fromForeground: Bool = false) async {
        await refreshGUIGate()
        if guiBlocker != nil { return }
        if fromForeground {
            ensureConnected()
            return
        }
        if !didInitialConnect, initialMode == .forceNew {
            didInitialConnect = true
            connect(mode: .forceNew)
        } else if workspace.connectionNote != nil {
            didInitialConnect = true
            connect(mode: .preferExisting)
        } else {
            didInitialConnect = true
            ensureConnected()
        }
    }

    private func refreshGUIGate() async {
        guard chat.mirrorsIDEChat, !bypassedGUIGate, let desk else {
            guiBlocker = nil
            guiGateReady = true
            return
        }
        var snap = store.hostHealth(for: desk.id)?.snapshot
        if let fresh = try? await DesktopSessionHub.shared.fetchHostHealth(for: desk) {
            snap = fresh
        }
        guiBlocker = HostGUIBlocker.detect(from: snap)
        guiGateReady = true
    }

    private func jumpToRemoteDesktop() {
        guard let desk else { return }
        store.pendingOpenDesktopId = desk.id
        userDisconnected = true
        onClose()
        workspace.close()
    }

    private func continueClientAnyway() {
        bypassedGUIGate = true
        guiBlocker = nil
        guiGateReady = true
        connect(mode: .preferExisting)
    }

    private func connect(mode: RemoteBootstrap.LaunchMode) {
        userDisconnected = false
        guard let desk, desk.canReconnect else {
            workspace.reportSetupFailure(String(localized: "Re-pair required — scan a fresh Agent QR."))
            return
        }
        var opening = chat
        if let live = workspace.currentDesktopChat {
            if opening.chatId.isEmpty, !live.chatId.isEmpty {
                opening.chatId = live.chatId
            }
            if live.mirrorsIDEChat {
                opening.source = "client"
                opening.clientName = live.clientName ?? opening.clientName ?? live.agentKind.displayName
            }
        }
        if chat.mirrorsIDEChat {
            opening.source = "client"
            if opening.clientName?.isEmpty ?? true {
                opening.clientName = chat.clientName ?? chat.agentKind.displayName
            }
        }
        workspace.connectDesktopAgent(desk: desk, chat: opening, mode: mode)
    }
}

private struct ClientGUIGateCheckingOverlay: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).opacity(0.92).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(String(localized: "Checking the Mac display…"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ClientGUIGateOverlay: View {
    let blocker: HostGUIBlocker
    var onOpenDesktop: () -> Void
    var onContinue: () -> Void

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).opacity(0.96).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: blocker.systemImage)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(blocker.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(blocker.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onOpenDesktop) {
                    Text(String(localized: "Open Remote Desktop"))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button(String(localized: "Continue anyway"), action: onContinue)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 420)
        }
        .accessibilityElement(children: .contain)
    }
}

enum DesktopPath {
    /// `/Users/me/Downloads/KoKo` → `~/Downloads/KoKo` (desktop home is not known on the phone).
    static func abbreviate(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count >= 3, parts[0].isEmpty, parts[1] == "Users" || parts[1] == "home" {
            let rest = parts.dropFirst(3).joined(separator: "/")
            return rest.isEmpty ? "~" : "~/" + rest
        }
        return path.isEmpty ? "~" : path
    }

    static func relative(_ path: String, to root: String) -> String {
        guard !root.isEmpty, path.hasPrefix(root + "/") else { return abbreviate(path) }
        return String(path.dropFirst(root.count + 1))
    }
}

/// Cursor IDE controls above the mirrored chat: project, mode, model, changed files, review.
private struct IDEChatBar: View {
    let state: IDEChatState?
    @ObservedObject var workspace: TerminalWorkspace
    @Binding var openSubChat: IDEChatState.SubChat?
    @Binding var suspendComposerAutofocus: Bool
    var showsCursorChrome: Bool = true
    @State private var showFiles = false
    @State private var showModes = false
    @State private var showModels = false
    @State private var showSubChats = false
    @State private var confirmUndo = false
    @State private var showAttachSource = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []

    private var files: [IDEChatState.File] { state?.files ?? [] }
    private var fileCount: Int {
        let listed = files.count
        if let n = state?.filesChangedCount, n > listed { return n }
        return listed
    }
    private var subChats: [IDEChatState.SubChat] { state?.subChats ?? [] }

    var body: some View {
        // One swipeable row: every control keeps its natural width instead of being
        // squeezed into the screen and truncated.
        VStack(spacing: 0) {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Stop first while busy so it stays on-screen without scrolling past Mode/Model.
                if workspace.isIDETurnBusy {
                    Button { workspace.stopIDEGeneration() } label: {
                        chip(String(localized: "Stop"), systemImage: "stop.fill")
                    }
                }
                if showsCursorChrome {
                Button { presentSheet($showModes) } label: {
                    chip(
                        state?.modeName ?? String(localized: "Mode"),
                        systemImage: modeIcon(state?.mode),
                        busy: workspace.idePendingAction?.kind.isMode == true
                    )
                }
                Button { presentSheet($showModels) } label: {
                    chip(
                        state?.modelName ?? String(localized: "Model"),
                        systemImage: "cpu",
                        busy: workspace.idePendingAction?.kind.isModel == true
                    )
                }
                Button {
                    showAttachSource = true
                } label: {
                    chip(
                        String(localized: "Upload"),
                        systemImage: "paperclip",
                        busy: workspace.idePendingAction?.kind.isAttach == true
                    )
                }
                .disabled(workspace.connectionState != .connected)
                if !subChats.isEmpty {
                    Button { presentSheet($showSubChats) } label: {
                        chip(String(localized: "\(subChats.count) Background"), systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                Button { presentSheet($showFiles) } label: {
                    chip(String(localized: "\(fileCount) Files"), systemImage: "doc.on.doc")
                }
                .disabled(fileCount == 0)
                if !workspace.isIDETurnBusy, state?.pendingReview == true {
                    Button(String(localized: "Undo All")) { confirmUndo = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(workspace.idePendingAction?.kind.isReview == true)
                    Button(String(localized: "Keep All")) { workspace.requestIDEReview(keep: true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(workspace.idePendingAction?.kind.isReview == true)
                }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .disabled(state == nil)
        }
        if let activity = workspace.idePendingAction?.text {
            IDEActivityStatus(text: activity)
        }
        }
        .background(.bar)
        .onChange(of: workspace.connectionState) { _, state in
            if state != .connected { workspace.cancelIDEPending() }
        }
        .sheet(isPresented: $showFiles, onDismiss: releaseComposerFocus) {
            IDEChangedFilesView(state: state, workspace: workspace)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showModes, onDismiss: releaseComposerFocus) {
            IDEModePickerSheet(state: state, onPick: { workspace.requestIDEMode($0) })
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showModels, onDismiss: releaseComposerFocus) {
            IDEModelPickerSheet(
                state: state,
                activity: workspace.idePendingAction?.text,
                onPick: { workspace.requestIDEModel($0) },
                onParameter: { id, value in
                    workspace.requestIDEModelParameter(id: id, value: value)
                }
            )
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSubChats, onDismiss: releaseComposerFocus) {
            IDESubChatPickerSheet(subChats: subChats) { sub in
                showSubChats = false
                openSubChat = sub
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog(String(localized: "Undo all changes?"), isPresented: $confirmUndo, titleVisibility: .visible) {
            Button(String(localized: "Undo All"), role: .destructive) { workspace.requestIDEReview(keep: false) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Reverts every file this chat changed in Cursor on the computer."))
        }
        .confirmationDialog(String(localized: "Upload to Cursor"), isPresented: $showAttachSource, titleVisibility: .visible) {
            Button(String(localized: "Photo Library")) { showPhotoPicker = true }
            Button(String(localized: "Files")) { showFileImporter = true }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Images are pasted into the chat input. Other files are saved under .koko-uploads in the project."))
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: 1,
            matching: .images
        )
        .onChange(of: photoItems) { _, items in
            guard let item = items.first else { return }
            photoItems = []
            Task { await importPhoto(item) }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await importFile(url) }
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        do {
            if let picked = try await item.loadTransferable(type: IDEPickedImage.self) {
                workspace.attachIDEImage(picked.image)
                return
            }
            workspace.reportIDEAttachError(String(localized: "Couldn't read that photo"))
        } catch {
            workspace.reportIDEAttachError(String(localized: "Couldn't read that photo"))
        }
    }

    private func importFile(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let name = url.lastPathComponent
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            if mime.hasPrefix("image/"), let image = UIImage(data: data) {
                let lower = name.lowercased()
                let preferred = lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
                    ? name
                    : "photo.jpg"
                workspace.attachIDEImage(image, preferredName: preferred)
            } else {
                workspace.attachIDEFile(name: name, mime: mime, data: data)
            }
        } catch {
            workspace.reportIDEAttachError(String(localized: "Couldn't read that file"))
        }
    }

    private func presentSheet(_ flag: Binding<Bool>) {
        suspendComposerAutofocus = true
        flag.wrappedValue = true
    }

    private func releaseComposerFocus() {
        if !showFiles && !showModes && !showModels && !showSubChats {
            suspendComposerAutofocus = false
        }
    }

    private func chip(_ text: String, systemImage: String, busy: Bool = false) -> some View {
        HStack(spacing: 4) {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary)
        .clipShape(Capsule())
    }

    private func modeIcon(_ modeID: String?) -> String {
        switch modeID?.lowercased() {
        case "plan": return "map"
        case "debug": return "ant"
        case "multitask": return "square.stack.3d.up"
        case "ask": return "bubble.left"
        default: return "infinity"
        }
    }
}

private struct IDEModePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let state: IDEChatState?
    let onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(state?.modes ?? []) { mode in
                    Button {
                        onPick(mode.id)
                        dismiss()
                    } label: {
                        HStack {
                            Label(mode.name, systemImage: mode.id == state?.mode ? "checkmark.circle.fill" : "circle")
                            Spacer()
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .navigationTitle(String(localized: "Mode"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }
}

private struct IDEPickedImage: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard let image = UIImage(data: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return IDEPickedImage(image: image)
        }
    }
}

/// Same shape as the connection banner: a spinner and one line, while Cursor catches up.
private struct IDEActivityStatus: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct IDEModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let state: IDEChatState?
    var activity: String? = nil
    let onPick: (String) -> Void
    let onParameter: (String, String) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var models: [IDEChatState.Option] {
        let all = state?.models ?? []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q) }
    }

    private var currentParameters: [IDEChatState.ModelParameter] {
        state?.models?.first(where: { $0.id == state?.model })?.parameters ?? []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let activity {
                    IDEActivityStatus(text: activity)
                        .background(Color(uiColor: .secondarySystemBackground))
                }
                TextField(String(localized: "Search models"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                List {
                if query.isEmpty, !currentParameters.isEmpty {
                    Section {
                        ForEach(currentParameters) { parameter in
                            if parameter.kind == "boolean" {
                                Toggle(
                                    parameter.name,
                                    isOn: Binding(
                                        get: { parameter.selected == "true" },
                                        set: { onParameter(parameter.id, $0 ? "true" : "false") }
                                    )
                                )
                            } else {
                                Menu {
                                    ForEach(parameter.values) { value in
                                        Button {
                                            onParameter(parameter.id, value.id)
                                        } label: {
                                            if value.id == parameter.selected {
                                                Label(value.name, systemImage: "checkmark")
                                            } else {
                                                Text(value.name)
                                            }
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(parameter.name)
                                        Spacer()
                                        Text(parameter.selectedName)
                                            .foregroundStyle(.secondary)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                    } header: {
                        Text(state?.modelName ?? String(localized: "Model"))
                    }
                }

                Section(String(localized: "Model")) {
                    ForEach(models) { model in
                        Button {
                            onPick(model.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text(model.name)
                                    .lineLimit(2)
                                Spacer()
                                if model.id == state?.model {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(String(localized: "Model"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    searchFocused = true
                }
            }
        }
    }
}

private struct IDESubChatPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let subChats: [IDEChatState.SubChat]
    let onOpen: (IDEChatState.SubChat) -> Void

    var body: some View {
        NavigationStack {
            List(subChats) { sub in
                Button(sub.name) {
                    onOpen(sub)
                    dismiss()
                }
            }
            .navigationTitle(String(localized: "Background subagents"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }
}

private struct IDESubChatScreen: View {
    @ObservedObject var workspace: TerminalWorkspace
    let sub: IDEChatState.SubChat

    var body: some View {
        IDEChatView(workspace: workspace, subComposerId: sub.composerId, readOnly: true)
            .navigationTitle(sub.name)
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct IDEChangedFilesView: View {
    @Environment(\.dismiss) private var dismiss
    let state: IDEChatState?
    @ObservedObject var workspace: TerminalWorkspace
    @State private var previewPath: String?
    @State private var showingPreview = false

    var body: some View {
        NavigationStack {
            List {
                if let state {
                    Section {
                        ForEach(state.files ?? []) { file in
                            Button {
                                workspace.requestIDEFileDiff(path: file.path)
                                previewPath = file.path
                                showingPreview = true
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(DesktopPath.relative(file.path, to: state.cwd))
                                            .font(.callout.monospaced())
                                        if file.new {
                                            Text(String(localized: "New file"))
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        }
                                    }
                                } icon: {
                                    Image(systemName: file.new ? "doc.badge.plus" : "doc.text")
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    } header: {
                        Text(verbatim: "+\(state.linesAdded)  −\(state.linesRemoved)")
                    }
                }
            }
            .navigationTitle(String(localized: "Changed Files"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showingPreview, onDismiss: { previewPath = nil }) {
                IDEChangedFilePreview(workspace: workspace, path: previewPath ?? "")
            }
        }
    }

    private func matchesPath(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasSuffix(rhs) || rhs.hasSuffix(lhs)
    }
}

/// Observes the workspace so the sheet updates when the diff arrives, instead of
/// staying on the loading state captured when it was presented.
private struct IDEChangedFilePreview: View {
    @ObservedObject var workspace: TerminalWorkspace
    let path: String

    var body: some View {
        if let preview = workspace.ideFilePreview, path.isEmpty || matches(preview.path, path) {
            if let diff = preview.diff {
                IDEFileDiffSheet(
                    filename: (preview.path as NSString).lastPathComponent,
                    diff: diff
                )
                .presentationDetents([.large])
            } else {
                ContentUnavailableView(
                    String(localized: "Couldn't open this file"),
                    systemImage: "doc.text",
                    description: Text(preview.error ?? String(localized: "Cursor did not return a diff for this file."))
                )
                .presentationDetents([.medium])
            }
        } else {
            ProgressView(String(localized: "Loading…"))
                .presentationDetents([.medium])
        }
    }

    private func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasSuffix(rhs) || rhs.hasSuffix(lhs)
    }
}

private struct DesktopAgentChatInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let chat: DesktopAgentChat

    var body: some View {
        NavigationStack {
            List {
                LabeledContent(String(localized: "Title"), value: chat.displayTitle)
                LabeledContent(String(localized: "Agent"), value: chat.agentKind.displayName)
                LabeledContent(String(localized: "Desktop"), value: chat.desktopName)
                if let origin = chat.originLabel {
                    LabeledContent(String(localized: "Source"), value: origin)
                }
                LabeledContent("ID", value: chat.chatId)
                if let cwd = chat.cwd, !cwd.isEmpty {
                    LabeledContent("cwd", value: cwd)
                }
                LabeledContent(String(localized: "Screen"), value: chat.screenName)
            }
            .navigationTitle(chat.agentKind.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) { dismiss() }
                }
            }
        }
    }
}
