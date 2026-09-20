import SwiftUI

struct TerminalScreenView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var workspaceRegistry = WorkspaceRegistry.shared
    let session: TerminalSession

    @State private var workspace: TerminalWorkspace?

    private var liveSession: TerminalSession {
        store.sessions.first(where: { $0.id == session.id }) ?? session
    }

    var body: some View {
        Group {
            if let workspace {
                // Must observe the workspace — `@State` alone won't refresh toolbar on connect.
                TerminalScreenContent(workspace: workspace, session: liveSession)
            } else {
                ProgressView("Initializing terminal…")
            }
        }
        .onAppear {
            if workspace == nil {
                workspace = workspaceRegistry.workspace(for: session.id)
            }
        }
    }
}

/// Observes `TerminalWorkspace` so connection badge / disconnect update correctly.
private struct TerminalScreenContent: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var workspace: TerminalWorkspace
    let session: TerminalSession

    @State private var showTerminateConfirm = false
    @State private var showForceNewConfirm = false
    @State private var showLoginSheet = false
    @State private var loginURL = ""
    @State private var loginAgentKind: AgentKind = .cursor
    @Environment(\.scenePhase) private var scenePhase

    private var liveSession: TerminalSession {
        store.sessions.first(where: { $0.id == session.id }) ?? session
    }

    var body: some View {
        TerminalContainerView(workspace: workspace)
            .navigationTitle(liveSession.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    connectionBadge
                    Menu {
                        Button("Reconnect") {
                            connect(mode: .preferExisting)
                        }
                        Button("New Agent Session") {
                            showForceNewConfirm = true
                        }
                        Button("Disconnect") {
                            workspace.disconnect()
                        }
                        Button("Terminate Session", role: .destructive) {
                            showTerminateConfirm = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                ensureConnected()
            }
            .onChange(of: workspace.connectionState) { oldState, newState in
                if newState == .connected, oldState != .connected {
                    syncSessionIdentityAfterConnect()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    // App 进后台再断 SSH；切 Tab / 回列表不断线，回来还能接着用。
                    workspace.disconnect()
                case .active:
                    ensureConnected()
                default:
                    break
                }
            }
            .onChange(of: workspace.awaitingAgentLogin) { _, awaiting in
                guard awaiting else { return }
                loginAgentKind = workspace.loginAgentKind ?? liveSession.agentKind
                showLoginSheet = true
            }
            .onChange(of: workspace.detectedLoginCode) { _, newValue in
                guard newValue != nil else { return }
                loginAgentKind = workspace.loginAgentKind ?? liveSession.agentKind
                showLoginSheet = true
            }
            .onChange(of: workspace.detectedLoginURL) { _, newValue in
                guard let newValue else { return }
                loginURL = newValue
                loginAgentKind = workspace.loginAgentKind ?? liveSession.agentKind
                showLoginSheet = true
            }
            .confirmationDialog("Terminate Session?", isPresented: $showTerminateConfirm) {
                Button("Terminate", role: .destructive) {
                    workspace.terminateSession()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Stops the remote agent or screen session on the server. Disconnect only closes this phone's SSH link.")
            }
            .confirmationDialog("Start a new agent?", isPresented: $showForceNewConfirm) {
                Button("New Agent Session", role: .destructive) {
                    connect(mode: .forceNew)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Stops the current remote session and starts a fresh one.")
            }
            .sheet(isPresented: $showLoginSheet) {
                AgentLoginView(
                    agentKind: loginAgentKind,
                    loginURL: workspace.detectedLoginURL ?? loginURL,
                    loginCode: workspace.detectedLoginCode,
                    onPasteCodeToTerminal: { code in
                        workspace.submitLoginCode(code)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .confirmationDialog(
                agentInstallTitle(for: workspace.agentInstallPrompt?.agentKind),
                isPresented: Binding(
                    get: { workspace.agentInstallPrompt != nil },
                    set: { if !$0 { workspace.cancelAgentInstallPrompt() } }
                ),
                titleVisibility: .visible
            ) {
                Button("一键安装") {
                    workspace.respondToAgentInstall(install: true)
                }
                Button("仅用 SSH") {
                    workspace.respondToAgentInstall(install: false)
                }
                Button("取消", role: .cancel) {
                    workspace.cancelAgentInstallPrompt()
                }
            } message: {
                if let prompt = workspace.agentInstallPrompt {
                    Text(agentInstallMessage(for: prompt))
                }
            }
    }

    private func agentInstallTitle(for kind: AgentKind?) -> String {
        guard let kind else { return "安装 CLI？" }
        return "安装 \(kind.displayName) CLI？"
    }

    private func agentInstallMessage(for prompt: AgentInstallPrompt) -> String {
        "服务器「\(prompt.serverName)」未检测到 \(prompt.agentKind.displayName) 命令行。安装后可像 Mac 终端一样连接；选择「仅用 SSH」则进入普通 shell。"
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch workspace.connectionState {
        case .connected:
            Image(systemName: "circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Connected")
        case .connecting, .reconnecting:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .ended:
            Image(systemName: "moon.fill")
                .foregroundStyle(.secondary)
        case .disconnected:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }

    private func ensureConnected() {
        switch workspace.connectionState {
        case .connected, .connecting, .reconnecting:
            return
        case .ended:
            return
        case .disconnected, .failed:
            connect(mode: .preferExisting)
        }
    }

    private func connect(mode: RemoteBootstrap.LaunchMode) {
        guard let server = store.server(for: liveSession.serverId) else {
            workspace.reportSetupFailure("This conversation has no linked host. Open Hosts and sync again.")
            return
        }
        guard let project = store.project(for: liveSession) else {
            workspace.reportSetupFailure("This conversation has no project path. Open Hosts and sync again.")
            return
        }

        let keyPair = store.keyPair(for: server.keyPairId)
        workspace.connect(
            server: server,
            keyPair: keyPair,
            session: liveSession,
            projectPath: project.remotePath,
            mode: mode,
            onHostKeyPrompt: { prompt in
                store.hostKeyPrompt = prompt
            },
            onHostKeySaved: { serverId, fingerprint in
                store.saveHostKey(serverId: serverId, fingerprint: fingerprint)
            }
        )
        store.touchSession(liveSession.id)
    }

    private func syncSessionIdentityAfterConnect() {
        guard workspace.connectionState == .connected else { return }
        guard let server = store.server(for: liveSession.serverId),
              let project = store.project(for: liveSession) else { return }

        Task {
            // Give the remote agent a moment to write session metadata.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await AgentSessionSync.applyForSession(
                liveSession,
                to: store,
                server: server,
                keyPair: store.keyPair(for: server.keyPairId),
                projectPath: project.remotePath,
                onHostKeyUnknown: { fingerprint in
                    Task { @MainActor in
                        store.hostKeyPrompt = HostKeyPrompt(serverId: server.id, fingerprint: fingerprint)
                    }
                }
            )
        }
    }
}

struct HostKeyConfirmView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let prompt: HostKeyPrompt

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Confirm the server host key fingerprint")
                    .font(.headline)
                Text(prompt.fingerprint)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Connections are blocked if the fingerprint changes. Verify it with your server admin.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("Host Fingerprint")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reject") {
                        if let ws = findActiveWorkspace() {
                            ws.rejectPendingHostKey()
                        }
                        HostKeyApprovalGate.shared.reject()
                        store.hostKeyPrompt = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust & Connect") {
                        store.saveHostKey(serverId: prompt.serverId, fingerprint: prompt.fingerprint)
                        if let ws = findActiveWorkspace() {
                            ws.approvePendingHostKey(serverId: prompt.serverId) { serverId, fingerprint in
                                store.saveHostKey(serverId: serverId, fingerprint: fingerprint)
                            }
                        }
                        HostKeyApprovalGate.shared.approve()
                        store.hostKeyPrompt = nil
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func findActiveWorkspace() -> TerminalWorkspace? {
        for session in store.sessions {
            let ws = WorkspaceRegistry.shared.workspace(for: session.id)
            if ws.connectionState == .connecting {
                return ws
            }
        }
        return nil
    }
}

struct AgentLoginView: View {
    let agentKind: AgentKind
    let loginURL: String
    let loginCode: String?
    let onPasteCodeToTerminal: (String) -> Void

    @State private var authCodeInput = ""
    @State private var codeSentToTerminal = false

    init(
        agentKind: AgentKind,
        loginURL: String,
        loginCode: String? = nil,
        onPasteCodeToTerminal: @escaping (String) -> Void = { _ in }
    ) {
        self.agentKind = agentKind
        self.loginURL = loginURL
        self.loginCode = loginCode
        self.onPasteCodeToTerminal = onPasteCodeToTerminal
    }

    private var navigationTitle: String {
        switch agentKind {
        case .cursor: return String(localized: "Cursor Login")
        case .claude: return String(localized: "Claude Login")
        case .codex: return String(localized: "Codex Login")
        case .gemini: return String(localized: "Gemini Login")
        }
    }

    private var headline: String {
        String(localized: "\(agentKind.displayName) is not signed in")
    }

    private var instructions: String {
        switch agentKind {
        case .cursor:
            return String(
                localized: "Copy the link and sign in in your browser. Switch back to KoKo when done — the session reconnects automatically."
            )
        case .codex:
            return String(
                localized: "Open the link in your browser and enter the one-time code there. Switch back to KoKo when done — the session reconnects automatically."
            )
        case .claude:
            return String(
                localized: "Open the link and sign in. Paste the authorization code into the field below, then tap Send to server terminal."
            )
        case .gemini:
            return String(
                localized: "Open the link and sign in. Paste the authorization code into the field below, then tap Send to server terminal."
            )
        }
    }

    private var waitingForLoginLink: Bool {
        loginURL.isEmpty
    }

    private var waitingForLoginContent: Bool {
        if agentKind.requiresTerminalAuthCode {
            return false
        }
        return loginURL.isEmpty && loginCode == nil
    }

    private var trimmedAuthCodeInput: String {
        authCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sanitizedDeviceCode: String? {
        guard let loginCode else { return nil }
        return LoginURLParser.sanitizeDeviceCode(loginCode)
    }

    @ViewBuilder
    private func loginLinkSection(url: String) -> some View {
        Text("Login link")
            .font(.subheadline.weight(.semibold))
        Text(url)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        Button("Copy Link") {
            UIPasteboard.general.string = url
        }
        .buttonStyle(.bordered)
        if let openURL = URL(string: url) {
            Link("Open in Browser", destination: openURL)
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func codexDeviceCodeSection(code: String) -> some View {
        Text("One-time code")
            .font(.subheadline.weight(.semibold))
        Text(code)
            .font(.title3.monospaced().weight(.semibold))
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        Button("Copy Code") {
            UIPasteboard.general.string = code
        }
        .buttonStyle(.bordered)
    }

    private func sendCodeToTerminal() {
        let code = trimmedAuthCodeInput
        guard !code.isEmpty else { return }
        onPasteCodeToTerminal(code)
        codeSentToTerminal = true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(headline)
                        .font(.headline)
                    Text(instructions)
                        .foregroundStyle(.secondary)
                    if waitingForLoginContent {
                        ProgressView("Waiting for login link in terminal…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        if agentKind.requiresTerminalAuthCode {
                            if waitingForLoginLink {
                                ProgressView("Waiting for login link in terminal…")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                loginLinkSection(url: loginURL)
                            }

                            Text("Authorization code")
                                .font(.subheadline.weight(.semibold))
                            TextField("Authorization code", text: $authCodeInput)
                                .font(.body.monospaced())
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textContentType(.oneTimeCode)
                                .padding(12)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))

                            Button("Send authorization code to terminal") {
                                sendCodeToTerminal()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(trimmedAuthCodeInput.isEmpty)

                            if codeSentToTerminal {
                                Text("Code sent to server terminal")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        } else if let deviceCode = sanitizedDeviceCode {
                            if !loginURL.isEmpty {
                                loginLinkSection(url: loginURL)
                            } else if waitingForLoginLink {
                                ProgressView("Waiting for login link in terminal…")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            codexDeviceCodeSection(code: deviceCode)
                        } else if !loginURL.isEmpty {
                            loginLinkSection(url: loginURL)
                        } else if agentKind == .codex {
                            ProgressView("Waiting for login link in terminal…")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Text("Switch back to KoKo to reconnect automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var languageStore: AppLanguageStore

    var body: some View {
        List {
            Section {
                Picker("Language", selection: $languageStore.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Affects KoKo UI only. Terminal / agent output follows the remote session.")
            }

            Section {
                LabeledContent("Version", value: AppBuildInfo.displayVersion)
                    .textSelection(.enabled)
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
    }
}
