import SwiftUI

/// Picks phone compact (ios TabView), foldable duo split, or iPad three-column split.
struct AdaptiveRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        switch DeviceLayout.current(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        ) {
        case .phoneCompact:
            PhoneRootView()
        case .phoneDuo:
            DuoRootView()
        case .tablet:
            TabletRootView()
        }
    }
}
