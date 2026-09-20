import Citadel
import Foundation
import NIO
import NIOSSH
import SwiftTerm
import UIKit

@MainActor
final class TerminalWorkspace: ObservableObject {
    @Published private(set) var connectionState: SessionConnectionState = .disconnected
    @Published var title: String = "KoKo"
    @Published var isPinnedToBottom = true
    @Published var detectedLoginURL: String?
    @Published var detectedLoginCode: String?
    @Published private(set) var loginAgentKind: AgentKind?
    @Published private(set) var awaitingAgentLogin = false
    @Published private(set) var agentInstallPrompt: AgentInstallPrompt?
    /// Local KoKo connect / status log — shown above the PTY, never inside it.
    @Published private(set) var localStatusEvents: [LocalStatusEvent] = []
    @Published private(set) var terminalFontSize: CGFloat

    let terminalView: TerminalView
    private let sessionId: UUID
    private var connectionTask: Task<Void, Never>?
    private var stdinWriter: TTYStdinWriter?
    private var sshClient: SSHClient?
    private var pendingFingerprint: String?
    private var loginDetectionBuffer = ""
    /// When true, close/cancel errors are silent (no terminal spam).
    private var intentionalClose = false
    private var activeSession: TerminalSession?
    private var activeServer: ServerProfile?
    private var connectGeneration = 0
    /// Batched scrollback/login parsing — never block the SSH reader.
    private var pendingScrollback = Data()
    private var scrollbackFlushScheduled = false
    /// Ordered stdin queue — one drain task, no per-key await chain.
    private var stdinPending = Data()
    private var stdinDrainTask: Task<Void, Never>?
    private var didWarnInputNotReady = false
    private var agentInstallContinuation: CheckedContinuation<AgentInstallDecision, Never>?
    /// Long remote setup (CLI install) can exceed the connect watchdog — keep it alive.
    private var remoteSetupInProgress = false
    /// Defer ScrollbackStore restore until PTY is live (avoid stale cache while connecting).
    private var pendingScrollbackRestore = false
    /// While replaying saved bytes, ignore CSI queries and block stdin (DA answers leak into Agent input).
    private var suppressTerminalResponsesDuringReplay = false

    enum AgentInstallDecision {
        case install
        case plainSSH
        case cancel
    }

    private static let connectTimeoutSeconds: UInt64 = 25
    /// Local dump of the full conversation plus live viewport; inertia stays on-device.
    private static let scrollbackLines = 50_000
    private static let maxLocalStatusEvents = 40
    /// Google OAuth links are long; keep enough rolling context to avoid truncating `https://`.
    private static let loginDetectionBufferLimit = 65_536
    private static let loginDetectionBufferKeep = 32_768
    private static let fontSizeDefaultsKey = "koko.terminalFontSize"
    static let minTerminalFontSize: CGFloat = 7
    static let maxTerminalFontSize: CGFloat = 14
    static let defaultTerminalFontSize: CGFloat = 7

