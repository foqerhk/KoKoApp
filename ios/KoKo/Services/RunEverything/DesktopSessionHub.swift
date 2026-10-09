import Combine
import Foundation

/// Shared remote-desktop session so Hosts viewer and Sessions tab hit the same
/// live tunnel. Data RPCs use the relay's separate data channel; only relays or
/// Agents without it fall back to riding this session.
@MainActor
final class DesktopSessionHub: ObservableObject {
    static let shared = DesktopSessionHub()

    let session = RE2DesktopSession()
    private var sessionObserve: AnyCancellable?
    private var phaseObserve: AnyCancellable?
    private weak var store: AppStore?
    /// Agents (device ids) reached through a relay or Agent without a data channel.
    private var legacyDataChannel: Set<String> = []
    /// One data-channel link per Agent, shared by the session list and every AI
    /// terminal: the relay holds a single data slot per phone, so a second link
    /// from this phone would replace the first.
    private var dataTunnels: [String: RE2DataTunnel] = [:]
    private var dataTunnelOpening: [String: Task<RE2DataTunnel, Error>] = [:]

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

    /// Data channel first. Without one, prefer the live desktop tunnel whenever this
    /// session holds the Agent's Noise peer: an old Agent ignores a parallel WSS Noise
    /// while UDP is live, and an old relay lets that socket replace the desktop's.
    /// `force` takes over from another phone.
    func listAgentChats(for desk: PairedDesktop, force: Bool = false) async throws -> [RemoteAgentConversation] {
        if usesDataChannel(desk) {
            do {
                let tunnel = try await dataTunnel(for: desk, force: force)
                do {
                    return try await tunnel.listChats()
                } catch where !tunnel.isOpen && !force {
                    // The shared link died under us (relay restart, network); one fresh try.
                    return try await dataTunnel(for: desk).listChats()
                }
            } catch RE2Error.channelUnsupported {
            }
        }
        if try await sharedTunnel(for: desk) {
            return try await session.listAgentChats()
        }
        return try await RE2AgentChatClient.listChats(profile: desk, force: force, channel: false)
    }

    /// The shared data-channel link to `desk`, opened on demand. `force` takes over
    /// from another phone. Throws `channelUnsupported` for relays / Agents without
    /// separate channels.
    func dataTunnel(for desk: PairedDesktop, force: Bool = false) async throws -> RE2DataTunnel {
        let id = desk.deviceID
        if !force, let t = dataTunnels[id], t.isOpen, t.sessionTicket == desk.sessionTicket {
            return t
        }
        if !force, let pending = dataTunnelOpening[id] {
            return try await pending.value
        }
        let opening = Task { @MainActor () throws -> RE2DataTunnel in
            let t = RE2DataTunnel(profile: desk)
            try await t.connect(force: force)
            return t
        }
        dataTunnelOpening[id] = opening
        defer { if dataTunnelOpening[id] == opening { dataTunnelOpening[id] = nil } }
        let tunnel: RE2DataTunnel
        do {
            tunnel = try await opening.value
        } catch RE2Error.channelUnsupported {
            markLegacyDataChannel(desk)
            throw RE2Error.channelUnsupported
        }
        guard tunnel.isSeparateChannel else {
            // An old relay bound it in the desktop slot; it would fight the desktop.
            tunnel.teardown()
            markLegacyDataChannel(desk)
            throw RE2Error.channelUnsupported
        }
        tunnel.isShared = true
        if let old = dataTunnels[id], old !== tunnel {
            old.teardown(reason: String(localized: "Data channel reconnected"))
        }
        dataTunnels[id] = tunnel
        return tunnel
    }

    func usesDataChannel(_ desk: PairedDesktop) -> Bool {
        !legacyDataChannel.contains(desk.deviceID)
    }

    func markLegacyDataChannel(_ desk: PairedDesktop) {
        legacyDataChannel.insert(desk.deviceID)
    }

    /// `true` when data RPCs for `desk` must ride `session`: no data channel, and the
    /// desktop session holds the Agent peer.
    func sharedTunnel(for desk: PairedDesktop) async throws -> Bool {
        guard !usesDataChannel(desk),
              session.currentPaired?.deviceID == desk.deviceID, session.holdsAgentPeer else { return false }
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
