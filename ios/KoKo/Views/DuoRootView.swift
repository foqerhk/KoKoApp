import SwiftUI

/// Foldable / wide iPhone: defaults to dual terminals; up to four slots when inner display is wide enough.
struct DuoRootView: View {
    var body: some View {
        LargeScreenShellView(maxSlots: 4, defaultSlotCount: 2, supportsExtraWindows: false, edgeToEdge: true)
    }
}
