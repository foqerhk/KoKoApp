import SwiftUI

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

struct SessionListView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var desktopHub = DesktopSessionHub.shared
    var serverFilter: UUID?
    var selectedSessionId: Binding<UUID?>? = nil
    var embedded: Bool = false
    var onPickSession: ((TerminalSession) -> Void)? = nil
    var onOpenInNewWindow: ((TerminalSession) -> Void)? = nil
    var highlightedSessionIds: Set<UUID> = []
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

    private var filteredSessions: [TerminalSession] {
        let all = store.sessions.sorted { ($0.lastConnectedAt ?? $0.createdAt) > ($1.lastConnectedAt ?? $1.createdAt) }
        guard let serverFilter else { return all }
        return all.filter { $0.serverId == serverFilter }
    }

    private var desktopChats: [DesktopAgentChat] {
        // SSH-only filter: hide desktop AI rows when browsing one SSH host.
        if serverFilter != nil { return [] }
        return store.desktopAgentChats.sorted { $0.updatedAt > $1.updatedAt }
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
                if !filteredSessions.isEmpty {
                    Section {
                        ForEach(filteredSessions) { session in
                            sessionRow(for: session)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    sessionsPendingDelete = [session]
                                    showDeleteConfirm = true
                                } label: {
                                    Label("Delete Session", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                    } header: {
                        Text(String(localized: "SSH"))
                    }
                }
                if !desktopChats.isEmpty {
                    Section {
                        ForEach(desktopChats) { chat in
                            Button {
                                selectedDesktopChat = chat
                            } label: {
                                DesktopAgentChatRow(chat: chat)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(String(localized: "Remote Desktop · AI"))
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
        .sheet(isPresented: $showingCreator, onDismiss: {
            if let chat = pendingNewDesktopChat {
                pendingNewDesktopChat = nil
                newDesktopChatId = chat.id
                selectedDesktopChat = chat
            }
        }) {
            SessionCreatorView(
                serverFilter: serverFilter,
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
                initialMode: chat.id == newDesktopChatId && !chat.mirrorsIDEChat ? .forceNew : .preferExisting
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
            if let serverFilter, let server = store.server(for: serverFilter) {
                return server.projects.map { (server, $0) }
            }
            return store.servers.flatMap { server in server.projects.map { (server, $0) } }
        }()
        let desktops = serverFilter == nil ? store.desktops.filter(\.canReconnect) : []

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

        // Paired Agents: use the live desktop tunnel when that host is streaming.
        // A parallel WSS Noise (RE2AgentChatClient) used to reset Agent crypto and
        // freeze the remote cursor / kill gestures.
        for desk in desktops {
            do {
                let conversations = try await desktopHub.listAgentChats(for: desk)
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
            } catch {
                errors.append("\(desk.name): \(error.localizedDescription)")
            }
        }

        if !errors.isEmpty {
            syncError = errors.joined(separator: "\n")
        }
    }

    @ViewBuilder
    private func sessionRow(for session: TerminalSession) -> some View {
        if let onPickSession {
            Button {
                onPickSession(session)
            } label: {
                SessionRowView(session: session)
            }
            .buttonStyle(.plain)
            .modifier(SessionRowHighlight(isHighlighted: highlightedSessionIds.contains(session.id)))
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
                SessionRowView(session: session)
            }
            .buttonStyle(.plain)
            .modifier(SessionRowHighlight(isHighlighted: selectedSessionId.wrappedValue == session.id))
        } else {
            NavigationLink(value: session.id) {
                SessionRowView(session: session)
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
    @EnvironmentObject private var store: AppStore
    let session: TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.displayName).font(.headline)
            if let server = store.server(for: session.serverId),
               let project = store.project(for: session) {
                Text(verbatim: "\(server.name) · \(project.displayPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 6) {
                Text(session.agentKind.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
                if session.agentChatId == nil {
                    Text(String(localized: "New"))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15))
                        .clipShape(Capsule())
                }
                if let updated = session.lastConnectedAt {
                    Text(updated, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SessionCreatorView: View {
    enum HostChoice: Hashable {
        case ssh(UUID)
        case desktop(UUID)
    }

    enum AgentChoice: Hashable {
        case cli(AgentKind)
        case cursorIDE
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    let serverFilter: UUID?
    let onCreate: (TerminalSession) -> Void
    var onCreateDesktop: ((DesktopAgentChat) -> Void)? = nil

    @State private var name = ""
    @State private var host: HostChoice?
    @State private var selectedProjectId: UUID?
    /// Desktop project directory; empty means "other folder" typed into `customDirectory`.
    @State private var desktopDirectory = ""
    @State private var customDirectory = ""
    @State private var agent: AgentChoice = .cli(.cursor)

    private var availableServers: [ServerProfile] {
        if let serverFilter, let server = store.server(for: serverFilter) {
            return [server]
        }
        return store.servers
    }

    private var availableDesktops: [PairedDesktop] {
        serverFilter == nil ? store.desktops : []
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

    private var agentChoices: [AgentChoice] {
        AgentKind.allCases.map { .cli($0) } + (isDesktop ? [.cursorIDE] : [])
    }

    private var chosenDirectory: String {
        let dir = desktopDirectory.isEmpty ? customDirectory : desktopDirectory
        return dir.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool {
        switch host {
        case .ssh: return selectedProjectId != nil && agent != .cursorIDE
        case .desktop: return !chosenDirectory.isEmpty
        case nil: return false
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
                    Picker("Agent", selection: $agent) {
                        ForEach(agentChoices, id: \.self) { choice in
                            switch choice {
                            case .cli(let kind): Text(kind.displayName).tag(choice)
                            case .cursorIDE: Text(String(localized: "Cursor IDE")).tag(choice)
                            }
                        }
                    }
                } footer: {
                    if agent == .cursorIDE {
                        Text(String(localized: "Opens a new chat in Cursor on the desktop for this folder and mirrors it here."))
                    } else if isDesktop {
                        Text(String(localized: "The CLI starts in this folder inside a GNU screen session on the desktop, so it keeps running when the phone disconnects."))
                    } else {
                        Text("Cursor uses agent persist. Claude, Codex, and Gemini run inside a named GNU screen session on the server.")
                    }
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
                if !isDesktop, agent == .cursorIDE { agent = .cli(.cursor) }
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
            guard let selectedProjectId, case .cli(let kind) = agent else { return }
            onCreate(TerminalSession(
                serverId: serverId,
                projectId: selectedProjectId,
                displayName: title,
                agentKind: kind,
                agentChatId: nil
            ))
        case .desktop(let deskId):
            guard let desk = store.desktops.first(where: { $0.id == deskId }) else { return }
            let tag = UUID().uuidString.prefix(8).lowercased()
            let chat: DesktopAgentChat
            switch agent {
            case .cursorIDE:
                chat = DesktopAgentChat(
                    id: UUID(), desktopId: deskId, desktopName: desk.name, agentKind: .cursor,
                    chatId: "", title: title, cwd: chosenDirectory, updatedAt: Date(),
                    screenName: "koko-cursor-ide-\(tag)", screenAlive: false,
                    source: "client", clientName: "Cursor IDE"
                )
            case .cli(let kind):
                // Matches the Agent's `koko-<kind>-<id>` screen rows, so the list keeps this chat.
                chat = DesktopAgentChat(
                    id: DesktopAgentChat.stableID(desktopId: deskId, kind: kind, chatId: tag),
                    desktopId: deskId, desktopName: desk.name, agentKind: kind,
                    chatId: tag, title: title, cwd: chosenDirectory, updatedAt: Date(),
                    screenName: "koko-\(kind.rawValue)-\(tag)", screenAlive: false,
                    source: "cli"
                )
            }
            onCreateDesktop?(chat)
        case nil:
            return
        }
        dismiss()
    }
}

private struct DesktopAgentChatRow: View {
    let chat: DesktopAgentChat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chat.displayTitle).font(.headline)
            Group {
                if let cwd = chat.cwd, !cwd.isEmpty {
                    Text(verbatim: "\(chat.desktopName) · \(DesktopPath.abbreviate(cwd))")
                } else {
                    Text(chat.desktopName)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            HStack(spacing: 6) {
                Text(chat.agentKind.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
                if let origin = chat.originLabel {
                    Text(origin)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(chat.isClientSession ? Color.blue.opacity(0.16) : Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
                if chat.screenAlive {
                    Text(String(localized: "Live"))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.18))
                        .clipShape(Capsule())
                }
                Text(chat.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// AI conversation on a paired desktop, attached in the same terminal editor as SSH.
private struct DesktopAgentChatTerminalView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var workspace: TerminalWorkspace
    let chat: DesktopAgentChat
    var initialMode: RemoteBootstrap.LaunchMode = .preferExisting

    @State private var showTerminateConfirm = false
    @State private var showForceNewConfirm = false
    @State private var showInfo = false
    @State private var didInitialConnect = false
    @State private var showLoginSheet = false

    private var desk: PairedDesktop? {
        store.desktops.first(where: { $0.id == chat.desktopId })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if chat.mirrorsIDEChat {
                    IDEChatBar(state: workspace.ideState, cwd: chat.cwd) { op, id in
                        workspace.sendIDEAction(op, id: id)
                    }
                    Divider()
                }
                TerminalContainerView(workspace: workspace)
            }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "Close")) {
                            workspace.disconnect()
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 6) {
                            connectionBadge
                            Text(workspace.ideState.map { $0.name.isEmpty ? chat.displayTitle : $0.name } ?? chat.displayTitle)
                                .font(.headline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Reconnect") { connect(mode: .preferExisting) }
                            if chat.mirrorsIDEChat {
                                Button(String(localized: "New CLI Session in This Project")) { showForceNewConfirm = true }
                            } else {
                                Button("New Agent Session") { showForceNewConfirm = true }
                            }
                            Button(String(localized: "Session Info")) { showInfo = true }
                            Button("Disconnect") { workspace.disconnect() }
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
            if !didInitialConnect, initialMode == .forceNew {
                didInitialConnect = true
                connect(mode: .forceNew)
            } else {
                ensureConnected()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: workspace.enterBackground()
            case .active:
                workspace.enterForeground()
                ensureConnected()
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

    private func ensureConnected() {
        switch workspace.connectionState {
        case .connected, .connecting, .reconnecting, .ended:
            return
        case .disconnected, .failed:
            connect(mode: .preferExisting)
        }
    }

    private func connect(mode: RemoteBootstrap.LaunchMode) {
        guard let desk, desk.canReconnect else {
            workspace.reportSetupFailure(String(localized: "Re-pair required — scan a fresh Agent QR."))
            return
        }
        workspace.connectDesktopAgent(desk: desk, chat: workspace.currentDesktopChat ?? chat, mode: mode)
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
    let cwd: String?
    let onAction: (String, String?) -> Void
    @State private var showFiles = false
    @State private var confirmUndo = false

    private var files: [IDEChatState.File] { state?.files ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(DesktopPath.abbreviate(state?.cwd ?? cwd ?? ""), systemImage: "folder")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            HStack(spacing: 8) {
                Menu {
                    ForEach(state?.modes ?? []) { mode in
                        Button { onAction("mode", mode.id) } label: {
                            if mode.id == state?.mode { Label(mode.name, systemImage: "checkmark") } else { Text(mode.name) }
                        }
                    }
                } label: {
                    chip(state?.modeName ?? String(localized: "Mode"), systemImage: "infinity")
                }
                Menu {
                    ForEach(state?.models ?? []) { model in
                        Button { onAction("model", model.id) } label: {
                            if model.id == state?.model { Label(model.name, systemImage: "checkmark") } else { Text(model.name) }
                        }
                    }
                } label: {
                    chip(state?.modelName ?? String(localized: "Model"), systemImage: "cpu")
                }
                Button { showFiles = true } label: {
                    chip("\(files.count)", systemImage: "doc.on.doc")
                }
                .disabled(files.isEmpty)
                Spacer(minLength: 0)
                if !files.isEmpty {
                    Button(String(localized: "Undo All")) { confirmUndo = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(String(localized: "Keep All")) { onAction("keepAll", nil) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .disabled(state == nil)
            if state?.bridge.needsReload == true {
                Text(String(localized: "Run Reload Window in Cursor on the computer to enable mode, model and Keep / Undo."))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .sheet(isPresented: $showFiles) {
            IDEChangedFilesView(state: state)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(String(localized: "Undo all changes?"), isPresented: $confirmUndo, titleVisibility: .visible) {
            Button(String(localized: "Undo All"), role: .destructive) { onAction("undoAll", nil) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Reverts every file this chat changed in Cursor on the computer."))
        }
    }

    private func chip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary)
            .clipShape(Capsule())
    }
}

private struct IDEChangedFilesView: View {
    @Environment(\.dismiss) private var dismiss
    let state: IDEChatState?

    var body: some View {
        NavigationStack {
            List {
                if let state {
                    Section {
                        ForEach(state.files ?? []) { file in
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
        }
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
