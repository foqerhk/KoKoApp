import SwiftUI

/// Foldable / wide iPhone layout: compact sidebar with section switcher + terminal detail.
struct DuoRootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedSection: SidebarSection = .sessions
    @State private var selectedServerId: UUID?
    @State private var selectedSessionId: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        SplitRootChrome(
            selectedSection: Binding(
                get: { selectedSection },
                set: { if let value = $0 { selectedSection = value } }
            ),
            selectedSessionId: $selectedSessionId
        ) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                VStack(spacing: 0) {
                    Picker("Section", selection: $selectedSection) {
                        ForEach(SidebarSection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    duoListColumn
                }
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
            } detail: {
                duoDetailColumn
            }
        }
        .onChange(of: selectedSection) { _, newSection in
            if newSection != .hosts { selectedServerId = nil }
            if newSection != .sessions { selectedSessionId = nil }
        }
    }

    @ViewBuilder
    private var duoListColumn: some View {
        switch selectedSection {
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
    private var duoDetailColumn: some View {
        switch selectedSection {
        case .hosts:
            if let selectedServerId, let server = store.server(for: selectedServerId) {
                ServerDetailView(server: server)
            } else {
                duoPlaceholder(
                    title: "Select a Host",
                    systemImage: "server.rack",
                    description: "Unfolded view: host details appear here."
                )
            }
        case .sessions:
            if let selectedSessionId, let session = store.sessions.first(where: { $0.id == selectedSessionId }) {
                TerminalScreenView(session: session)
            } else {
                duoPlaceholder(
                    title: "Select a Session",
                    systemImage: "terminal",
                    description: "Unfolded view: terminal uses the wide pane."
                )
            }
        case .keys:
            duoPlaceholder(
                title: "SSH Keys",
                systemImage: "key",
                description: "Manage keys in the left pane while unfolded."
            )
        case .settings:
            duoPlaceholder(
                title: "Settings",
                systemImage: "gearshape",
                description: "Adjust language in the left pane while unfolded."
            )
        }
    }

    private func duoPlaceholder(title: LocalizedStringKey, systemImage: String, description: LocalizedStringKey) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
    }
}
