import Combine
import CoreTelephony
import Network
import SwiftUI

/// Live clock + link kind for Duo topChrome (replaces the hidden system status capsule).
@MainActor
final class ChromeLinkStatusModel: ObservableObject {
    enum Kind: Equatable {
        case offline
        case wifi
        case cellular(String) // "5G" / "4G" / "LTE" / "3G" / "蜂窝"
    }

    @Published private(set) var now: Date = .now
    @Published private(set) var kind: Kind = .offline
    /// 0…3 approximate bars from path quality (iOS does not expose RSSI to apps).
    @Published private(set) var bars: Int = 0

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.foqerhk.koko.link-status")
    private var ticker: AnyCancellable?
    private let telephony = CTTelephonyNetworkInfo()

    func start() {
        guard ticker == nil else { return }
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                self?.now = date
            }

        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.apply(path: path)
            }
        }
        pathMonitor.start(queue: queue)
        monitor = pathMonitor
        apply(path: pathMonitor.currentPath)
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        monitor?.cancel()
        monitor = nil
    }

    private func apply(path: NWPath) {
        guard path.status == .satisfied else {
            kind = .offline
            bars = 0
            return
        }

        // Soft quality from path flags — not true radio RSSI (unavailable publicly).
        if path.isConstrained {
            bars = 1
        } else if path.isExpensive {
            bars = 2
        } else {
            bars = 3
        }

        if path.usesInterfaceType(.wifi) {
            kind = .wifi
        } else if path.usesInterfaceType(.cellular) {
            kind = .cellular(Self.cellularLabel(telephony))
        } else if path.usesInterfaceType(.wiredEthernet) {
            kind = .wifi
            bars = 3
        } else {
            kind = .cellular(Self.cellularLabel(telephony))
        }
    }

    private static func cellularLabel(_ info: CTTelephonyNetworkInfo) -> String {
        let techs: [String]
        if let map = info.serviceCurrentRadioAccessTechnology {
            techs = Array(map.values)
        } else {
            techs = []
        }
        for tech in techs {
            switch tech {
            case CTRadioAccessTechnologyNR, CTRadioAccessTechnologyNRNSA:
                return "5G"
            case CTRadioAccessTechnologyLTE:
                return "4G"
            case CTRadioAccessTechnologyWCDMA,
                 CTRadioAccessTechnologyHSDPA,
                 CTRadioAccessTechnologyHSUPA,
                 CTRadioAccessTechnologyeHRPD:
                return "3G"
            case CTRadioAccessTechnologyEdge,
                 CTRadioAccessTechnologyGPRS,
                 CTRadioAccessTechnologyCDMA1x:
                return "2G"
            default:
                continue
            }
        }
        return String(localized: "Cellular")
    }
}

/// Compact time + link cluster for the trailing edge of Duo topChrome.
struct ChromeStatusCluster: View {
    @StateObject private var model = ChromeLinkStatusModel()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 0) {
            Text(Self.timeFormatter.string(from: model.now))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .padding(.trailing, 8)

            Capsule()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1, height: 13)

            linkLabel
                .padding(.leading, 8)
        }
        .padding(.horizontal, 11)
        .frame(height: DuoChromeMetrics.circleButton)
        .background {
            Capsule(style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var linkLabel: some View {
        HStack(spacing: 4) {
            switch model.kind {
            case .offline:
                Image(systemName: "wifi.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .imageScale(.small)
                Text(String(localized: "Offline"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            case .wifi:
                Image(systemName: "wifi")
                    .font(.system(size: 12, weight: .semibold))
                    .imageScale(.small)
                SignalBars(level: model.bars)
            case .cellular(let name):
                Text(name)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(-0.3)
                SignalBars(level: model.bars)
            }
        }
        .foregroundStyle(.primary)
        .fixedSize()
    }

    private var accessibilityText: String {
        let time = Self.timeFormatter.string(from: model.now)
        switch model.kind {
        case .offline:
            return "\(time), \(String(localized: "Offline"))"
        case .wifi:
            return String(format: String(localized: "%@, Wi‑Fi, %lld bars"), time, Int64(model.bars))
        case .cellular(let name):
            return String(format: String(localized: "%@, %@, %lld bars"), time, name, Int64(model.bars))
        }
    }
}

/// Three-bar strength meter (path-quality proxy; iOS hides real RSSI from apps).
private struct SignalBars: View {
    var level: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.75, style: .continuous)
                    .fill(index < max(level, 0) ? Color.primary : Color.primary.opacity(0.2))
                    .frame(width: 2.5, height: 4 + CGFloat(index) * 3.5)
            }
        }
        .frame(height: 11, alignment: .bottom)
        .padding(.bottom, 0.5)
        .accessibilityHidden(true)
    }
}
