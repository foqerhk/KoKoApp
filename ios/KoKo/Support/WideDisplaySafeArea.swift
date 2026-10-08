import SwiftUI
import UIKit

/// Reads container safe-area insets for iPhone Duo / iPad inner displays (rounded corners + side status bar).
struct WideDisplaySafeAreaReader<Content: View>: View {
    @ViewBuilder var content: (EdgeInsets) -> Content

    var body: some View {
        GeometryReader { geo in
            content(geo.safeAreaInsets)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }
}

/// Safari-on-Duo inspired chrome metrics: same visual row height as the system floating status capsule.
enum DuoChromeMetrics {
    /// Top bar content height — matches Safari toolbar / Duo status capsule.
    static let barHeight: CGFloat = 52
    /// Circular control diameter (Safari back / tabs style).
    static let circleButton: CGFloat = 36
    static let symbolPointSize: CGFloat = 17
}

private struct KokoKeyboardVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the software keyboard is visible (used to mirror Safari: hide status + drop trailing clearance).
    var kokoKeyboardVisible: Bool {
        get { self[KokoKeyboardVisibleKey.self] }
        set { self[KokoKeyboardVisibleKey.self] = newValue }
    }
}

extension EdgeInsets {
    /// Side status / Dynamic Island cluster (unfolded Duo landscape), not top status (portrait).
    var hasSideStatusCluster: Bool {
        let side = max(leading, trailing)
        return side >= 20 && side >= top - 4
    }

    /// Leading inset for top chrome controls (background itself stays edge-to-edge).
    /// Extra floor clears Duo/iPhone continuous corner arcs (Safari leaves similar room).
    var chromeLeadingPadding: CGFloat {
        if hasSideStatusCluster {
            return max(leading + 28, 48)
        }
        return max(leading + 18, 28)
    }

    /// Trailing inset for top chrome — corner arcs only; system capsule is hidden and
    /// replaced by in-chrome `ChromeStatusCluster` after the More menu.
    var chromeTrailingPadding: CGFloat {
        if hasSideStatusCluster {
            return max(trailing + 28, 48)
        }
        return max(trailing + 18, 28)
    }

    /// Clearance for pane header buttons near continuous corner arcs.
    /// Always keep a floor: parent often ignores horizontal safe area so `trailing` reads as 0.
    var paneHeaderTrailingPadding: CGFloat {
        max(trailing + 14, 36)
    }

    func chromeTrailingPadding(keyboardVisible: Bool) -> CGFloat {
        // Status capsule may hide with keyboard, but device corner arcs remain.
        keyboardVisible ? max(trailing + 18, 28) : chromeTrailingPadding
    }

    func paneHeaderTrailingPadding(keyboardVisible: Bool) -> CGFloat {
        keyboardVisible ? 8 : paneHeaderTrailingPadding
    }
}

enum WideDisplayPaneInsets {
    /// True when a pane header sits under the system floating status cluster.
    static func needsHeaderTrailingInset(
        slotIndex: Int,
        slotCount: Int,
        isMaximized: Bool,
        portrait: Bool = false
    ) -> Bool {
        if isMaximized || slotCount <= 1 { return true }
        if portrait {
            return slotIndex == 0
        }
        switch slotCount {
        case 2, 3, 4:
            return slotIndex == 1
        default:
            return false
        }
    }
}

/// Observes keyboard show/hide and overlap height for Duo layout avoidance.
struct KeyboardVisibilityObserver: ViewModifier {
    @Binding var isVisible: Bool
    var overlapHeight: Binding<CGFloat>?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                isVisible = true
                overlapHeight?.wrappedValue = Self.overlap(from: note)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                let overlap = Self.overlap(from: note)
                if overlap > 1 {
                    isVisible = true
                    overlapHeight?.wrappedValue = overlap
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { note in
                let overlap = Self.overlap(from: note)
                if overlap > 1 {
                    isVisible = true
                    overlapHeight?.wrappedValue = overlap
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isVisible = false
                overlapHeight?.wrappedValue = 0
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                isVisible = false
                overlapHeight?.wrappedValue = 0
            }
    }

    /// Keyboard frame height intersecting the key window (includes inputAccessoryView when present).
    private static func overlap(from note: Notification) -> CGFloat {
        guard
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
            let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
        else { return 0 }
        let converted = window.convert(frame, from: nil)
        return max(0, window.bounds.maxY - converted.minY)
    }
}

extension View {
    func observeKeyboardVisibility(
        _ isVisible: Binding<Bool>,
        overlapHeight: Binding<CGFloat>? = nil
    ) -> some View {
        modifier(KeyboardVisibilityObserver(isVisible: isVisible, overlapHeight: overlapHeight))
    }
}

/// Circular toolbar control matching Safari's Duo top-bar buttons.
struct SafariChromeCircleButton<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: DuoChromeMetrics.symbolPointSize, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: DuoChromeMetrics.circleButton, height: DuoChromeMetrics.circleButton)
                .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
        }
        .buttonStyle(.plain)
    }
}
