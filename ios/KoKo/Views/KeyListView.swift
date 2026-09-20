import SwiftUI

struct KeyListView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingGenerator = false
    @State private var errorMessage: String?

    @State private var installKey: SSHKeyPair?
    @State private var showServerPicker = false
    @State private var installJob: PublicKeyInstallJob?
    @State private var keysPendingDelete: [SSHKeyPair] = []
    @State private var showDeleteConfirm = false

    private var sshHosts: [ServerProfile] { store.sshServers }

    var body: some View {
        List {
            if store.keyPairs.isEmpty {
                ContentUnavailableView(
                    "No Keys",
                    systemImage: "key",
                    description: Text("Generate Ed25519 / ECDSA / RSA keys stored in Keychain")
                )
            } else {
                ForEach(store.keyPairs) { key in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(key.label).font(.headline)
                        Text(key.algorithm.displayName).font(.caption).foregroundStyle(.secondary)
                        Text(key.publicKeyOpenSSH)
                            .font(.caption2.monospaced())
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = key.publicKeyOpenSSH
                        } label: {
                            Label("Copy Public Key", systemImage: "doc.on.doc")
                        }
                        if !sshHosts.isEmpty {
                            Button {
                                beginInstall(for: key)
                            } label: {
                                Label("Quick Setup on Server", systemImage: "server.rack")
                            }
                        }
                        // Keep Delete last — add new actions above this divider.
                        Divider()
                        Button(role: .destructive) {
                            keysPendingDelete = [key]
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete Key", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // Do NOT use role: .destructive here — SwiftUI removes the row
                        // before our confirmation sheet runs.
                        Button {
                            keysPendingDelete = [key]
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete Key", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
        }
        .navigationTitle("Keys")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingGenerator = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingGenerator) {
            KeyGeneratorView(defaultLabel: nextDefaultKeyLabel()) { keyPair, privateData in
                do {
                    try store.upsertKeyPair(keyPair, privateKeyData: privateData)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .confirmationDialog(
            String(localized: "Quick Setup on Server"),
            isPresented: $showServerPicker,
            titleVisibility: .visible
        ) {
            ForEach(sshHosts) { server in
                Button(server.name) {
                    if let installKey {
                        startInstall(key: installKey, server: server)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                installKey = nil
            }
        } message: {
            Text(String(localized: "Choose which SSH host should receive this public key."))
        }
        .sheet(isPresented: $showDeleteConfirm, onDismiss: {
            keysPendingDelete = []
        }) {
            KeyDeleteConfirmView(
                keys: keysPendingDelete,
                onConfirm: {
                    keysPendingDelete.forEach(store.deleteKeyPair)
                    keysPendingDelete = []
                    showDeleteConfirm = false
                },
                onCancel: {
                    keysPendingDelete = []
                    showDeleteConfirm = false
                }
            )
        }
        .sheet(item: $installJob) { job in
            PublicKeyInstallProgressView(job: job)
                .environmentObject(store)
        }
        .alert(String(localized: "Error"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func beginInstall(for key: SSHKeyPair) {
        installKey = key
        if sshHosts.count == 1, let server = sshHosts.first {
            startInstall(key: key, server: server)
        } else if sshHosts.count > 1 {
            showServerPicker = true
        }
    }

    private func startInstall(key: SSHKeyPair, server: ServerProfile) {
        let job = PublicKeyInstallJob(key: key, server: server)
        installJob = job
        installKey = nil
        job.start(store: store)
    }

    /// Next unused "KoKo Key N" label.
    private func nextDefaultKeyLabel() -> String {
        let prefix = "KoKo Key"
        var used = Set<Int>()
        for key in store.keyPairs {
            if key.label == prefix {
                used.insert(1)
            } else if key.label.hasPrefix(prefix + " "),
                      let n = Int(key.label.dropFirst(prefix.count + 1).trimmingCharacters(in: .whitespaces)) {
                used.insert(n)
            }
        }
        var n = 1
        while used.contains(n) { n += 1 }
        return "\(prefix) \(n)"
    }
}

struct KeyDeleteConfirmView: View {
    let keys: [SSHKeyPair]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var message: String {
        if keys.count == 1, let key = keys.first {
            return String(
                format: String(localized: "Delete %@ from this device? The private key will be removed from Keychain and cannot be recovered."),
                key.label
            )
        }
        return String(localized: "Delete the selected keys from this device? Private keys will be removed from Keychain and cannot be recovered.")
    }

    var body: some View {
        CountdownDeleteConfirmView(
            title: String(localized: "Delete Key?"),
            message: message,
            confirmLabel: String(localized: "Delete Key"),
            onConfirm: onConfirm,
            onCancel: onCancel
        )
    }
}

@MainActor
final class PublicKeyInstallJob: ObservableObject, Identifiable {
    let id = UUID()
    let key: SSHKeyPair
    let server: ServerProfile

    @Published var step: PublicKeyInstallStep = .connecting
    @Published var isFinished = false
    @Published var pendingFingerprint: String?

    private var task: Task<Void, Never>?

    init(key: SSHKeyPair, server: ServerProfile) {
        self.key = key
        self.server = server
    }

    func start(store: AppStore) {
        task?.cancel()
        isFinished = false
        pendingFingerprint = nil
        step = .connecting
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Prefer latest host profile (password / fingerprint may have changed).
                let liveServer = store.server(for: self.server.id) ?? self.server
                let existingKey = store.keyPair(for: liveServer.keyPairId)
                let installedPublicKey = try await PublicKeyInstaller.install(
                    keyPair: self.key,
                    server: liveServer,
                    existingKeyPair: existingKey,
                    onHostKeyUnknown: { fingerprint in
                        Task { @MainActor in
                            self.pendingFingerprint = fingerprint
                            self.step = .waitingHostKey
                        }
                    },
                    onStep: { step in
                        // Don't clobber waitingHostKey UI until user acts.
                        if self.pendingFingerprint != nil, step != .waitingHostKey {
                            return
                        }
                        self.step = step
                    }
                )
                store.updateKeyPairPublicKey(self.key, publicKeyOpenSSH: installedPublicKey)
                store.switchServerToKeyAuth(serverId: self.server.id, keyPairId: self.key.id)
                self.pendingFingerprint = nil
                self.step = .done
                self.isFinished = true
            } catch is CancellationError {
                self.pendingFingerprint = nil
                self.step = .failed(String(localized: "Cancelled"))
                self.isFinished = true
            } catch {
                self.pendingFingerprint = nil
                self.step = .failed(error.localizedDescription)
                self.isFinished = true
            }
        }
    }

    func approveHostKey(store: AppStore) {
        guard let fingerprint = pendingFingerprint else { return }
        store.saveHostKey(serverId: server.id, fingerprint: fingerprint)
        pendingFingerprint = nil
        step = .authenticating
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

struct PublicKeyInstallProgressView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @ObservedObject var job: PublicKeyInstallJob

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
            .navigationTitle(job.pendingFingerprint == nil ? String(localized: "Install Public Key") : String(localized: "Host Fingerprint"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if job.pendingFingerprint != nil {
                        Button(String(localized: "Reject")) { job.rejectHostKey() }
                    } else if job.isFinished {
                        Button(String(localized: "Done")) { dismiss() }
                    } else {
                        Button(String(localized: "Cancel")) {
                            job.cancel()
                        }
                    }
                }
                if job.pendingFingerprint != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Trust & Connect")) {
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

        Text("\(job.key.label) → \(job.server.name) (\(job.server.username)@\(job.server.host))")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

        if job.step == .done {
            Text(String(localized: "Public key is on the server. This host now uses key login in KoKo; the saved password was removed."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
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
            Text(String(localized: "After you trust it, KoKo will finish installing the public key and switch this host to key login."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct KeyGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var algorithm: SSHKeyAlgorithm = .ed25519
    @State private var errorMessage: String?
    let onGenerate: (SSHKeyPair, Data) -> Void

    init(defaultLabel: String = "KoKo Key 1", onGenerate: @escaping (SSHKeyPair, Data) -> Void) {
        _label = State(initialValue: defaultLabel)
        self.onGenerate = onGenerate
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "Label"), text: $label)
                Picker(String(localized: "Algorithm"), selection: $algorithm) {
                    ForEach(SSHKeyAlgorithm.allCases) { algo in
                        Text(algo.displayName).tag(algo)
                    }
                }
                Text(String(localized: "Private keys stay in Keychain on this device. Add the public key to the server’s authorized_keys."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(String(localized: "Generate Key"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Generate")) {
                        do {
                            let generated = try SSHKeyGenerator.generate(label: label, algorithm: algorithm)
                            let keyPair = SSHKeyPair(label: label, algorithm: algorithm, publicKeyOpenSSH: generated.publicKeyOpenSSH)
                            onGenerate(keyPair, generated.privateKeyData)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}
