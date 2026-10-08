import SwiftUI

/// Picks phone compact (ios TabView), foldable duo split, or iPad three-column split.
struct AdaptiveRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { geo in
            let kind = DeviceLayout.current(
                horizontalSizeClass: horizontalSizeClass,
                verticalSizeClass: verticalSizeClass,
                containerWidth: geo.size.width
            )
            Group {
                switch kind {
                case .phoneCompact:
                    // Folded Duo outer display + normal iPhone — push navigation.
                    PhoneRootView()
                case .phoneDuo:
                    DuoRootView()
                case .tablet:
                    TabletRootView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
