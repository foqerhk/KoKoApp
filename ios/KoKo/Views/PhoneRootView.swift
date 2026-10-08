import SwiftUI

/// iPhone compact layout (TabView + stack navigation).
///
/// Terminal stays inside the tab’s `NavigationStack` so push/pop animates normally.
/// `TerminalScreenView` hides the tab bar and lifts for the keyboard.
struct PhoneRootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedTab = 0
    @State private var sessionPath = NavigationPath()
    @State private var keyboardVisible = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                // No onPickSession → NavigationLink(value:) push (animated) within this stack.
                HostListView()
                    .navigationDestination(for: UUID.self) { sessionId in
                        if let session = store.sessions.first(where: { $0.id == sessionId }) {
                            TerminalScreenView(session: session)
                        } else {
                            Text("Session missing")
                        }
                    }
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
        .modifier(PhoneTabBarStyle())
        .environment(\.kokoKeyboardVisible, keyboardVisible)
        .observeKeyboardVisibility($keyboardVisible)
        .sheet(item: $store.hostKeyPrompt) { prompt in
            HostKeyConfirmView(prompt: prompt)
        }
        .onChange(of: store.e2eOpenSessionId) { _, sessionId in
            guard let sessionId else { return }
            selectedTab = 1
            sessionPath.append(sessionId)
            store.e2eOpenSessionId = nil
        }
        .onAppear {
            if let sessionId = store.e2eOpenSessionId {
                selectedTab = 1
                sessionPath.append(sessionId)
                store.e2eOpenSessionId = nil
            }
        }
    }
}

/// Prefer a classic bottom tab bar over Duo’s sidebar list pill (iOS 18+).
private struct PhoneTabBarStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.tabViewStyle(.tabBarOnly)
        } else {
            content
        }
    }
}
