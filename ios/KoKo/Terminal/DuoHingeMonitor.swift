import Combine
import SwiftUI
import UIKit

/// Observes iPhone Duo hinge posture via `UIHingeInteraction` (iOS 27.1+),
/// with keyboard / division fallbacks for half-fold accessory mode.
@MainActor
final class DuoHingeMonitor: ObservableObject {
    static let shared = DuoHingeMonitor()

    /// `true` when the hinge reports `.partiallyOpen` (flex / laptop half-fold).
    @Published private(set) var isPartiallyOpen = false

    /// Use the window-level floating accessory — only in real Duo half-fold / flex
    /// (`partiallyOpen` or an active division). Do **not** infer this from a tall
    /// CJK keyboard on a single screen (that falsely clipped the app to half height
    /// and left content under the keyboard).
    @Published private(set) var prefersFloatingAccessory = false

    /// True when the hinge / division says we are in up-down or left-right flex.
    var isHalfFoldLayout: Bool { isPartiallyOpen || hasActiveDivision }

    /// Bottom Y of the upper content pane (top of hinge / division). 0 = unknown.
    @Published private(set) var upperContentMaxY: CGFloat = 0

    /// Top Y of the lower content pane (bottom of hinge / division). 0 = unknown.
    @Published private(set) var lowerContentMinY: CGFloat = 0

    private var hasActiveDivision = false

    @available(iOS 27.1, *)
    fileprivate func apply(status: UIHinge.Status?) {
        let partial = (status == .partiallyOpen)
        if isPartiallyOpen != partial {
            isPartiallyOpen = partial
        }
        recompute()
    }

    /// Kept for keyboard-avoidance callers; no longer drives floating / flex mode.
    func applyKeyboardOverlap(_ overlap: CGFloat, screenHeight: CGFloat) {
        _ = overlap
        _ = screenHeight
    }

    func applyDivision(active: Bool, upperMaxY: CGFloat, lowerMinY: CGFloat) {
        var changed = false
        if hasActiveDivision != active {
            hasActiveDivision = active
            changed = true
        }
        if abs(upperContentMaxY - upperMaxY) > 0.5 {
            upperContentMaxY = upperMaxY
            changed = true
        }
        if abs(lowerContentMinY - lowerMinY) > 0.5 {
            lowerContentMinY = lowerMinY
            changed = true
        }
        if changed { recompute() }
    }

    private func recompute() {
        let next = isPartiallyOpen || hasActiveDivision
        if prefersFloatingAccessory != next {
            prefersFloatingAccessory = next
        }
        // Midline fallback when hinge is partial but division rect hasn't arrived yet.
        if next, upperContentMaxY < 1 || lowerContentMinY < 1 {
            let mid = (UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?
                .bounds.height ?? UIScreen.main.bounds.height) * 0.5
            if upperContentMaxY < 1 { upperContentMaxY = mid - 6 }
            if lowerContentMinY < 1 { lowerContentMinY = mid + 6 }
        }
        if !next {
            upperContentMaxY = 0
            lowerContentMinY = 0
        }
    }
}

/// Invisible probe that attaches `UIHingeInteraction` to the window and watches division regions.
struct DuoHingeProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> HingeProbeUIView {
        HingeProbeUIView()
    }

    func updateUIView(_ uiView: HingeProbeUIView, context: Context) {}
}

final class HingeProbeUIView: UIView {
    private var hingeInteraction: UIInteraction?
    private static var didInstallOnRoot = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        installHingeInteractionIfNeeded()
        refreshDivision()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Division queries during every layout + SwiftUI republish caused fold/rotate flash loops.
        // Probe on a short debounce instead.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(debouncedRefreshDivision), object: nil)
        perform(#selector(debouncedRefreshDivision), with: nil, afterDelay: 0.08)
    }

    @objc private func debouncedRefreshDivision() {
        refreshDivision()
    }

    private func installHingeInteractionIfNeeded() {
        guard hingeInteraction == nil else { return }
        let target = window?.rootViewController?.view ?? self
        if #available(iOS 27.1, *) {
            // Avoid stacking duplicate interactions when SwiftUI recreates the probe.
            if !Self.didInstallOnRoot || target === self {
                let interaction = UIHingeInteraction { _, update in
                    Task { @MainActor in
                        DuoHingeMonitor.shared.apply(status: update.hinge?.status)
                    }
                }
                target.addInteraction(interaction)
                hingeInteraction = interaction
                if target !== self { Self.didInstallOnRoot = true }
            }
        }
    }

    private func refreshDivision() {
        guard #available(iOS 27.1, *) else {
            DuoHingeMonitor.shared.applyDivision(active: false, upperMaxY: 0, lowerMinY: 0)
            return
        }
        let host = window?.rootViewController?.view ?? self
        let divisions = host.reservedRegions(kind: .division).filter {
            $0.isActive && $0.frame.height > 0.5
        }
        if let region = divisions.max(by: { $0.frame.height < $1.frame.height }) {
            let frame = host.convert(region.frame, to: nil)
            // Convert to key-window coordinates for layout consumers.
            let window = self.window
            let local = window.map { $0.convert(frame, from: nil) } ?? frame
            DuoHingeMonitor.shared.applyDivision(
                active: true,
                upperMaxY: local.minY,
                lowerMinY: local.maxY
            )
        } else {
            DuoHingeMonitor.shared.applyDivision(active: false, upperMaxY: 0, lowerMinY: 0)
        }
    }
}

extension View {
    /// Installs a zero-size hinge probe so Duo half-fold state is tracked app-wide.
    func trackDuoHinge() -> some View {
        background {
            DuoHingeProbe()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
