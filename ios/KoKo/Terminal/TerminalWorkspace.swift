import Citadel
import Combine
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
    /// Mode / model / changed files of a mirrored Cursor IDE chat.
    @Published private(set) var ideState: IDEChatState?
    /// Structured conversation of a mirrored Cursor IDE chat, ordered by bubble index.
    @Published private(set) var ideMessages: [IDEChatMessage] = []
    /// Messages sent from the phone that Cursor has not stored yet.
    @Published private(set) var idePendingSends: [String] = []
    private var backgroundDisconnectTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var ideExtractor = IDEStateExtractor()
    private var ideChatSynced = false

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
    /// Paired-desktop AI CLI over the Agent PTY channel instead of SSH.
    private var agentPTY: (transport: AgentPTYTransport, id: String)?
    private var dataTunnel: RE2DataTunnel?
    private var desktopChat: DesktopAgentChat?
    private var desktopProfile: PairedDesktop?
    private var hubPhaseObserver: AnyCancellable?
    private var desktopAutoReconnects = 0
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
        desktopChat = nil
        desktopProfile = nil
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

    /// Attach a paired desktop's AI CLI (Cursor / Claude / Codex / Gemini) through the
    /// Agent PTY channel — same editor as SSH, no remote-desktop video.
    func connectDesktopAgent(
        desk: PairedDesktop,
        chat: DesktopAgentChat,
        mode: RemoteBootstrap.LaunchMode = .preferExisting
    ) {
        closeConnection(updateState: .connecting, feedErrors: false)
        intentionalClose = false
        activeSession = nil
        activeServer = nil
        desktopChat = chat
        desktopProfile = desk
        desktopAutoReconnects = 0
        ideExtractor = IDEStateExtractor()
        ideChatSynced = false
        if ideState?.composerId != chat.chatId {
            ideState = nil
            ideMessages = []
            idePendingSends = []
        }
        title = chat.displayTitle
        detectedLoginURL = nil
        detectedLoginCode = nil
        loginAgentKind = nil
        awaitingAgentLogin = false
        loginDetectionBuffer = ""
        clearLocalStatus()
        didWarnInputNotReady = false
        resetScreenForConnect(mode: mode)
        appendLocalStatus("Connecting to \(desk.name)…", kind: .info)
        connectGeneration += 1
        let generation = connectGeneration
        startConnectingWatchdog(generation: generation)

        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runDesktopAgentConnection(desk: desk, chat: chat, mode: mode, generation: generation)
            } catch {
                guard generation == self.connectGeneration, !self.intentionalClose else { return }
                if error is CancellationError { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.closeConnection(updateState: .failed(message), feedErrors: false)
                self.appendLocalStatus(message, kind: .error)
            }
        }
    }

    private func runDesktopAgentConnection(
        desk: PairedDesktop,
        chat: DesktopAgentChat,
        mode: RemoteBootstrap.LaunchMode,
        generation: Int
    ) async throws {
        let hub = DesktopSessionHub.shared
        let hubSession = hub.session
        var tunnel: RE2DataTunnel?
        if hub.usesDataChannel(desk) {
            appendLocalStatus("Opening encrypted data channel (no desktop video)…", kind: .info)
            do {
                tunnel = try await hub.dataTunnel(for: desk)
            } catch RE2Error.channelUnsupported {
            }
        }
        if tunnel == nil, !(try await hub.sharedTunnel(for: desk)) {
            let t = RE2DataTunnel(profile: desk)
            try await t.connect(channel: false)
            tunnel = t
        }
        let transport: AgentPTYTransport
        if let tunnel {
            guard generation == connectGeneration, !intentionalClose else {
                tunnel.shutdown()
                throw CancellationError()
            }
            transport = tunnel
            if !tunnel.isShared {
                // Pre-channel link of our own in the desktop slot: a desktop connect replaces it.
                dataTunnel = tunnel
                watchDesktopTakeover(deviceID: desk.deviceID, generation: generation)
            }
        } else {
            transport = DesktopTunnelPTYTransport(session: hubSession)
        }
        appendLocalStatus("Agent reached via \(transport.label) — attaching \(chat.agentKind.displayName)…", kind: .success)

        terminalView.layoutIfNeeded()
        let dimensions = terminalView.terminalDimensions
        let id = DesktopAgentLaunch.ptySessionID(for: chat)
        let launch = DesktopAgentLaunch.request(
            chat: chat,
            mode: mode,
            cols: max(dimensions.cols, 80),
            rows: max(dimensions.rows, 24)
        )
        // Loader output until its marker is local plumbing, never shown.
        var staging: Data? = Data()
        try await transport.open(
            id: id,
            request: launch.open,
            onReady: {},
            onData: { [weak self] data in
                guard let self, generation == self.connectGeneration else { return }
                var output = data
                if var buffered = staging {
                    buffered.append(data)
                    guard let marker = buffered.range(of: DesktopAgentLaunch.stageReadyMarker) else {
                        staging = buffered
                        return
                    }
                    staging = nil
                    output = buffered.subdata(in: marker.upperBound..<buffered.endIndex)
                    self.restoreScrollbackIfPending()
                    Task { [weak self] in
                        do {
                            try await transport.write(id: id, data: launch.script)
                        } catch {
                            self?.handleDesktopAgentClosed(reason: error.localizedDescription, generation: generation)
                            return
                        }
                        guard let self, generation == self.connectGeneration else { return }
                        self.agentPTY = (transport, id)
                        self.desktopAutoReconnects = 0
                        self.connectionState = .connected
                        self.appendLocalStatus("\(chat.agentKind.displayName) attached on \(desk.name)", kind: .success)
                        self.syncRemoteTerminalSize()
                        if !self.stdinPending.isEmpty { self.startStdinDrainIfNeeded() }
                        if let state = self.ideState { self.applyIDEState(state) }
                    }
                }
                if chat.mirrorsIDEChat {
                    let split = self.ideExtractor.process(output)
                    output = split.output
                    for frame in split.chats { self.applyIDEChat(frame) }
                    if let state = split.states.last { self.applyIDEState(state) }
                }
                guard !output.isEmpty else { return }
                self.terminalView.feed(byteArray: ArraySlice(output))
                self.enqueueScrollback(output)
            },
            onClose: { [weak self] reason in
                self?.handleDesktopAgentClosed(reason: reason, generation: generation)
            }
        )
    }

    /// The desktop chat this workspace is attached to; a new IDE chat gains its id here.
    var currentDesktopChat: DesktopAgentChat? { desktopChat }

    private func applyIDEState(_ state: IDEChatState) {
        ideState = state
        // A chat created from the phone learns its Cursor id from the first state, so
        // reconnects reopen it instead of creating another one.
        if var chat = desktopChat, chat.chatId.isEmpty, !state.composerId.isEmpty {
            chat.chatId = state.composerId
            if !state.name.isEmpty { chat.title = state.name }
            desktopChat = chat
        }
        // A reattached mirror only sends rows that changed; ask for the full history once.
        if state.supportsNativeChat, !ideChatSynced, agentPTY != nil {
            ideChatSynced = true
            sendIDEAction("resync")
        }
    }

    private func applyIDEChat(_ frame: IDEChatFrame) {
        let incoming = frame.messages ?? []
        if frame.reset == true {
            ideChatSynced = true
            ideMessages = incoming.sorted { $0.idx < $1.idx }
        } else if !incoming.isEmpty {
            var byIdx = Dictionary(ideMessages.map { ($0.idx, $0) }, uniquingKeysWith: { _, new in new })
            for message in incoming { byIdx[message.idx] = message }
            ideMessages = byIdx.values.sorted { $0.idx < $1.idx }
        }
        let stored = Set(incoming.filter { $0.role == .user }.compactMap { $0.text.map(Self.squashed) })
        if !stored.isEmpty {
            idePendingSends.removeAll { pending in stored.contains { $0.contains(Self.squashed(pending)) } }
        }
    }

    private static func squashed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func sendIDEAction(_ op: String, id: String? = nil) {
        sendBytes(IDEChatState.actionBytes(op: op, id: id))
    }

    /// Sends a chat message into the Cursor IDE chat on the desktop.
    func sendIDEMessage(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, agentPTY != nil else { return }
        idePendingSends.append(text)
        sendBytes(IDEChatState.actionBytes(["op": "send", "text": text]))
    }

    /// Answers a Cursor questionnaire; the desktop delivers it as the next chat message.
    func answerIDEQuestion(_ toolCallId: String, answers: [IDEChatMessage.Answer]) {
        let payload: [[String: Any]] = answers.map { answer in
            var item: [String: Any] = ["questionId": answer.questionId, "selectedOptionIds": answer.selectedOptionIds]
            if let text = answer.freeformText, !text.isEmpty { item["freeformText"] = text }
            return item
        }
        sendBytes(IDEChatState.actionBytes(["op": "answer", "id": toolCallId, "answers": payload]))
    }

    /// Opening the remote desktop moves the Agent to a new Noise session, which
    /// silently orphans this data tunnel's PTY — reattach through the desktop tunnel.
    private func watchDesktopTakeover(deviceID: String, generation: Int) {
        let hubSession = DesktopSessionHub.shared.session
        hubPhaseObserver = hubSession.$phase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self, generation == self.connectGeneration,
                      phase == .streaming,
                      hubSession.currentPaired?.deviceID == deviceID else { return }
                self.handleDesktopAgentClosed(reason: "tunnel_reset", generation: generation)
            }
    }

    private func handleDesktopAgentClosed(reason: String?, generation: Int) {
        guard generation == connectGeneration, !intentionalClose else { return }
        if reason == "pty_exit" {
            appendLocalStatus("Remote terminal closed", kind: .info)
            closeConnection(updateState: .ended, feedErrors: false)
            return
        }
        let detail = reason ?? "connection lost"
        guard let desk = desktopProfile, let chat = desktopChat, desktopAutoReconnects < 3 else {
            closeConnection(updateState: .failed(detail), feedErrors: false)
            appendLocalStatus(detail, kind: .error)
            return
        }
        desktopAutoReconnects += 1
        appendLocalStatus("Link changed (\(detail)) — reattaching…", kind: .warning)
        closeConnection(updateState: .reconnecting, feedErrors: false)
        let retryGeneration = connectGeneration
        Task { [weak self] in
            // Let the Agent finish its Noise switch before the next OPEN.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, retryGeneration == self.connectGeneration else { return }
            let attempts = self.desktopAutoReconnects
            self.connectDesktopAgent(desk: desk, chat: chat, mode: .preferExisting)
            self.desktopAutoReconnects = attempts
        }
    }

    /// App went to background: keep the link for a grace period so quick trips out
    /// (Settings, Control Center, a reply) do not drop and reattach the session.
    func enterBackground(grace: TimeInterval = 20) {
        guard backgroundDisconnectTask == nil else { return }
        if backgroundTaskID == .invalid {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "koko.terminal.grace") { [weak self] in
                Task { @MainActor [weak self] in self?.finishBackgroundGrace() }
            }
        }
        backgroundDisconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishBackgroundGrace()
        }
    }

    /// Back in foreground: cancel the pending disconnect. The caller then runs its usual
    /// `ensureConnected()`, which reconnects only if the link dropped meanwhile.
    func enterForeground() {
        backgroundDisconnectTask?.cancel()
        backgroundDisconnectTask = nil
        endBackgroundTime()
    }

    private func finishBackgroundGrace() {
        backgroundDisconnectTask?.cancel()
        backgroundDisconnectTask = nil
        if UIApplication.shared.applicationState != .active {
            disconnect()
        }
        endBackgroundTime()
    }

    private func endBackgroundTime() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// Disconnect SSH; the remote agent / screen session keeps running.
    func disconnect() {
        backgroundDisconnectTask?.cancel()
        backgroundDisconnectTask = nil
        pendingScrollbackRestore = false
        closeConnection(updateState: .disconnected, feedErrors: false)
        clearTerminalDisplay()
    }

    /// Close SSH and stop the remote agent or screen session.
    func terminateSession() {
        intentionalClose = true
        connectionState = .ended
        if let chat = desktopChat, let agentPTY {
            let transport = agentPTY.transport
            let killID = agentPTY.id + "-quit"
            Task {
                try? await transport.open(
                    id: killID,
                    request: DesktopAgentLaunch.terminateRequest(chat: chat),
                    onReady: {},
                    onData: { _ in },
                    onClose: { _ in }
                )
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await transport.close(id: killID)
                transport.shutdown()
            }
            self.agentPTY = nil
            dataTunnel = nil
        } else if let activeSession, stdinWriter != nil {
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
        guard stdinWriter != nil || agentPTY != nil else {
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
                if let agentPTY = self.agentPTY {
                    let chunk = self.stdinPending
                    self.stdinPending = Data()
                    try? await agentPTY.transport.write(id: agentPTY.id, data: chunk)
                    continue
                }
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
        if let agentPTY {
            Task { await agentPTY.transport.resize(id: agentPTY.id, cols: cols, rows: rows) }
            return
        }
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

        hubPhaseObserver = nil
        let pty = agentPTY
        let tunnel = dataTunnel
        agentPTY = nil
        dataTunnel = nil
        if pty != nil || tunnel != nil {
            Task {
                if let pty { await pty.transport.close(id: pty.id) }
                tunnel?.shutdown()
            }
        }

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
        let preferredKind = loginAgentKind ?? activeSession?.agentKind ?? desktopChat?.agentKind
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
