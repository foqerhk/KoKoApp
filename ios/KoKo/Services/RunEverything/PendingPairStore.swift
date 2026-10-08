import Foundation
import Combine

/// Holds a deep-link / QR payload until Desktops tab consumes it.
@MainActor
final class PendingPairStore: ObservableObject {
    static let shared = PendingPairStore()

    @Published var payload: RE2PairingPayload?

    func ingest(url: URL) {
        guard let parsed = try? RE2PairingPayload.parse(url.absoluteString) else { return }
        payload = parsed
    }

    func ingest(raw: String) {
        guard let parsed = try? RE2PairingPayload.parse(raw) else { return }
        payload = parsed
    }

    func take() -> RE2PairingPayload? {
        let p = payload
        payload = nil
        return p
    }
}
