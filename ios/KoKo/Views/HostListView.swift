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
                            NavigationLink {
                                DesktopHostDetailView(desktop: desk) {
                                    openRemoteDesktop(desk)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(desk.name).font(.headline)
                                        if let health = store.hostHealth(for: desk.id) {
                                            Text(Self.healthSubtitle(health))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        } else {
                                            Text(String(localized: "Status unavailable"))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if !desk.canReconnect {
                                        Text(String(localized: "Re-pair"))
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .foregroundStyle(.primary)
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
                        Text(String(localized: "Desktop Hosts"))
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
                    // Only restore during an in-progress connect — after the user
                    // leaves, this would push the viewer right back (a one-frame pop).
                    if connecting, activeDesktop?.id != p.id {
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
            Text(RE2Error.controllerBusy(peer: takeoverPeer).localizedDescription)
        }
        .alert(String(localized: "Session Taken Over"), isPresented: Binding(
            get: { activeDesktop == nil && desktopSession.kickAlertMessage != nil },
            set: { if !$0 { desktopSession.kickAlertMessage = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) {
                desktopSession.kickAlertMessage = nil
            }
        } message: {
            Text(desktopSession.kickAlertMessage ?? "")
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
            consumePendingOpenDesktop()
        }
        .onChange(of: store.pendingOpenDesktopId) { _, _ in
            consumePendingOpenDesktop()
        }
        .task {
            while !Task.isCancelled {
                await refreshDesktopHealth()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
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

    private static func healthSubtitle(_ health: DesktopHostHealth) -> String {
        let age = RelativeDateTimeFormatter().localizedString(for: health.fetchedAt, relativeTo: .now)
        guard health.reachability == .online, let snapshot = health.snapshot else {
            let state = health.reachability == .offline
                ? String(localized: "Offline")
                : String(localized: "Last status")
            return "\(state) · \(age)"
        }
        if snapshot.phase == "booted_waiting_login" {
            return String(localized: "Powered on · waiting for login")
        }
        if snapshot.phase == "user_logged_in" {
            return String(localized: "Logged in · Agent starting")
        }
        var parts = [String(localized: "Online")]
        if let power = snapshot.power, power.available {
            parts.append(power.onAc ? String(localized: "AC") : String(localized: "Battery"))
            if power.batteryPercent >= 0 { parts.append("\(power.batteryPercent)%") }
            if power.sleepDisabled { parts.append(String(localized: "Lid-close awake")) }
        }
        return parts.joined(separator: " · ")
    }

    private func refreshDesktopHealth() async {
        for desk in store.desktops where desk.canReconnect {
            _ = try? await desktopHub.fetchHostHealth(for: desk)
        }
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
            let profile = try await desktopSession.connect(
                payload: payload,
                accessPassword: password,
                openDesktop: false
            )
            let stored = store.upsertDesktop(profile)
            desktopSession.adoptStoredIdentity(stored)
            _ = try? await desktopHub.fetchHostHealth(for: stored)
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

    private func consumePendingOpenDesktop() {
        guard let id = store.pendingOpenDesktopId else { return }
        guard let desk = store.desktops.first(where: { $0.id == id }) else {
            store.pendingOpenDesktopId = nil
            return
        }
        store.pendingOpenDesktopId = nil
        openRemoteDesktop(desk)
    }

    private func openRemoteDesktop(_ desk: PairedDesktop) {
        // Reattach to the session kept alive after Back; a second connect would
        // race the Agent's still-live UDP stream.
        if desktopSession.currentPaired?.deviceID == desk.deviceID,
           desktopSession.holdsAgentPeer {
            activeDesktop = desk
            return
        }
        pendingReconnect = desk
        let saved = RE2DesktopSecrets.loadPassword(desktopID: desk.id)
        Task { await reconnectDesktop(desk, password: saved) }
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
                _ = try? await desktopHub.fetchHostHealth(for: updated)
            }
        } catch let err as RE2Error {
            if case .cancelled = err { connecting = false; return }
            if case .controllerBusy(let peer) = err {
                activeDesktop = nil
                connecting = false
                askTakeover(desk, peer: peer, password: password)
                return
            }
            if case .signaling(let message) = err,
               message.lowercased().contains("password") {
                activeDesktop = nil
                connecting = false
                pendingReconnect = desk
                askPassword = true
                return
            }
            connectError = [err.localizedDescription, err.recoveryHint]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            // Close the half-open viewer so "Binding…" does not stick after a timeout.
            activeDesktop = nil
        } catch is CancellationError {
            // Superseded by another reconnect (network / foreground) — not a user-facing failure.
        } catch {
            connectError = error.localizedDescription
            activeDesktop = nil
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

private struct DesktopHostDetailView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var desktopHub = DesktopSessionHub.shared
    let desktop: PairedDesktop
    let onRemoteDesktop: () -> Void

    private var currentDesktop: PairedDesktop {
        store.desktops.first(where: { $0.id == desktop.id }) ?? desktop
    }

    private var health: DesktopHostHealth? {
        store.hostHealth(for: currentDesktop.id)
    }

    private var events: [HostPowerEvent] {
        store.hostPowerEvents.filter { $0.desktopId == currentDesktop.id }
    }

    private var projectDirectories: [String] {
        var seen = Set<String>()
        return store.desktopAgentChats
            .filter { $0.desktopId == currentDesktop.id }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { $0.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var body: some View {
        List {
            Section("Host Health") {
                LabeledContent("Computer", value: currentDesktop.name)
                LabeledContent("Reachability", value: health?.reachability.rawValue ?? "unknown")
                if let fetchedAt = health?.fetchedAt {
                    LabeledContent("Last heartbeat", value: fetchedAt.formatted(date: .abbreviated, time: .standard))
                }
                if let reason = health?.offlineReason, !reason.isEmpty {
                    LabeledContent("Offline reason", value: reason)
                }
                if let snapshot = health?.snapshot {
                    LabeledContent("Phase", value: snapshot.phase ?? "unknown")
                    LabeledContent("Agent", value: snapshot.agentVersion ?? "unknown")
                    LabeledContent("Thermal", value: snapshot.thermal ?? "unknown")
                    if let user = snapshot.consoleUser, !user.isEmpty {
                        LabeledContent("Console user", value: user)
                    } else {
                        LabeledContent("Console user", value: String(localized: "Waiting for login"))
                    }
                }
            }
            if let power = health?.snapshot?.power {
                Section("Power") {
                    LabeledContent("Source", value: power.onAc ? String(localized: "AC") : String(localized: "Battery"))
                    if power.batteryPercent >= 0 {
                        LabeledContent("Battery", value: "\(power.batteryPercent)%")
                    }
                    LabeledContent("Mac mini mode", value: power.mode ?? "unknown")
                    LabeledContent("Lid-close awake", value: power.sleepDisabled ? String(localized: "Yes") : String(localized: "No"))
                    if power.lowBattery {
                        Label("Low-battery protection is active", systemImage: "battery.25")
                            .foregroundStyle(.orange)
                    }
                }
            }
            if let disk = health?.snapshot?.disk {
                Section("Storage") {
                    LabeledContent("Free", value: ByteCountFormatter.string(fromByteCount: Int64(disk.freeBytes), countStyle: .file))
                    LabeledContent("Total", value: ByteCountFormatter.string(fromByteCount: Int64(disk.totalBytes), countStyle: .file))
                }
            }
            if let ups = health?.snapshot?.ups {
                Section("UPS") {
                    LabeledContent("Reachable", value: ups.reachable ? String(localized: "Yes") : String(localized: "No"))
                    if let status = ups.status { LabeledContent("Status", value: status) }
                    if let error = ups.error { Text(error).foregroundStyle(.secondary) }
                }
            }
            if !events.isEmpty {
                Section("Recent power events") {
                    ForEach(events.sorted { $0.timeUnix > $1.timeUnix }.prefix(20)) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.event)
                            if let detail = event.detail, !detail.isEmpty {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(Date(timeIntervalSince1970: TimeInterval(event.timeUnix)).formatted())
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Section("Projects") {
                if projectDirectories.isEmpty {
                    Text("No project directories discovered")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(projectDirectories, id: \.self) { directory in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(fileURLWithPath: directory).lastPathComponent)
                                .font(.headline)
                            Text(DesktopPath.abbreviate(directory))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                NavigationLink("Session List") {
                    SessionListView(desktopFilter: currentDesktop.id)
                }
                Button {
                    onRemoteDesktop()
                } label: {
                    Label("Remote Control Desktop", systemImage: "display")
                }
                .disabled(!currentDesktop.canReconnect)
            }
        }
        .navigationTitle(currentDesktop.name)
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    private func refresh() async {
        _ = try? await desktopHub.fetchHostHealth(for: currentDesktop)
        guard let conversations = try? await desktopHub.listAgentChats(for: currentDesktop) else { return }
        let rows = conversations.map { conversation in
            DesktopAgentChat(
                id: DesktopAgentChat.stableID(
                    desktopId: currentDesktop.id,
                    kind: conversation.agentKind,
                    chatId: conversation.chatId
                ),
                desktopId: currentDesktop.id,
                desktopName: currentDesktop.name,
                agentKind: conversation.agentKind,
                chatId: conversation.chatId,
                title: conversation.title,
                cwd: conversation.cwd,
                updatedAt: conversation.updatedAt,
                screenName: conversation.screenName,
                screenAlive: conversation.screenAlive,
                source: conversation.source,
                clientName: conversation.client
            )
        }
        store.replaceDesktopAgentChats(desktopId: currentDesktop.id, chats: rows)
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
