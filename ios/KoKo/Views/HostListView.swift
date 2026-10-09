import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var pendingPair: PendingPairStore
    var selectedServerId: Binding<UUID?>? = nil
    /// When set (Duo / large-screen shell), picking a session dismisses management and opens it in a slot.
    var onPickSession: ((TerminalSession) -> Void)? = nil

    @ObservedObject private var desktopHub = DesktopSessionHub.shared
    /// Observe the session directly (hub also forwards) so statusText/phase refresh.
    @ObservedObject private var desktopSession = DesktopSessionHub.shared.session
    @State private var showingEditor = false
    @State private var editingServer: ServerProfile?
    @State private var hostsPendingDelete: [ServerProfile] = []
    @State private var showDeleteConfirm = false
    @State private var showScanner = false
    @State private var showPaste = false
    @State private var activeDesktop: PairedDesktop?
    @State private var connecting = false
    @State private var connectError: String?
    @State private var password = ""
    @State private var askPassword = false
    @State private var pendingPayload: RE2PairingPayload?
    @State private var pendingReconnect: PairedDesktop?
    @State private var takeoverDesk: PairedDesktop?
    @State private var takeoverPeer = ""
    @State private var takeoverPassword: String?
    /// Ignores brief `activeDesktop == nil` flashes when Hashable item fields change mid-connect.
    @State private var leaveDesktopEpoch = 0

    private var isEmpty: Bool {
        store.servers.isEmpty && store.desktops.isEmpty
    }

    var body: some View {
        List {
            if isEmpty {
                EmptyListStatusView(
                    title: "No Hosts",
                    systemImage: "server.rack",
                    description: "Add an SSH server, or scan an Agent QR to pair a remote desktop."
                )
            } else {
                if !store.servers.isEmpty {
                    Section {
                        ForEach(store.servers) { server in
                            hostRow(for: server)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        hostsPendingDelete = [server]
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("Delete Host", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                        }
                    } header: {
                        Text(String(localized: "SSH"))
                    }
                }

                if !store.desktops.isEmpty {
                    Section {
                        ForEach(store.desktops) { desk in
                            Button {
                                // Reattach to the session kept alive after Back; a second
                                // connect would race the Agent's still-live UDP stream.
                                if desktopSession.currentPaired?.deviceID == desk.deviceID,
                                   desktopSession.holdsAgentPeer {
                                    activeDesktop = desk
                                    return
                                }
                                pendingReconnect = desk
                                let saved = RE2DesktopSecrets.loadPassword(desktopID: desk.id)
                                Task { await reconnectDesktop(desk, password: saved) }
                            } label: {
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(desk.name)
                                        Text(desk.deviceID)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        if let lan = Self.lanSubtitle(
                                            desk: desk,
                                            live: desktopSession.currentPaired?.deviceID == desk.deviceID
                                                ? desktopSession.lanEndpointsDisplay
                                                : nil
                                        ) {
                                            Text(lan)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    if desktopSession.currentPaired?.deviceID == desk.deviceID, desktopSession.isStreaming {
                                        Text(desktopSession.pathLabel.isEmpty
                                             ? String(localized: "Connected")
                                             : desktopSession.pathLabel)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.green)
                                    } else if !desk.canReconnect {
                                        Text(String(localized: "Re-pair"))
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.deleteDesktop(desk)
                                } label: {
                                    Label(String(localized: "Delete"), systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text(String(localized: "Remote Desktop"))
                    }
                }
            }
        }
        .navigationTitle("Hosts")
        // Re-show tab bar only while this list is the top page. Never while
        // DesktopViewer / Terminal is pushed (that was undoing .toolbar(.hidden)).
        .toolbar(activeDesktop == nil ? .visible : .hidden, for: .tabBar)
        .background(RestoreTabBarWhenVisible(enabled: activeDesktop == nil))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editingServer = store.makeDefaultSSHHost()
                        showingEditor = true
                    } label: {
                        Label(String(localized: "Add SSH Host"), systemImage: "server.rack")
                    }
                    Button {
                        showScanner = true
                    } label: {
                        Label(String(localized: "Scan Desktop QR"), systemImage: "qrcode.viewfinder")
                    }
                    Button {
                        showPaste = true
                    } label: {
                        Label(String(localized: "Paste Pairing Code"), systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            HostEditorView(server: editingServer ?? store.makeDefaultSSHHost()) { saved in
                store.upsertServer(saved)
            }
        }
        .sheet(isPresented: $showDeleteConfirm, onDismiss: {
            hostsPendingDelete = []
        }) {
            CountdownDeleteConfirmView(
                title: String(localized: "Delete Host?"),
                message: hostDeleteMessage,
                confirmLabel: String(localized: "Delete Host"),
                onConfirm: {
                    hostsPendingDelete.forEach(store.deleteServer)
                    hostsPendingDelete = []
                    showDeleteConfirm = false
                },
                onCancel: {
                    hostsPendingDelete = []
                    showDeleteConfirm = false
                }
            )
        }
        .sheet(isPresented: $showScanner) {
            PairScanView(pairingInFlight: $connecting) { payload in
                // Dismiss immediately — keeping the camera sheet open through
                // BIND/Noise caused "stuck on scan + Connecting…" and re-scan thrash.
                pendingPayload = payload
                showScanner = false
                Task { await pairDesktop(payload) }
            }
        }
        .sheet(isPresented: $showPaste) {
            PairPasteView { payload in
                pendingPayload = payload
                showPaste = false
                Task { await pairDesktop(payload) }
            }
        }
        .navigationDestination(item: $activeDesktop) { _ in
            DesktopViewerView(session: desktopSession)
                .onChange(of: desktopSession.pathLabel) { _, _ in
                    guard let p = desktopSession.currentPaired else { return }
                    store.upsertDesktop(p)
                    // Same id → keep navigation item stable. Replacing Hashable fields
                    // was briefly nil'ing the destination and killing in-flight connect.
                    if activeDesktop?.id != p.id {
                        activeDesktop = p
                    }
                }
                .onChange(of: desktopSession.lanEndpointsDisplay) { _, _ in
                    guard let p = desktopSession.currentPaired else { return }
                    store.upsertDesktop(p)
                }
                .onChange(of: desktopSession.isStreaming) { _, streaming in
                    guard streaming, let desk = desktopSession.currentPaired else { return }
                    Task { await syncDesktopAgentChats(desk: desk, session: desktopSession) }
                }
        }
        .overlay {
            // Only on the host list — viewer has its own status. Otherwise a mid-connect
            // pop leaves "Opening desktop…" stuck over the list forever.
            if connecting, activeDesktop == nil {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    ProgressView(
                        desktopSession.statusText.isEmpty
                            ? String(localized: "Connecting…")
                            : desktopSession.statusText
                    )
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        // Push viewer as soon as PairRedeem yields a profile (like reconnect),
        // so status is not stuck behind a frozen Hosts overlay.
        .onChange(of: desktopSession.phase) { _, phase in
            guard connecting, activeDesktop == nil,
                  let p = desktopSession.currentPaired else { return }
            switch phase {
            case .binding, .associating, .openingDesktop, .streaming, .reconnecting:
                store.upsertDesktop(p)
                activeDesktop = p
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kokoE2EShowDesktop)) { note in
            guard let desk = note.userInfo?["desktop"] as? PairedDesktop else { return }
            store.upsertDesktop(desk)
            connecting = true
            activeDesktop = desk
        }
        .onChange(of: activeDesktop) { _, desk in
            guard desk == nil else { return }
            leaveDesktopEpoch &+= 1
            let epoch = leaveDesktopEpoch
            Task { @MainActor in
                // Debounce: Hashable field churn on PairedDesktop can briefly nil
                // navigationDestination mid-connect / quality reopen.
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard epoch == leaveDesktopEpoch, activeDesktop == nil else { return }
                let phase = desktopSession.phase
                let busy = desktopSession.isStreaming
                    || phase == .pairing || phase == .binding || phase == .associating
                    || phase == .openingDesktop || phase == .reconnecting
                if busy {
                    // Still connecting under a nil destination flash — do not kill WSS.
                    return
                }
                connecting = false
                desktopSession.disconnect(userInitiated: true)
            }
        }
        .alert(String(localized: "Connection Failed"), isPresented: Binding(
            get: { connectError != nil },
            set: { if !$0 { connectError = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(connectError ?? "")
        }
        .alert(String(localized: "Computer In Use"), isPresented: Binding(
            get: { takeoverDesk != nil },
            set: { if !$0 { takeoverDesk = nil } }
        )) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Take Over"), role: .destructive) {
                if let d = takeoverDesk {
                    let pw = takeoverPassword
                    Task { await reconnectDesktop(d, password: pw, force: true) }
                }
            }
        } message: {
            Text(takeoverPeer.isEmpty
                 ? String(localized: "Another device is controlling this computer. Continue and disconnect it?")
                 : String(localized: "\(takeoverPeer) is controlling this computer. Continue and disconnect it?"))
        }
        .alert(String(localized: "Session Password"), isPresented: $askPassword) {
            SecureField(String(localized: "Password"), text: $password)
            Button(String(localized: "Cancel"), role: .cancel) {
                pendingPayload = nil
                pendingReconnect = nil
            }
            Button(String(localized: "Connect")) {
                if let p = pendingPayload {
                    Task { await pairDesktop(p, password: password) }
                } else if let d = pendingReconnect {
                    Task { await reconnectDesktop(d, password: password) }
                }
            }
        } message: {
            Text(String(localized: "This Agent requires a session password."))
        }
        .onAppear {
            if let p = pendingPair.take() {
                pendingPayload = p
                Task { await pairDesktop(p) }
            }
        }
        .onChange(of: pendingPair.payload) { _, new in
            guard let new else { return }
            _ = pendingPair.take()
            pendingPayload = new
            Task { await pairDesktop(new) }
        }
    }

    private var hostDeleteMessage: String {
        if hostsPendingDelete.count == 1, let host = hostsPendingDelete.first {
            return String(
                format: String(localized: "Delete %@? Related sessions on this device will also be removed."),
                host.name
            )
        }
        return String(localized: "Delete the selected hosts? Related sessions on this device will also be removed.")
    }

    /// `LAN host:port` line for Remote Desktop rows (QR + live PreferDirect).
    private static func lanSubtitle(desk: PairedDesktop, live: String?) -> String? {
        let liveTrim = live?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !liveTrim.isEmpty {
            return "LAN \(liveTrim)"
        }
        let saved = desk.lanCandidates
            .filter { !$0.isEmpty && !$0.hasSuffix(":0") }
            .joined(separator: " · ")
        guard !saved.isEmpty else { return nil }
        return "LAN \(saved)"
    }

    @ViewBuilder
    private func hostRow(for server: ServerProfile) -> some View {
        let label = HStack {
            Image(systemName: "server.rack")
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name).font(.headline)
                Text("\(server.username)@\(server.host):\(server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let selectedServerId {
            Button {
                selectedServerId.wrappedValue = server.id
            } label: {
                label
            }
            .buttonStyle(.plain)
            .modifier(SessionRowHighlight(isHighlighted: selectedServerId.wrappedValue == server.id))
        } else {
            NavigationLink {
                ServerDetailView(server: server, onPickSession: onPickSession)
            } label: {
                label
            }
        }
    }

    private func pairDesktop(_ payload: RE2PairingPayload, password: String? = nil) async {
        connecting = true
        connectError = nil
        showScanner = false
        showPaste = false
        do {
            let profile = try await desktopSession.connect(payload: payload, accessPassword: password)
            let stored = store.upsertDesktop(profile)
            desktopSession.adoptStoredIdentity(stored)
            activeDesktop = stored
        } catch let err as RE2Error {
            if case .cancelled = err {
                // superseded
            } else if case .controllerBusy(let peer) = err, let redeemed = desktopSession.currentPaired {
                // The QR token is already redeemed; keep the pair and take over via reconnect.
                let stored = store.upsertDesktop(redeemed)
                desktopSession.adoptStoredIdentity(stored)
                askTakeover(stored, peer: peer, password: password)
            } else if case .signaling(let m) = err, m.lowercased().contains("password") {
                askPassword = true
            } else {
                connectError = [err.localizedDescription, err.recoveryHint]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
            }
        } catch is CancellationError {
            // ignore
        } catch {
            connectError = error.localizedDescription
        }
        connecting = false
    }

    private func askTakeover(_ desk: PairedDesktop, peer: String, password: String?) {
        takeoverPeer = peer
        takeoverPassword = password
        takeoverDesk = desk
    }

    private func reconnectDesktop(_ desk: PairedDesktop, password: String? = nil, force: Bool = false) async {
        connecting = true
        connectError = nil
        // Show viewer immediately so Encrypting… / pathLabel are visible while reconnecting.
        activeDesktop = desk
        do {
            try await desktopSession.reconnect(profile: desk, accessPassword: password, force: force)
            if let updated = desktopSession.currentPaired {
                store.upsertDesktop(updated)
                if activeDesktop?.id != updated.id {
                    activeDesktop = updated
                }
            }
        } catch let err as RE2Error {
            if case .cancelled = err { connecting = false; return }
            if case .controllerBusy(let peer) = err {
                activeDesktop = nil
                connecting = false
                askTakeover(desk, peer: peer, password: password)
                return
            }
            connectError = [err.localizedDescription, err.recoveryHint]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        } catch is CancellationError {
            // Superseded by another reconnect (network / foreground) — not a user-facing failure.
        } catch {
            connectError = error.localizedDescription
        }
        connecting = false
    }

    /// Pull Cursor/Claude/Codex/Gemini chats over the live data tunnel (no extra BIND).
    private func syncDesktopAgentChats(desk: PairedDesktop, session: RE2DesktopSession) async {
        do {
            let conversations = try await session.listAgentChats()
            let canonicalDesk = store.desktops.first(where: { $0.deviceID == desk.deviceID }) ?? desk
            let rows = conversations.map { c in
                DesktopAgentChat(
                    id: DesktopAgentChat.stableID(desktopId: canonicalDesk.id, kind: c.agentKind, chatId: c.chatId),
                    desktopId: canonicalDesk.id,
                    desktopName: canonicalDesk.name,
                    agentKind: c.agentKind,
                    chatId: c.chatId,
                    title: c.title,
                    cwd: c.cwd,
                    updatedAt: c.updatedAt,
                    screenName: c.screenName,
                    screenAlive: c.screenAlive,
                    source: c.source,
                    clientName: c.client
                )
            }
            store.replaceDesktopAgentChats(desktopId: canonicalDesk.id, chats: rows)
        } catch {
            RE2Log.error("desktop agent chat sync: \(error.localizedDescription)")
        }
    }
}

struct ServerDetailView: View {
    @EnvironmentObject private var store: AppStore
    let server: ServerProfile
    var onPickSession: ((TerminalSession) -> Void)? = nil
    @State private var showingEditor = false

    private var currentServer: ServerProfile {
        store.server(for: server.id) ?? server
    }

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Address", value: currentServer.host)
                LabeledContent("Port", value: "\(currentServer.port)")
                LabeledContent("User", value: currentServer.username)
                LabeledContent("Auth", value: authLabel(for: currentServer))
                if let fingerprint = currentServer.hostKeyFingerprint {
                    LabeledContent("Fingerprint", value: fingerprint)
                        .font(.caption)
                }
            }

            Section("Projects") {
                if currentServer.projects.isEmpty {
                    Text("No projects configured")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(currentServer.projects) { project in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.label).font(.headline)
                            Text(project.remotePath.isEmpty ? "(home)" : project.remotePath)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                NavigationLink("Session List") {
                    SessionListView(
                        serverFilter: currentServer.id,
                        onPickSession: onPickSession
                    )
                }
            }
        }
        .navigationTitle(currentServer.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showingEditor = true }
            }
        }
        .sheet(isPresented: $showingEditor) {
            HostEditorView(server: currentServer) { saved in
                store.upsertServer(saved)
            }
        }
    }

    private func authLabel(for server: ServerProfile) -> String {
        switch server.authType {
        case .password:
            return String(localized: "Password")
        case .key:
            if let key = store.keyPair(for: server.keyPairId) {
                return String(localized: "Key") + " · \(key.label)"
            }
            return String(localized: "Key")
        }
    }
}
