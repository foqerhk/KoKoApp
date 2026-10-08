import SwiftUI
import UIKit

/// Layout bucket for the universal KoKo shell (compact phone / Duo / iPad).
enum DeviceLayoutKind: Equatable {
    /// Standard iPhone portrait / folded cover screen.
    case phoneCompact
    /// Unfolded foldable iPhone (`horizontalSizeClass == .regular` on phone idiom).
    case phoneDuo
    /// iPad and iPadOS windowing.
    case tablet
}

enum DeviceLayout {
    /// Inner Duo width is ~600pt+; outer cover is phone-sized (~390). Used when size class lies.
    private static let duoInnerMinWidth: CGFloat = 560

    static func current(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        containerWidth: CGFloat? = nil
    ) -> DeviceLayoutKind {
        let idiom = UIDevice.current.userInterfaceIdiom
        if idiom == .pad {
            return .tablet
        }
        if idiom == .phone, horizontalSizeClass == .regular {
            // Folded cover must stay compact/phone even if traits flicker to `.regular`.
            if let containerWidth, containerWidth < duoInnerMinWidth {
                return .phoneCompact
            }
            return .phoneDuo
        }
        _ = verticalSizeClass
        return .phoneCompact
    }
}

/// Empty / loading status for Hosts · Sessions · Keys (not list rows).
struct EmptyListStatusView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var title: LocalizedStringKey? = nil
    var systemImage: String? = nil
    var showProgress: Bool = false
    var description: LocalizedStringKey

    private var foldedPhone: Bool {
        DeviceLayout.current(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        ) == .phoneCompact
    }

    var body: some View {
        ContentUnavailableView {
            if showProgress {
                ProgressView()
            } else if let title, let systemImage {
                Label(title, systemImage: systemImage)
            } else if let title {
                Text(title)
            }
        } description: {
            Text(description)
                .font(foldedPhone ? .system(size: 12, weight: .regular) : .subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, foldedPhone ? 12 : 0)
        }
    }
}