    init(sessionId: UUID) {
        self.sessionId = sessionId
        let savedFontSize = UserDefaults.standard.object(forKey: Self.fontSizeDefaultsKey) as? Double
        let initialFontSize = min(
            max(CGFloat(savedFontSize ?? Double(Self.defaultTerminalFontSize)), Self.minTerminalFontSize),
            Self.maxTerminalFontSize
        )
        self.terminalFontSize = initialFontSize
        let options = TerminalOptions(
            cursorStyle: .blinkBlock,
            scrollback: Self.scrollbackLines
        )
        self.terminalView = TerminalView(
            frame: .zero,
            font: UIFont.monospacedSystemFont(ofSize: initialFontSize, weight: .regular),
            options: options
        )
        self.terminalView.backgroundColor = UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)
        self.terminalView.isOpaque = true
        self.terminalView.isAccessibilityElement = false
        self.terminalView.alwaysBounceVertical = true
        self.terminalView.bounces = true
        self.terminalView.decelerationRate = .normal
        self.terminalView.showsVerticalScrollIndicator = true
        // Stay on the normal buffer when Agent enters the alt screen so local
        // scrollback + UIScrollView inertia can scrub conversation history.
        self.terminalView.allowMouseReporting = false
        self.terminalView.keepHistoryOnFullscreen = true
        self.terminalView.respondToDeviceAttributes = true
        // Metal must be enabled after the view is in a window — see ensureMetalRenderer().
    }

    /// Reload trailing bytes saved for this session (survives disconnect / app restart).
    private func restorePersistedScrollbackIfAvailable() {
        guard let saved = ScrollbackStore.shared.load(sessionId: sessionId), !saved.isEmpty else { return }
        // Replaying scrollback re-parses CSI `c` queries from saved output. Answering them
        // types `ESC [ ?65;…c` into the live Agent prompt (SwiftTerm KoKo note).
        suppressTerminalResponsesDuringReplay = true
        terminalView.respondToDeviceAttributes = false
        terminalView.feed(byteArray: ArraySlice(saved))
        terminalView.respondToDeviceAttributes = true
        suppressTerminalResponsesDuringReplay = false
        terminalView.scrollTo(row: .max, notifyAccessibility: false)
        isPinnedToBottom = true
        if detectedLoginURL == nil || detectedLoginCode == nil {
            scanForLoginCredentials(in: saved)
        }
    }

    private func restoreScrollbackIfPending() {
        guard pendingScrollbackRestore else { return }
        pendingScrollbackRestore = false
        restorePersistedScrollbackIfAvailable()
    }

    /// Blank the on-screen PTY without touching persisted ScrollbackStore bytes.
    private func clearTerminalDisplay() {
        terminalView.softReset()
        terminalView.allowMouseReporting = false
        terminalView.keepHistoryOnFullscreen = true
        terminalView.respondToDeviceAttributes = true
        terminalView.feed(text: "\u{001b}[H\u{001b}[2J")
    }

    /// Prepare the local PTY view before SSH attach.
    private func resetScreenForConnect(mode: RemoteBootstrap.LaunchMode) {
        pendingScrollbackRestore = mode == .preferExisting
        if mode == .forceNew {
            ScrollbackStore.shared.clear(sessionId: sessionId)
            pendingScrollbackRestore = false
        }
        pendingScrollback = Data()
        scrollbackFlushScheduled = false
        isPinnedToBottom = true
        clearTerminalDisplay()
        if mode == .forceNew {
            // Erase scrollback in the terminal emulator (CSI 3 J).
            terminalView.feed(text: "\u{001b}[3J")
        }
    }

    func appendLocalStatus(_ message: String, kind: LocalStatusEvent.Kind = .info) {
        let event = LocalStatusEvent(kind: kind, message: message)
        localStatusEvents.append(event)
        if localStatusEvents.count > Self.maxLocalStatusEvents {
            localStatusEvents.removeFirst(localStatusEvents.count - Self.maxLocalStatusEvents)
        }
    }

    func clearLocalStatus() {
        localStatusEvents.removeAll()
    }

    /// Surface a setup error (missing host/project, etc.) without starting SSH.
    func reportSetupFailure(_ message: String) {
        connectionState = .failed(message)
        appendLocalStatus(message, kind: .error)
    }

    /// Enable/disable GPU renderer. Default off — CG + UIScrollView is reliable for
    /// scrubbing and first-responder keyboard input on iOS.
    func ensureMetalRenderer(enabled: Bool = false) {
        if !enabled {
            if terminalView.isUsingMetalRenderer {
                try? terminalView.setUseMetal(false)
            }
            return
        }
        guard !terminalView.isUsingMetalRenderer else { return }
        do {
            try terminalView.setUseMetal(true)
        } catch {
            // Stay on CoreGraphics.
        }
    }

    func connect(
        server: ServerProfile,
        keyPair: SSHKeyPair?,
        session: TerminalSession,
        projectPath: String,
        mode: RemoteBootstrap.LaunchMode = .preferExisting,
        onHostKeyPrompt: @escaping (HostKeyPrompt) -> Void,
        onHostKeySaved: @escaping (UUID, String) -> Void
    ) {
        // Quietly tear down any prior attempt first.
        closeConnection(updateState: .connecting, feedErrors: false)
        intentionalClose = false
        activeSession = session
        activeServer = server
        title = session.displayName
        detectedLoginURL = nil
        detectedLoginCode = nil
        loginAgentKind = nil
        awaitingAgentLogin = false
        agentInstallPrompt = nil
        agentInstallContinuation = nil
        remoteSetupInProgress = false
        loginDetectionBuffer = ""
        clearLocalStatus()
        didWarnInputNotReady = false
        resetScreenForConnect(mode: mode)
        appendLocalStatus("Connecting to \(server.name)…", kind: .info)
        connectGeneration += 1
        let generation = connectGeneration
        startConnectingWatchdog(generation: generation)

        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.appendLocalStatus("SSH \(server.host):\(server.port) as \(server.username)…", kind: .info)
                try await self.runConnection(
                    server: server,
                    keyPair: keyPair,
                    session: session,
                    projectPath: projectPath,
                    mode: mode,
                    generation: generation,
                    onHostKeyPrompt: onHostKeyPrompt,
                    onHostKeySaved: onHostKeySaved
                )
            } catch is CancellationError {
                await MainActor.run {
                    guard generation == self.connectGeneration else { return }
                    if self.connectionState != .ended && self.connectionState != .disconnected {
                        if case .failed = self.connectionState { return }
                        self.connectionState = .disconnected
                    }
                    self.appendLocalStatus("Disconnected", kind: .info)
                }
            } catch {
                await MainActor.run {
                    guard generation == self.connectGeneration else { return }
                    if self.intentionalClose || Self.isBenignCloseError(error) {
                        if self.connectionState != .ended {
                            if case .failed = self.connectionState { return }
                            self.connectionState = .disconnected
                        }
                        return
                    }
                    let message = SSHErrorMapper.message(for: error)
                    self.connectionState = .failed(message)
                    self.appendLocalStatus(message, kind: .error)
                    HostKeyApprovalGate.shared.reset()
                }
            }
        }
    }

    /// Disconnect SSH; the remote agent / screen session keeps running.
    func disconnect() {
        pendingScrollbackRestore = false
        closeConnection(updateState: .disconnected, feedErrors: false)
        clearTerminalDisplay()
    }

    /// Close SSH and stop the remote agent or screen session.
    func terminateSession() {
        intentionalClose = true
        connectionState = .ended
        if let activeSession, stdinWriter != nil {
            sendText(RemoteBootstrap.killSessionCommand(session: activeSession))
        }
        closeConnection(updateState: .ended, feedErrors: false)
    }

    func sendText(_ text: String) {
        sendBytes(Data(text.utf8))
    }

    /// Paste an OAuth / authorization code into the live remote login prompt.
    func submitLoginCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendText(trimmed + "\n")
    }

    func sendBytes(_ data: Data) {
        guard !data.isEmpty else { return }
        if suppressTerminalResponsesDuringReplay { return }
        guard let writer = stdinWriter else {
            if !didWarnInputNotReady {
                didWarnInputNotReady = true
                appendLocalStatus("Input ignored — session not attached yet", kind: .warning)
            }
            return
        }
        didWarnInputNotReady = false
        let payload = data
        stdinPending.append(payload)
        startStdinDrainIfNeeded()
    }

    /// Each keystroke is sent to the remote PTY immediately (Mac terminal semantics).
    /// A single ordered drain task batches back-to-back keys without waiting one Task per key.
    private func startStdinDrainIfNeeded() {
        guard stdinDrainTask == nil else { return }
        stdinDrainTask = Task { [weak self] in
            guard let self else { return }
            defer { self.stdinDrainTask = nil }
            while !self.stdinPending.isEmpty {
                guard let writer = self.stdinWriter else {
                    self.stdinPending.removeAll(keepingCapacity: false)
                    return
                }
                let chunk = self.stdinPending
                self.stdinPending = Data()
                var buffer = ByteBufferAllocator().buffer(capacity: chunk.count)
                buffer.writeBytes(chunk)
                try? await writer.write(buffer)
            }
        }
    }

    func sendControlKey(_ byte: UInt8) {
        sendBytes(Data([byte]))
    }

    func sendEscapeSequence(_ sequence: String) {
        sendText(sequence)
    }

    func clearAgentInputLine() {
        // Emacs/readline line kill — do not send Ctrl+J (0x0A is newline).
        sendControlKey(0x15) // Ctrl+U
        sendControlKey(0x0B) // Ctrl+K
        sendText(String(repeating: "\u{7f}", count: 64))
    }

    func scrollToBottom() {
        isPinnedToBottom = true
        terminalView.scrollTo(row: .max, notifyAccessibility: false)
    }

    func decreaseTerminalFontSize() {
        setTerminalFontSize(terminalFontSize - 1)
    }

    func increaseTerminalFontSize() {
        setTerminalFontSize(terminalFontSize + 1)
    }

    func setTerminalFontSize(_ size: CGFloat) {
        let clamped = min(max(size.rounded(), Self.minTerminalFontSize), Self.maxTerminalFontSize)
        guard abs(clamped - terminalFontSize) >= 0.5 else { return }

        terminalFontSize = clamped
        terminalView.font = UIFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
        UserDefaults.standard.set(Double(clamped), forKey: Self.fontSizeDefaultsKey)
        syncRemoteTerminalSize()
    }

    /// Push the current on-screen cell grid to the remote PTY (call after layout).
    func syncRemoteTerminalSize() {
        let dimensions = terminalView.terminalDimensions
        resizeTerminal(cols: max(dimensions.cols, 80), rows: max(dimensions.rows, 24))
    }

    func resizeTerminal(cols: Int, rows: Int) {
        guard let stdinWriter else { return }
        let writer = stdinWriter
        Task {
            try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
        }
    }

    func approvePendingHostKey(serverId: UUID, onHostKeySaved: @escaping (UUID, String) -> Void) {
        guard let pendingFingerprint else { return }
        onHostKeySaved(serverId, pendingFingerprint)
        HostKeyApprovalGate.shared.approve()
        self.pendingFingerprint = nil
    }

    func rejectPendingHostKey() {
        pendingFingerprint = nil
        HostKeyApprovalGate.shared.reject()
    }

    func respondToAgentInstall(install: Bool) {
        respondToAgentInstall(decision: install ? .install : .plainSSH)
    }

    func cancelAgentInstallPrompt() {
        respondToAgentInstall(decision: .cancel)
    }

    private func respondToAgentInstall(decision: AgentInstallDecision) {
        agentInstallPrompt = nil
        agentInstallContinuation?.resume(returning: decision)
        agentInstallContinuation = nil
    }

    private func promptForAgentInstall(kind: AgentKind, serverName: String) async -> AgentInstallDecision {
        await withCheckedContinuation { continuation in
            agentInstallContinuation = continuation
            agentInstallPrompt = AgentInstallPrompt(agentKind: kind, serverName: serverName)
        }
    }

    private func closeConnection(updateState: SessionConnectionState, feedErrors: Bool) {
        intentionalClose = !feedErrors
        if agentInstallContinuation != nil {
            agentInstallPrompt = nil
            agentInstallContinuation?.resume(returning: .cancel)
            agentInstallContinuation = nil
        }
        connectGeneration += 1
        connectionTask?.cancel()
        connectionTask = nil
        stdinWriter = nil
        stdinDrainTask?.cancel()
        stdinDrainTask = nil
        stdinPending.removeAll(keepingCapacity: false)
        connectionState = updateState
        // Unblock any host-key sheet still awaiting approval from a prior attempt.
        HostKeyApprovalGate.shared.reset()

        let client = sshClient
        sshClient = nil
        guard let client else { return }
        Task {
            // Bound close so a hung network can't block forever.
            try? await withTimeout(seconds: 3) {
                try await client.close()
            }
        }
    }

    /// If we never reach `.connected`, force a visible failure (PTY / host-key / network hangs).
    private func startConnectingWatchdog(generation: Int) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.connectTimeoutSeconds * 1_000_000_000)
            await MainActor.run {
                guard let self else { return }
                guard generation == self.connectGeneration else { return }
                guard self.connectionState == .connecting || self.connectionState == .reconnecting else { return }
                if self.agentInstallPrompt != nil || self.remoteSetupInProgress {
                    self.startConnectingWatchdog(generation: generation)
                    return
                }
                self.appendLocalStatus("Connection timed out", kind: .error)
                self.closeConnection(
                    updateState: .failed(
                        "Connection timed out. Check network / host key prompt, then tap Reconnect."
                    ),
                    feedErrors: false
                )
            }
        }
    }

    private func runConnection(
        server: ServerProfile,
        keyPair: SSHKeyPair?,
        session: TerminalSession,
        projectPath: String,
        mode: RemoteBootstrap.LaunchMode,
        generation: Int,
        onHostKeyPrompt: @escaping (HostKeyPrompt) -> Void,
        onHostKeySaved: @escaping (UUID, String) -> Void
    ) async throws {
        let authMethod = try SSHAuthBuilder.makeAuthenticationMethod(profile: server, keyPair: keyPair)
        let validator = TOFUHostKeyValidator(expectedFingerprint: server.hostKeyFingerprint) { [weak self] fingerprint in
            Task { @MainActor in
                self?.pendingFingerprint = fingerprint
                self?.appendLocalStatus("Confirm host key fingerprint to continue…", kind: .warning)
                onHostKeyPrompt(HostKeyPrompt(serverId: server.id, fingerprint: fingerprint))
            }
        }

        let client = try await withTimeout(seconds: Self.connectTimeoutSeconds) {
            try await SSHClient.connect(
                host: server.host,
                port: server.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                algorithms: .all
            )
        }

        try Task.checkCancellation()
        guard await MainActor.run(body: { generation == self.connectGeneration && !self.intentionalClose }) else {
            try? await client.close()
            throw CancellationError()
        }

        await MainActor.run {
            self.sshClient = client
            let attachMessage: String = {
                switch session.agentKind {
                case .cursor:
                    return "SSH connected — attaching agent persist…"
                default:
                    return "SSH connected — attaching screen \(session.remoteSessionName)…"
                }
            }()
            self.appendLocalStatus(attachMessage, kind: .success)
        }

        var useAgent = true
        let kind = session.agentKind
        if try await AgentCLIInstaller.isInstalled(kind: kind, using: client) {
            await MainActor.run {
                self.appendLocalStatus("\(kind.displayName) CLI detected", kind: .info)
            }
        } else {
            await MainActor.run {
                self.appendLocalStatus("\(kind.displayName) CLI not found on \(server.name)", kind: .warning)
            }
            let decision = await promptForAgentInstall(kind: kind, serverName: server.name)
            switch decision {
            case .install:
                await MainActor.run {
                    self.appendLocalStatus(
                        "Installing \(kind.displayName) CLI on server (SSH — uses server network, not phone)…",
                        kind: .info
                    )
                    self.remoteSetupInProgress = true
                }
                do {
                    await MainActor.run {
                        if kind.needsNpmBootstrap {
                            self.appendLocalStatus("Checking/installing Node.js/npm on server…", kind: .info)
                        }
                        self.appendLocalStatus("Checking server outbound network…", kind: .info)
                    }
                    try await AgentCLIInstaller.install(kind: kind, using: client)
                    await MainActor.run {
                        self.remoteSetupInProgress = false
                        self.appendLocalStatus("\(kind.displayName) CLI installed on server", kind: .success)
                    }
                } catch {
                    let message: String
                    if let installError = error as? AgentCLIInstallError {
                        message = installError.errorDescription ?? error.localizedDescription
                    } else if let failed = error as? SSHClient.CommandFailed {
                        message = String(
                            format: String(localized: "Server install command failed (exit %lld)"),
                            Int64(failed.exitCode)
                        )
                    } else {
                        message = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    }
                    await MainActor.run {
                        self.remoteSetupInProgress = false
                        self.appendLocalStatus("Install failed on server — opening plain SSH shell", kind: .warning)
                        self.appendLocalStatus(message, kind: .error)
                    }
                    useAgent = false
                }
            case .plainSSH:
                await MainActor.run {
                    self.appendLocalStatus("Using plain SSH shell (no \(kind.displayName) agent)", kind: .info)
                }
                useAgent = false
            case .cancel:
                try? await client.close()
                throw CancellationError()
            }
        }

        if useAgent, kind.usesScreen {
            await MainActor.run {
                self.appendLocalStatus("\(kind.displayName) via GNU screen", kind: .info)
            }
        }

        var startLoginFlow = false
        if useAgent {
            if try await AgentCLIInstaller.isLoggedIn(kind: kind, using: client) {
                await MainActor.run {
                    self.appendLocalStatus("\(kind.displayName) signed in", kind: .success)
                }
            } else {
                await MainActor.run {
                    self.loginAgentKind = kind
                    self.awaitingAgentLogin = true
                    self.appendLocalStatus("\(kind.displayName) not signed in — starting login…", kind: .warning)
                }
                startLoginFlow = true
            }
        }

        let (terminalView, dimensions) = await MainActor.run {
            self.terminalView.layoutIfNeeded()
            return (self.terminalView, self.terminalView.terminalDimensions)
        }
        let cols = max(dimensions.cols, 80)
        let rows = max(dimensions.rows, 24)

        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            // Let the remote shell/agent set raw mode; forcing ECHO caused duplicate
            // line redraws with full-screen TUIs like Cursor Agent.
            terminalModes: .init([:])
        )

        let environment = [
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LANG", value: "en_US.UTF-8"),
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "TERM", value: "xterm-256color")
        ]

        do {
            try await client.withPTY(ptyRequest, environment: environment) { [weak self] inbound, outbound in
                guard let self else { return }
                await MainActor.run {
                    guard generation == self.connectGeneration else { return }
                    self.stdinWriter = outbound
                    self.connectionState = .connected
                    self.restoreScrollbackIfPending()
                    self.appendLocalStatus("PTY attached", kind: .success)
                }

                let bootstrap: String
                if useAgent, startLoginFlow {
                    bootstrap = RemoteBootstrap.agentLoginShellCommand(kind: kind, projectPath: projectPath)
                } else {
                    bootstrap = RemoteBootstrap.shellCommand(
                        projectPath: projectPath,
                        session: session,
                        mode: mode,
                        useCursorAgent: useAgent
                    )
                }
                try await outbound.write(ByteBuffer(string: bootstrap))

                for try await output in inbound {
                    try Task.checkCancellation()
                    guard await MainActor.run(body: { generation == self.connectGeneration }) else {
                        throw CancellationError()
                    }
                    switch output {
                    case .stdout(let buffer), .stderr(let buffer):
                        guard let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes),
                              !bytes.isEmpty else {
                            continue
                        }
                        // Parse off the SSH thread like upstream SwiftTerm SSH sample.
                        terminalView.feed(byteArray: ArraySlice(bytes))
                        let chunk = Data(bytes)
                        Task { @MainActor [weak self] in
                            self?.enqueueScrollback(chunk)
                        }
                    }
                }

                await MainActor.run {
                    guard generation == self.connectGeneration else { return }
                    if case .connected = self.connectionState {
                        self.connectionState = .ended
                    }
                }
            }
        } catch {
            if Self.isBenignCloseError(error) || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    /// Batch scrollback/login parsing on main — one turn per burst, never block SSH reads.
    private func enqueueScrollback(_ data: Data) {
        guard !data.isEmpty else { return }
        pendingScrollback.append(data)
        guard !scrollbackFlushScheduled else { return }
        scrollbackFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushScrollbackBatch()
        }
    }

    private func flushScrollbackBatch() {
        scrollbackFlushScheduled = false
        guard !pendingScrollback.isEmpty else { return }
        let batch = pendingScrollback
        pendingScrollback = Data()
        persistRemoteOutput(batch)
    }

    private func persistRemoteOutput(_ data: Data) {
        ScrollbackStore.shared.append(sessionId: sessionId, data: data)
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        appendToLoginDetectionBuffer(chunk)
    }

    private func appendToLoginDetectionBuffer(_ chunk: String) {
        loginDetectionBuffer += chunk
        trimLoginDetectionBufferIfNeeded()
        scanForLoginCredentials(in: loginDetectionBuffer)
    }

    private func trimLoginDetectionBufferIfNeeded() {
        guard loginDetectionBuffer.count > Self.loginDetectionBufferLimit else { return }
        let lower = loginDetectionBuffer.lowercased()
        if let httpsRange = lower.range(of: "https://", options: .backwards) {
            let keepFrom = loginDetectionBuffer.index(loginDetectionBuffer.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: httpsRange.lowerBound))
            loginDetectionBuffer = String(loginDetectionBuffer[keepFrom...])
        } else {
            loginDetectionBuffer = String(loginDetectionBuffer.suffix(Self.loginDetectionBufferKeep))
        }
        if loginDetectionBuffer.count > Self.loginDetectionBufferLimit {
            loginDetectionBuffer = String(loginDetectionBuffer.suffix(Self.loginDetectionBufferKeep))
        }
    }

    private func scanForLoginCredentials(in output: Data) {
        guard let text = String(data: output, encoding: .utf8) else { return }
        scanForLoginCredentials(in: text)
    }

    private func scanForLoginCredentials(in output: String) {
        let preferredKind = loginAgentKind ?? activeSession?.agentKind
        let activelyLoggingIn = awaitingAgentLogin || loginAgentKind != nil

        if detectedLoginURL == nil {
            if activelyLoggingIn || loginOutputLooksPlausible(output) {
                if let url = LoginURLParser.extract(from: output, preferredKind: preferredKind) {
                    detectedLoginURL = url
                    if loginAgentKind == nil {
                        loginAgentKind = preferredKind
                    }
                }
            }
        }

        if detectedLoginCode == nil {
            let codeKind: AgentKind? = preferredKind == .codex ? .codex : nil
            if activelyLoggingIn || output.lowercased().contains("one-time code") {
                if let code = LoginURLParser.extractDeviceCode(from: output, kind: codeKind) {
                    detectedLoginCode = code
                    if loginAgentKind == nil, preferredKind == .codex {
                        loginAgentKind = .codex
                    }
                }
            }
        }
    }

    private func loginOutputLooksPlausible(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("authenticator")
            || lower.contains("cursor.sh")
            || lower.contains("cursor.com")
            || lower.contains("claude.ai")
            || lower.contains("claude.com")
            || lower.contains("platform.claude.com")
            || lower.contains("anthropic.com")
            || lower.contains("chatgpt.com")
            || lower.contains("openai.com")
            || lower.contains("auth.openai.com")
            || lower.contains("one-time code")
            || lower.contains("accounts.google.com")
            || lower.contains("codeassist.google.com")
            || lower.contains("oauth/authorize")
            || lower.contains("https://")
    }

    private static func isBenignCloseError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let ssh = error as? SSHClientError {
            // Auth failures are never benign.
            if case .allAuthenticationOptionsFailed = ssh { return false }
            if case .unsupportedPasswordAuthentication = ssh { return false }
            if case .unsupportedPrivateKeyAuthentication = ssh { return false }
            // Channel create can fire during teardown races.
            if case .channelCreationFailed = ssh { return true }
        }
        let ns = error as NSError
        // NIOCore.ChannelError alreadyClosed / ioOnClosedChannel / eof, etc.
        if ns.domain.contains("NIO") || ns.domain.contains("Channel") {
            return true
        }
        let text = error.localizedDescription.lowercased()
        if text.contains("channelerror")
            || text.contains("already closed")
            || text.contains("alreadyclosed")
            || text.contains("connection reset")
            || text.contains("socket is not connected")
            || text.contains("broken pipe") {
            return true
        }
        return false
    }
}

