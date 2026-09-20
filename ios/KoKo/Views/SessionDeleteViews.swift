import SwiftUI

@MainActor
final class SessionDeleteJob: ObservableObject, Identifiable {
    let id = UUID()
    let sessions: [TerminalSession]

    @Published var step: SessionDeleteStep = .connecting
    @Published var currentIndex = 0
    @Published var isFinished = false
    @Published var pendingFingerprint: String?
    @Published var currentSessionTitle = ""

    private var task: Task<Void, Never>?

    init(sessions: [TerminalSession]) {
        self.sessions = sessions
    }

    var progressLabel: String {
        guard sessions.count > 1 else { return currentSessionTitle }
        return String(
            format: String(localized: "Deleting %lld of %lld: %@"),
            Int64(currentIndex + 1),
            Int64(sessions.count),
            currentSessionTitle
        )
    }

    func start(store: AppStore) {
        task?.cancel()
        isFinished = false
        pendingFingerprint = nil
        currentIndex = 0
        step = .connecting
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for (index, session) in self.sessions.enumerated() {
                    try Task.checkCancellation()
                    self.currentIndex = index
                    self.currentSessionTitle = session.displayName
                    self.step = .connecting

                    guard
                        let server = store.server(for: session.serverId),
                        let project = store.project(for: session)
                    else {
                        throw AgentSessionDeleteError.missingHostOrProject
                    }

                    WorkspaceRegistry.shared.prepareForDeletion(sessionId: session.id)

                    try await AgentSessionDelete.deleteOnServer(
                        session: session,
                        server: server,
                        projectPath: project.remotePath,
                        keyPair: store.keyPair(for: server.keyPairId),
                        onStep: { step in
                            if self.pendingFingerprint != nil, step != .connecting {
                                return
                            }
                            self.step = step
                        },
                        onHostKeyUnknown: { fingerprint in
                            Task { @MainActor in
                                self.pendingFingerprint = fingerprint
                                self.step = .connecting
                            }
                        }
                    )

                    self.pendingFingerprint = nil
                    self.step = .removingLocal
                    WorkspaceRegistry.shared.remove(sessionId: session.id)
                    store.deleteSession(session)
                }

                self.pendingFingerprint = nil
                self.step = .done
                self.isFinished = true
            } catch is CancellationError {
                self.pendingFingerprint = nil
                self.step = .failed(String(localized: "Cancelled"))
                self.isFinished = true
            } catch {
                self.pendingFingerprint = nil
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.step = .failed(message)
                self.isFinished = true
            }
        }
    }

    func approveHostKey(store: AppStore) {
        guard let fingerprint = pendingFingerprint else { return }
        guard currentIndex < sessions.count else { return }
        store.saveHostKey(serverId: sessions[currentIndex].serverId, fingerprint: fingerprint)
        pendingFingerprint = nil
        step = .connecting
        HostKeyApprovalGate.shared.approve()
    }

    func rejectHostKey() {
        pendingFingerprint = nil
        HostKeyApprovalGate.shared.reject()
        step = .failed(String(localized: "Host key was rejected"))
        isFinished = true
        task?.cancel()
        task = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        if pendingFingerprint != nil {
            HostKeyApprovalGate.shared.reject()
            pendingFingerprint = nil
        }
        if !isFinished {
            step = .failed(String(localized: "Cancelled"))
            isFinished = true
        }
    }
}

struct SessionDeleteProgressView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @ObservedObject var job: SessionDeleteJob

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let fingerprint = job.pendingFingerprint {
                    hostKeyConfirmContent(fingerprint: fingerprint)
                } else {
                    statusContent
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle(String(localized: "Deleting Session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if job.pendingFingerprint != nil {
                        Button(String(localized: "Reject")) { job.rejectHostKey() }
                    } else if job.isFinished {
                        Button(String(localized: "Done")) { dismiss() }
                    } else {
                        Button(String(localized: "Cancel")) { job.cancel() }
                    }
                }
                if job.pendingFingerprint != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Trust & Continue")) {
                            job.approveHostKey(store: store)
                        }
                    }
                }
            }
            .interactiveDismissDisabled(!job.isFinished)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var statusContent: some View {
        if case .failed = job.step {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
        } else if job.step == .done {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
        } else {
            ProgressView()
                .controlSize(.large)
        }

        Text(job.step.title)
            .font(.headline)
            .multilineTextAlignment(.center)

        if !job.currentSessionTitle.isEmpty {
            Text(job.progressLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }

        if job.sessions.count > 1, !job.isFinished, job.pendingFingerprint == nil {
            ProgressView(value: Double(job.currentIndex), total: Double(job.sessions.count))
                .progressViewStyle(.linear)
        }

        if job.step == .done {
            Text(String(localized: "Session deleted on server and this device."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }

        if let detail = job.step.detailMessage {
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func hostKeyConfirmContent(fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Confirm the server host key fingerprint"))
                .font(.headline)
            Text(fingerprint)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(String(localized: "Trust the host key to continue deleting the remote session."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
