import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingEditor = false
    @State private var editingServer: ServerProfile?
    @State private var hostsPendingDelete: [ServerProfile] = []
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            if store.servers.isEmpty {
                ContentUnavailableView(
                    "No Hosts",
                    systemImage: "server.rack",
                    description: Text("Add an SSH server to connect AI agents over screen or Cursor persist")
                )
            } else {
                ForEach(store.servers) { server in
                    NavigationLink {
                        ServerDetailView(server: server)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(server.name).font(.headline)
                            Text("\(server.username)@\(server.host):\(server.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            hostsPendingDelete = [server]
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete Host", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
        }
        .navigationTitle("Hosts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingServer = store.makeDefaultSSHHost()
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            HostEditorView(server: editingServer ?? store.makeDefaultSSHHost()) { saved in
                store.upsertServer(saved)
            }
        }
        .sheet(isPresented: $showDeleteConfirm, onDismiss: {
            hostsPendingDelete = []
        }) {
            CountdownDeleteConfirmView(
                title: String(localized: "Delete Host?"),
                message: hostDeleteMessage,
                confirmLabel: String(localized: "Delete Host"),
                onConfirm: {
                    hostsPendingDelete.forEach(store.deleteServer)
                    hostsPendingDelete = []
                    showDeleteConfirm = false
                },
                onCancel: {
                    hostsPendingDelete = []
                    showDeleteConfirm = false
                }
            )
        }
    }

    private var hostDeleteMessage: String {
        if hostsPendingDelete.count == 1, let host = hostsPendingDelete.first {
            return String(
                format: String(localized: "Delete %@? Related sessions on this device will also be removed."),
                host.name
            )
        }
        return String(localized: "Delete the selected hosts? Related sessions on this device will also be removed.")
    }
}

struct ServerDetailView: View {
    @EnvironmentObject private var store: AppStore
    let server: ServerProfile
    @State private var showingEditor = false

    private var currentServer: ServerProfile {
        store.server(for: server.id) ?? server
    }

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Address", value: currentServer.host)
                LabeledContent("Port", value: "\(currentServer.port)")
                LabeledContent("User", value: currentServer.username)
                LabeledContent("Auth", value: authLabel(for: currentServer))
                if let fingerprint = currentServer.hostKeyFingerprint {
                    LabeledContent("Fingerprint", value: fingerprint)
                        .font(.caption)
                }
            }

            Section("Projects") {
                if currentServer.projects.isEmpty {
                    Text("No projects configured")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(currentServer.projects) { project in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.label).font(.headline)
                            Text(project.remotePath.isEmpty ? "(home)" : project.remotePath)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                NavigationLink("Session List") {
                    SessionListView(serverFilter: currentServer.id)
                }
            }
        }
        .navigationTitle(currentServer.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showingEditor = true }
            }
        }
        .sheet(isPresented: $showingEditor) {
            HostEditorView(server: currentServer) { saved in
                store.upsertServer(saved)
            }
        }
    }

    private func authLabel(for server: ServerProfile) -> String {
        switch server.authType {
        case .password:
            return String(localized: "Password")
        case .key:
            if let key = store.keyPair(for: server.keyPairId) {
                return String(localized: "Key") + " · \(key.label)"
            }
            return String(localized: "Key")
        }
    }
}
