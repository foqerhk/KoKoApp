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
    private struct WeakWorkspace { weak var value: TerminalWorkspace? }
    /// The one AI session per Agent this phone keeps attached.
    private var activeChatSessions: [String: WeakWorkspace] = [:]

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

    /// AI sessions are deliberately data-channel only. Falling back to the desktop
    /// controller slot couples chat availability to ScreenCaptureKit and makes a
    /// sleeping/closed display tear down otherwise healthy terminal sessions.
    /// `force` takes over only the Agent's data slot, never its desktop slot.
    func listAgentChats(for desk: PairedDesktop, force: Bool = false) async throws -> [RemoteAgentConversation] {
        do {
            let tunnel = try await dataTunnel(for: desk, force: force)
            do {
                return try await tunnel.listChats()
            } catch where !tunnel.isOpen && !force {
                // The shared link died under us (relay restart, network); one fresh try.
                return try await dataTunnel(for: desk).listChats()
            }
        } catch RE2Error.channelUnsupported {
            throw RE2Error.signaling(String(localized: "This Relay or Agent does not support screen-independent sessions. Update it, then try again."))
        }
    }

    @discardableResult
    func fetchHostHealth(for desk: PairedDesktop, force: Bool = false) async throws -> HostHealthSnapshot {
        do {
            let tunnel = try await dataTunnel(for: desk, force: force)
            let snapshot = try await tunnel.fetchHostHealth()
            store?.updateDesktopName(desktopId: desk.id, computerName: snapshot.computerName)
            store?.updateHostHealth(desktopId: desk.id, snapshot: snapshot, reachability: .online)
            return snapshot
        } catch let error as RE2Error {
            if case .agentOffline = error,
               let lifecycle = try? await RE2AgentChatClient.lifecycleStatus(profile: desk) {
                let snapshot = lifecycle.healthSnapshot
                store?.updateHostHealth(
                    desktopId: desk.id, snapshot: snapshot, reachability: .online,
                    reason: lifecycle.phase
                )
                return snapshot
            }
            let reason: String
            let reachability: HostHealthReachability
            switch error {
            case .agentOffline:
                reason = "relay_offline"
                reachability = .offline
            case .channelUnsupported:
                reason = "health_unsupported"
                reachability = .unsupported
            default:
                reason = error.localizedDescription
                reachability = .stale
            }
            store?.updateHostHealth(
                desktopId: desk.id,
                snapshot: store?.hostHealth(for: desk.id)?.snapshot,
                reachability: reachability,
                reason: reason
            )
            throw error
        } catch {
            store?.updateHostHealth(
                desktopId: desk.id,
                snapshot: store?.hostHealth(for: desk.id)?.snapshot,
                reachability: .stale,
                reason: error.localizedDescription
            )
            throw error
        }
    }

    /// The shared data-channel link to `desk`, opened on demand. `force` takes over
    /// from another phone. Throws `channelUnsupported` for relays / Agents without
    /// separate channels.
    func dataTunnel(for desk: PairedDesktop, force: Bool = false) async throws -> RE2DataTunnel {
        let id = desk.deviceID
        if legacyDataChannel.contains(id) {
            throw RE2Error.channelUnsupported
        }
        if !force, let t = dataTunnels[id], t.sessionTicket == desk.sessionTicket {
            if t.isOpen { return t }
            // Stale cache after half-open death — drop before opening a fresh BIND.
            dataTunnels[id] = nil
            t.teardown(reason: String(localized: "Data channel reconnected"))
        }
        if !force, let pending = dataTunnelOpening[id] {
            return try await pending.value
        }
        let opening = Task { @MainActor () throws -> RE2DataTunnel in
            let t = RE2DataTunnel(profile: desk)
            try await t.connect(force: force)
            t.onPowerEvent = { [weak self] data in
                guard let self,
                      let event = try? HostPowerEvent.decode(data, desktopId: desk.id) else { return }
                self.store?.recordPowerEvent(event, hostName: desk.name)
                Task { try? await self.fetchHostHealth(for: desk) }
            }
            t.onDead = { [weak self] in
                Task { @MainActor in
                    guard let self, self.dataTunnels[id] === t else { return }
                    self.dataTunnels[id] = nil
                }
            }
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

    /// Drop the shared data link to `deviceID` once no AI terminal is attached to it;
    /// the session list reopens it on demand.
    func releaseDataTunnelIfIdle(deviceID: String) {
        guard let t = dataTunnels[deviceID], !t.hasSessions else { return }
        dataTunnels[deviceID] = nil
        t.teardown()
    }

    /// Makes `workspace` the only live AI session for `deviceID` on this phone; the
    /// previous holder is detached.
    func claimChatSession(deviceID: String, by workspace: TerminalWorkspace, exclusive: Bool = true) {
        guard exclusive else { return }
        let previous = activeChatSessions[deviceID]?.value
        activeChatSessions[deviceID] = WeakWorkspace(value: workspace)
        if let previous, previous !== workspace {
            previous.yieldToOtherSession()
        }
    }

    func releaseChatSession(deviceID: String, by workspace: TerminalWorkspace) {
        if activeChatSessions[deviceID]?.value === workspace {
            activeChatSessions[deviceID] = nil
        }
    }

    private func markLegacyDataChannel(_ desk: PairedDesktop) {
        legacyDataChannel.insert(desk.deviceID)
    }
}
