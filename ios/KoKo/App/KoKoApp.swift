import SwiftUI
import UIKit

@main
struct KoKoApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var languageStore = AppLanguageStore.shared
    @StateObject private var appearanceStore = AppAppearanceStore.shared
    @StateObject private var pendingPair = PendingPairStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(languageStore)
                .environmentObject(appearanceStore)
                .environmentObject(pendingPair)
                .environment(\.locale, languageStore.resolvedLocale)
                .preferredColorScheme(appearanceStore.appearance.preferredColorScheme)
                // Only remount on language change (locale). Appearance must NOT be in `.id`
                // or Settings → theme would rebuild the tree and re-open demo sessions.
                .id(languageStore.language.rawValue)
                .trackDuoHinge()
                .overlay {
                    FloatingAccessoryWindowOverlay()
                }
                .onAppear {
                    DesktopSessionHub.shared.attach(store: store)
                    // Production default: HW decode first. Drop persisted soft-only smoke flag
                    // unless this launch explicitly requests `-RE2SoftDecode`.
                    if !ProcessInfo.processInfo.arguments.contains("-RE2SoftDecode"),
                       ProcessInfo.processInfo.environment["KOKO_RE2_SOFT_DECODE"] != "1" {
                        H264Decoder.clearForceSoftwareDefault()
                    }
                    E2EAutoConnect.runIfRequested(store: store)
                    RE2E2EAutoConnect.runIfRequested(store: store)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // Device relaunch via devicectl sometimes skips a cold onAppear.
                    RE2E2EAutoConnect.runIfRequested(store: store)
                }
                .task {
                    RE2E2EAutoConnect.writeBootProbe()
                    RE2E2EAutoConnect.runIfRequested(store: store)
                }
                .onOpenURL { url in
                    pendingPair.ingest(url: url)
                }
        }

        // iPad / Stage Manager (and Duo inner display when the system allows).
        // Compact PhoneRootView never calls openWindow; DuoRootView keeps supportsExtraWindows=false.
        WindowGroup(id: SessionWindowScene.session, for: UUID.self) { $sessionId in
            if let sessionId {
                SessionWindowRoot(sessionId: sessionId)
                    .environmentObject(store)
                    .environmentObject(languageStore)
                    .environmentObject(appearanceStore)
                    .preferredColorScheme(appearanceStore.appearance.preferredColorScheme)
            } else {
                ContentUnavailableView("No Session", systemImage: "terminal")
            }
        }
        .defaultSize(width: 960, height: 720)
    }
}
