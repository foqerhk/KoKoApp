import Darwin
import SwiftUI
import UIKit

/// Hardware marketing model for controller identity (kick / takeover copy).
/// `UIDevice.current.name` is often just "iPhone", so peers cannot tell devices apart.
enum DeviceMarketingName {
    static var machineIdentifier: String {
        var sys = utsname()
        uname(&sys)
        var machine = sys.machine
        return withUnsafeBytes(of: &machine) { raw in
            raw.withMemoryRebound(to: CChar.self) { ptr in
                String(cString: ptr.baseAddress!)
            }
        }
    }

    /// e.g. "iPhone 14 Pro Max", "iPhone Air". Unknown ids fall back to the raw machine string.
    static var marketingModel: String {
        let id = machineIdentifier
        return map[id] ?? id
    }

    /// BIND `client_name` base (time stamped separately): model, plus custom name when set.
    static var controllerLabel: String {
        let model = marketingModel
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic: Set<String> = [
            "", "iPhone", "iPad", "iPod", "iPod touch", UIDevice.current.model,
        ]
        if generic.contains(name) { return model }
        if name.caseInsensitiveCompare(model) == .orderedSame { return model }
        if name.localizedCaseInsensitiveContains(model) { return name }
        if model.localizedCaseInsensitiveContains(name) { return model }
        return "\(model) · \(name)"
    }

    // Identifiers from Apple / AppleDB; keep recent phones the lab uses.
    private static let map: [String: String] = [
        // iPhone 14
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        // iPhone 15
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        // iPhone 16
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        // iPhone 17 / Air
        "iPhone18,3": "iPhone 17",
        "iPhone18,1": "iPhone 17 Pro",
        "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,4": "iPhone Air",
        // Simulator
        "i386": "Simulator",
        "x86_64": "Simulator",
        "arm64": "Simulator",
    ]
}

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
