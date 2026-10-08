import SwiftUI

/// Session controls shared by in-pane headers and the Duo top chrome center strip.
struct SessionChromeBar: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var workspace: TerminalWorkspace
    let session: TerminalSession
    var slotIndex: Int? = nil
    var slotCount: Int = 1
    var isMaximized: Bool = false
    /// When true, show drag handle + slot number (legacy in-pane header).
    var showsSlotHandle: Bool = false
    var trailingInset: CGFloat = 0
    var onToggleMaximize: (() -> Void)? = nil
    var onRemoveFromSlot: (() -> Void)? = nil
    var onSwitchSession: (() -> Void)? = nil
    var style: Style = .pane

    enum Style {
        /// Fills pane width with secondary background.
        case pane
        /// Sits inside the top chrome; transparent, hugs content.
        case chrome
    }

    @State private var showTerminateConfirm = false
    @State private var showForceNewConfirm = false

    private var liveSession: TerminalSession {
        store.sessions.first(where: { $0.id == session.id }) ?? session
    }

    var body: some View {
        HStack(spacing: style == .chrome ? 6 : 8) {
            if showsSlotHandle, slotCount > 1, let slotIndex {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Drag to reorder")
                Text("#\(slotIndex + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if style == .chrome, slotCount > 1, let slotIndex {
                Text("#\(slotIndex + 1)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
            }

            // Status first, smaller — then title — then session ⋯
            connectionBadge

            Text(liveSession.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(style == .chrome ? 0.75 : 1)
                .layoutPriority(1)

            // Session ⋯ (Reconnect / New / Disconnect / Terminate) glued to title/status.
            terminalMenu
                .layoutPriority(2)

            if style == .pane {
                Spacer(minLength: 0)
            }

            if let onToggleMaximize {
                Button(action: onToggleMaximize) {
                    Image(systemName: isMaximized
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: DuoChromeMetrics.symbolPointSize, weight: .semibold))
                        .frame(width: DuoChromeMetrics.circleButton, height: DuoChromeMetrics.circleButton)
                        .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .layoutPriority(2)
                .accessibilityLabel(isMaximized ? "Restore pane size" : "Maximize pane")
            }

            if let onRemoveFromSlot {
                Button(action: onRemoveFromSlot) {
                    Image(systemName: "xmark")
                        .font(.system(size: DuoChromeMetrics.symbolPointSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: DuoChromeMetrics.circleButton, height: DuoChromeMetrics.circleButton)
                        .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .layoutPriority(2)
                .accessibilityLabel("Close pane")
            }
        }
        .padding(.leading, style == .pane ? 10 : 0)
        .padding(.trailing, style == .pane ? (10 + trailingInset) : 0)
        .frame(minWidth: style == .chrome ? 0 : nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: DuoChromeMetrics.barHeight)
        .background {
            if style == .pane {
                Color(uiColor: .secondarySystemBackground)
            }
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
    }

    private var terminalMenu: some View {
        Menu {
            if let onSwitchSession {
                Button("Switch Session…") {
                    onSwitchSession()
                }
                Divider()
            }
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
            Image(systemName: "ellipsis")
                .font(.system(size: DuoChromeMetrics.symbolPointSize, weight: .semibold))
                .frame(width: DuoChromeMetrics.circleButton, height: DuoChromeMetrics.circleButton)
                .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
        }
        .accessibilityLabel("Session")
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch workspace.connectionState {
        case .connected:
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.green)
                .accessibilityLabel("Connected")
        case .connecting, .reconnecting:
            ProgressView()
                .controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        case .ended:
            Image(systemName: "moon.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .disconnected:
            Image(systemName: "circle")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
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
}
