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
    var serverFilter: UUID?
    var selectedSessionId: Binding<UUID?>? = nil
    @State private var showingCreator = false
    @State private var sessionsPendingDelete: [TerminalSession] = []
    @State private var showDeleteConfirm = false
    @State private var isRefreshing = false
    @State private var syncError: String?
    @State private var hostKeyPrompt: HostKeyPrompt?
    @State private var deleteJob: SessionDeleteJob?

    private var filteredSessions: [TerminalSession] {
        let all = store.sessions.sorted { ($0.lastConnectedAt ?? $0.createdAt) > ($1.lastConnectedAt ?? $1.createdAt) }
        guard let serverFilter else { return all }
        return all.filter { $0.serverId == serverFilter }
    }

    var body: some View {
        List {
            if let syncError {
                Text(syncError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if filteredSessions.isEmpty {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pull to refresh — KoKo loads agent sessions and live screen names from the server")
                )
            } else {
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
            }
        }
        .navigationTitle("Sessions")
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
        .sheet(isPresented: $showingCreator) {
            SessionCreatorView(serverFilter: serverFilter) { session in
                store.upsertSession(session)
            }
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

        guard !targets.isEmpty else {
            syncError = String(localized: "Add a host and project path first")
            return
        }

        isRefreshing = true
        syncError = nil
        defer { isRefreshing = false }

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
        if !errors.isEmpty {
            syncError = errors.joined(separator: "\n")
        }
    }

    @ViewBuilder
    private func sessionRow(for session: TerminalSession) -> some View {
        if let selectedSessionId {
            Button {
                selectedSessionId.wrappedValue = session.id
            } label: {
                SessionRowView(session: session)
            }
            .listRowBackground(
                selectedSessionId.wrappedValue == session.id
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
        } else {
            NavigationLink {
                TerminalScreenView(session: session)
            } label: {
                SessionRowView(session: session)
            }
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
                Text("\(server.name) · \(project.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    let serverFilter: UUID?
    let onCreate: (TerminalSession) -> Void

    @State private var name = ""
    @State private var selectedServerId: UUID?
    @State private var selectedProjectId: UUID?
    @State private var selectedAgentKind: AgentKind = .cursor

    private var availableServers: [ServerProfile] {
        if let serverFilter, let server = store.server(for: serverFilter) {
            return [server]
        }
        return store.servers
    }

    private var availableProjects: [ProjectPath] {
        guard let selectedServerId, let server = store.server(for: selectedServerId) else { return [] }
        return server.projects
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title (optional)", text: $name)
                    Picker("Agent", selection: $selectedAgentKind) {
                        ForEach(AgentKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    Picker("Host", selection: $selectedServerId) {
                        ForEach(availableServers) { server in
                            Text(server.name).tag(Optional(server.id))
                        }
                    }
                    Picker("Project", selection: $selectedProjectId) {
                        ForEach(availableProjects) { project in
                            Text(project.label).tag(Optional(project.id))
                        }
                    }
                } footer: {
                    Text("Cursor uses agent persist. Claude, Codex, and Gemini run inside a named GNU screen session on the server.")
                }
            }
            .navigationTitle("New Conversation")
            .onAppear {
                selectedServerId = serverFilter ?? availableServers.first?.id
                selectedProjectId = availableProjects.first?.id
                if name.isEmpty {
                    name = String(localized: "New Agent Chat")
                }
            }
            .onChange(of: selectedServerId) { _, _ in
                selectedProjectId = availableProjects.first?.id
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard
                            let selectedServerId,
                            let selectedProjectId
                        else { return }
                        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? String(localized: "New Agent Chat")
                            : name
                        let session = TerminalSession(
                            serverId: selectedServerId,
                            projectId: selectedProjectId,
                            displayName: title,
                            agentKind: selectedAgentKind,
                            agentChatId: nil
                        )
                        onCreate(session)
                        dismiss()
                    }
                    .disabled(selectedServerId == nil || selectedProjectId == nil)
                }
            }
        }
    }
}
