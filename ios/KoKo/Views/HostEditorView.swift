import SwiftUI

struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    @State private var draft: ServerProfile
    @State private var password: String = ""
    @State private var projectLabel = ""
    @State private var projectPath = ""
    let onSave: (ServerProfile) -> Void

    init(server: ServerProfile, onSave: @escaping (ServerProfile) -> Void) {
        _draft = State(initialValue: server)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Name", text: $draft.name)
                    TextField("Address", text: $draft.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $draft.port, format: .number)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $draft.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Authentication") {
                    Picker("Method", selection: $draft.authType) {
                        Text("SSH Key").tag(AuthType.key)
                        Text("Password").tag(AuthType.password)
                    }
                    .pickerStyle(.segmented)

                    if draft.authType == .key {
                        Picker("Key", selection: $draft.keyPairId) {
                            Text("Select…").tag(UUID?.none)
                            ForEach(store.keyPairs) { key in
                                Text(key.label).tag(Optional(key.id))
                            }
                        }
                        if store.keyPairs.isEmpty {
                            Text("Generate an SSH key on the Keys tab first")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        SecureField("SSH Password", text: $password)
                    }
                }

                Section("Projects") {
                    TextField("Label", text: $projectLabel)
                    TextField("Remote path, e.g. /home/user/project", text: $projectPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Add Project") {
                        guard !projectLabel.isEmpty else { return }
                        draft.projects.append(ProjectPath(label: projectLabel, remotePath: projectPath))
                        projectLabel = ""
                        projectPath = ""
                    }
                    ForEach(draft.projects) { project in
                        VStack(alignment: .leading) {
                            Text(project.label)
                            Text(project.remotePath.isEmpty ? "(home)" : project.remotePath)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        draft.projects.remove(atOffsets: offsets)
                    }
                }
            }
            .navigationTitle(draft.name.isEmpty ? String(localized: "New Host") : String(localized: "Edit Host"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        guard !draft.name.isEmpty else { return false }
        return !draft.host.isEmpty && !draft.username.isEmpty &&
            (draft.authType == .password ? !password.isEmpty : draft.keyPairId != nil)
    }

    private func save() {
        if draft.authType == .password, !password.isEmpty {
            try? KeychainService.shared.save(
                data: Data(password.utf8),
                account: KeychainAccount.password.rawValue,
                keyId: draft.id
            )
        }
        onSave(draft)
        dismiss()
    }
}
