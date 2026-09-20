import SwiftUI

/// iPhone compact layout (TabView + stack navigation).
struct PhoneRootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedTab = 0
    @State private var sessionPath = NavigationPath()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HostListView()
            }
            .tabItem {
                Label("Hosts", systemImage: "server.rack")
            }
            .tag(0)

            NavigationStack(path: $sessionPath) {
                SessionListView()
                    .navigationDestination(for: UUID.self) { sessionId in
                        if let session = store.sessions.first(where: { $0.id == sessionId }) {
                            TerminalScreenView(session: session)
                        } else {
                            Text("Session missing")
                        }
                    }
            }
            .tabItem {
                Label("Sessions", systemImage: "terminal")
            }
            .tag(1)

            NavigationStack {
                KeyListView()
            }
            .tabItem {
                Label("Keys", systemImage: "key")
            }
            .tag(2)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(3)
        }
        .sheet(item: $store.hostKeyPrompt) { prompt in
            HostKeyConfirmView(prompt: prompt)
        }
        .onChange(of: store.e2eOpenSessionId) { _, sessionId in
            guard let sessionId else { return }
            selectedTab = 1
            sessionPath = NavigationPath()
            sessionPath.append(sessionId)
        }
    }
}
