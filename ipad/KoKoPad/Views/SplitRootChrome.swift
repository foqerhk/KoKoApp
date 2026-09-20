import SwiftUI

/// Shared sheets and deep-link handling for split layouts (tablet / duo).
struct SplitRootChrome<Content: View>: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selectedSection: SidebarSection?
    @Binding var selectedSessionId: UUID?

    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .sheet(item: $store.hostKeyPrompt) { prompt in
                HostKeyConfirmView(prompt: prompt)
            }
            .onChange(of: store.e2eOpenSessionId) { _, sessionId in
                guard let sessionId else { return }
                selectedSection = .sessions
                selectedSessionId = sessionId
            }
    }
}
