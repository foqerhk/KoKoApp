import SwiftUI

/// iPad three-column layout: sidebar section → list/content → detail/terminal.
struct TabletRootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedSection: SidebarSection? = .sessions
    @State private var selectedServerId: UUID?
    @State private var selectedSessionId: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        SplitRootChrome(
            selectedSection: $selectedSection,
            selectedSessionId: $selectedSessionId
        ) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                List(SidebarSection.allCases, selection: $selectedSection) { section in
                    Label(section.title, systemImage: section.icon)
                }
                .navigationTitle("KoKo")
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            } content: {
                NavigationStack {
                    contentColumn
                }
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 480)
            } detail: {
                detailColumn
                    .navigationSplitViewColumnWidth(min: 420, ideal: 560)
            }
        }
        .onChange(of: selectedSection) { _, newSection in
            if newSection != .hosts { selectedServerId = nil }
            if newSection != .sessions { selectedSessionId = nil }
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch selectedSection ?? .sessions {
        case .hosts:
            HostListView(selectedServerId: $selectedServerId)
        case .sessions:
            SessionListView(selectedSessionId: $selectedSessionId)
        case .keys:
            KeyListView()
        case .settings:
            SettingsView()
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch selectedSection ?? .sessions {
        case .hosts:
            if let selectedServerId, let server = store.server(for: selectedServerId) {
                ServerDetailView(server: server)
            } else {
                splitPlaceholder(
                    title: "Select a Host",
                    systemImage: "server.rack",
                    description: "Choose a host to view connection details and projects."
                )
            }
        case .sessions:
            if let selectedSessionId, let session = store.sessions.first(where: { $0.id == selectedSessionId }) {
                TerminalScreenView(session: session)
            } else {
                splitPlaceholder(
                    title: "Select a Session",
                    systemImage: "terminal",
                    description: "Pick a conversation to open the SSH terminal."
                )
            }
        case .keys:
            splitPlaceholder(
                title: "SSH Keys",
                systemImage: "key",
                description: "Generate and manage keys in the middle column. Copy or install from the list."
            )
        case .settings:
            splitPlaceholder(
                title: "Settings",
                systemImage: "gearshape",
                description: "Language and version info are in the middle column."
            )
        }
    }

    private func splitPlaceholder(title: LocalizedStringKey, systemImage: String, description: LocalizedStringKey) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
    }
}
