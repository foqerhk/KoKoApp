import SwiftUI

/// iPad: fullscreen terminal grid with up to four concurrent sessions.
struct TabletRootView: View {
    var body: some View {
        LargeScreenShellView(maxSlots: 4, defaultSlotCount: 1, supportsExtraWindows: false, edgeToEdge: true)
    }
}