private struct ConnectionTimeoutError: LocalizedError {
    var errorDescription: String? {
        "Connection timed out. Check the network, then tap Reconnect."
    }
}

private func withTimeout<T: Sendable>(
    seconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            throw ConnectionTimeoutError()
        }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return result
    }
}

@MainActor
final class TerminalViewAdapter: NSObject, TerminalViewDelegate {
    weak var workspace: TerminalWorkspace?

    func scrolled(source: TerminalView, position: Double) {
        guard let workspace else { return }
        // SwiftTerm's `canScroll` is false on the alternate buffer even when
        // local scrollback is available (keepHistoryOnFullscreen). Never tie
        // UIScrollView scrolling to that flag — it blocked history scrubbing.
        source.isScrollEnabled = true
        source.alwaysBounceVertical = true
        if source.isUserScrolling {
            workspace.isPinnedToBottom = position >= 0.995
            return
        }
        if !workspace.isPinnedToBottom, position >= 0.99 {
            workspace.isPinnedToBottom = true
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // Agent OSC titles (e.g. slash-command redraws) must not drive SwiftUI
        // navigation — rapid updates have crashed UIKitToolbarStrategy on device.
        _ = title
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        workspace?.resizeTerminal(cols: newCols, rows: newRows)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        workspace?.sendBytes(Data(data))
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let string = String(bytes: content, encoding: .utf8) {
            UIPasteboard.general.string = string
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            UIApplication.shared.open(url)
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
