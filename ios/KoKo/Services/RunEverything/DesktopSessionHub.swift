import Combine
import Foundation

/// Shared remote-desktop session so Hosts viewer and Sessions tab hit the same
/// live tunnel. A second WSS Noise from `RE2AgentChatClient` must not run while
/// this session is streaming — that was tearing down PreferDirect / freezing input.
@MainActor
final class DesktopSessionHub: ObservableObject {
    static let shared = DesktopSessionHub()

    let session = RE2DesktopSession()
    private var sessionObserve: AnyCancellable?
    private var phaseObserve: AnyCancellable?
    private weak var store: AppStore?

    private init() {
        // HostList / SessionList observe *this* hub. Without forwarding,
        // `session.statusText` / `phase` updates never redraw the Hosts overlay
        // — UI stuck on 「正在配对…」while REHP1/Noise already ran (agent logs).
        sessionObserve = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Persist the profile that actually reached the desktop. UI paths only saved it
    /// when `connect` returned cleanly, so a pairing that streamed after an internal
    /// retry kept the previous QR's token on disk and every later reconnect failed
    /// Noise msg3 until the user scanned again.
    func attach(store: AppStore) {
        self.store = store
        phaseObserve = session.$phase
            .removeDuplicates()
            .filter { $0 == .streaming }
            .sink { [weak self] _ in
                Task { @MainActor in self?.persistLiveProfile() }
            }
    }

    private func persistLiveProfile() {
        guard let store, let live = session.currentPaired, live.canReconnect else { return }
        let stored = store.upsertDesktop(live)
        session.adoptStoredIdentity(stored)
    }

    /// Prefer the live encrypted tunnel whenever this desktop session holds the
    /// Agent's Noise peer. The Agent ignores a parallel WSS Noise while UDP is live,
    /// and closing that refused socket makes the relay report peer_gone, which then
    /// tears down the desktop too.
    func listAgentChats(for desk: PairedDesktop) async throws -> [RemoteAgentConversation] {
        if try await sharedTunnel(for: desk) {
            return try await session.listAgentChats()
        }
        return try await RE2AgentChatClient.listChats(profile: desk)
    }

    /// `true` when data RPCs for `desk` must ride `session`; `false` when a separate
    /// WSS data channel is safe because no desktop session holds the Agent peer.
    func sharedTunnel(for desk: PairedDesktop) async throws -> Bool {
        guard session.currentPaired?.deviceID == desk.deviceID, session.holdsAgentPeer else { return false }
        let deadline = Date().addingTimeInterval(12)
        while !session.hasLiveTunnel, session.holdsAgentPeer, Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if session.hasLiveTunnel { return true }
        if session.holdsAgentPeer {
            throw RE2Error.signaling(String(localized: "Remote desktop is reconnecting — try again in a moment."))
        }
        return false
    }
}
