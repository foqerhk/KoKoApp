import SwiftUI

/// Standalone terminal window (iPad multi-window / Stage Manager).
struct SessionWindowRoot: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var languageStore: AppLanguageStore
    let sessionId: UUID

    var body: some View {
        Group {
            if let session = store.sessions.first(where: { $0.id == sessionId }) {
                TerminalScreenView(session: session, compactChrome: false)
            } else {
                ContentUnavailableView(
                    "Session Unavailable",
                    systemImage: "terminal",
                    description: Text("This conversation was removed from the device.")
                )
            }
        }
        .environment(\.locale, languageStore.resolvedLocale)
    }
}
