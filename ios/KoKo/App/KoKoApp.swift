import SwiftUI

@main
struct KoKoApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var languageStore = AppLanguageStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(languageStore)
                .environment(\.locale, languageStore.resolvedLocale)
                .id(languageStore.language.rawValue)
                .onAppear {
                    E2EAutoConnect.runIfRequested(store: store)
                }
        }
    }
}
