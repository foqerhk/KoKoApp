import SwiftTerm
import SwiftUI
import UIKit

struct TerminalContainerView: View {
    @ObservedObject var workspace: TerminalWorkspace
    @State private var adapter = TerminalViewAdapter()
    @State private var statusExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            LocalStatusBanner(workspace: workspace, expanded: $statusExpanded)

            ZStack(alignment: .bottomTrailing) {
                TerminalRepresentable(
                    terminalView: workspace.terminalView,
                    adapter: adapter,
                    workspace: workspace
                )
                if !workspace.isPinnedToBottom {
                    Button {
                        workspace.scrollToBottom()
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .padding(8)
                    }
                    .padding()
                }
            }

            TerminalAccessoryBar(workspace: workspace)
        }
        .onAppear {
            adapter.workspace = workspace
            workspace.terminalView.accessoryClearInputHandler = { [weak workspace] in
                workspace?.clearAgentInputLine()
            }
            workspace.terminalView.terminalDelegate = adapter
            workspace.ensureMetalRenderer(enabled: false)
            focusTerminal(workspace)
        }
        .onChange(of: workspace.connectionState) { _, state in
            if state == .connected {
                focusTerminal(workspace)
            }
        }
    }

    private func focusTerminal(_ workspace: TerminalWorkspace) {
        DispatchQueue.main.async {
            workspace.syncRemoteTerminalSize()
            _ = workspace.terminalView.becomeFirstResponder()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            workspace.syncRemoteTerminalSize()
            _ = workspace.terminalView.becomeFirstResponder()
        }
    }
}

/// Collapsible KoKo-local status strip (never mixed into remote PTY output).
private struct LocalStatusBanner: View {
    @ObservedObject var workspace: TerminalWorkspace
    @Binding var expanded: Bool

    private var latest: LocalStatusEvent? {
        workspace.localStatusEvents.last
    }

    private var hasContent: Bool {
        latest != nil || failedMessage != nil
    }

    private var failedMessage: String? {
        if case .failed(let message) = workspace.connectionState { return message }
        return nil
    }

    var body: some View {
        Group {
            if hasContent {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            expanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)

                            Circle()
                                .fill(color(for: latest?.kind ?? .warning))
                                .frame(width: 6, height: 6)

                            Text(failedMessage ?? latest?.message ?? "")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(SwiftUI.Color.primary.opacity(0.9))
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            if workspace.localStatusEvents.count > 1 {
                                Text("\(workspace.localStatusEvents.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if expanded {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: true) {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    if let failedMessage {
                                        Text(failedMessage)
                                            .font(.system(.caption, design: .rounded))
                                            .foregroundStyle(.orange)
                                            .padding(.leading, 26)
                                    }
                                    ForEach(workspace.localStatusEvents) { event in
                                        HStack(alignment: .top, spacing: 8) {
                                            Circle()
                                                .fill(color(for: event.kind))
                                                .frame(width: 6, height: 6)
                                                .padding(.top, 5)
                                            Text(event.message)
                                                .font(.system(.caption, design: .rounded))
                                                .foregroundStyle(SwiftUI.Color.primary.opacity(0.85))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(.leading, 20)
                                        .id(event.id)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                            }
                            .frame(maxHeight: 120)
                            .onAppear {
                                if let last = workspace.localStatusEvents.last {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                            .onChange(of: workspace.localStatusEvents.count) { _, _ in
                                if let last = workspace.localStatusEvents.last {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                .background(SwiftUI.Color(uiColor: .secondarySystemBackground))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(SwiftUI.Color.primary.opacity(0.08))
                        .frame(height: 1)
                }
            }
        }
    }

    private func color(for kind: LocalStatusEvent.Kind) -> SwiftUI.Color {
        switch kind {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct TerminalRepresentable: UIViewRepresentable {
    let terminalView: TerminalView
    let adapter: TerminalViewAdapter
    @ObservedObject var workspace: TerminalWorkspace

    func makeUIView(context: Context) -> TerminalHostView {
        let host = TerminalHostView(terminalView: terminalView)
        host.onPinchFontScale = { proposed in
            workspace.setTerminalFontSize(proposed)
        }
        configure(host.terminalView)
        return host
    }

    func updateUIView(_ uiView: TerminalHostView, context: Context) {
        configure(uiView.terminalView)
        if abs(uiView.terminalView.font.pointSize - workspace.terminalFontSize) >= 0.5 {
            uiView.terminalView.font = UIFont.monospacedSystemFont(
                ofSize: workspace.terminalFontSize,
                weight: .regular
            )
        }
    }

    private func configure(_ uiView: TerminalView) {
        uiView.terminalDelegate = adapter
        uiView.accessoryClearInputHandler = { [weak workspace] in
            workspace?.clearAgentInputLine()
        }
        uiView.isScrollEnabled = true
        uiView.delaysContentTouches = false
        uiView.canCancelContentTouches = true
        uiView.allowMouseReporting = false
        uiView.keepHistoryOnFullscreen = true
        uiView.respondToDeviceAttributes = true
        uiView.alwaysBounceVertical = true
        uiView.bounces = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {}
}

struct TerminalAccessoryBar: View {
    @ObservedObject var workspace: TerminalWorkspace
    @State private var ctrlPressed = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                keyButton("A−") { workspace.decreaseTerminalFontSize() }
                Text("\(Int(workspace.terminalFontSize))pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34)
                keyButton("A+") { workspace.increaseTerminalFontSize() }

                Divider().frame(height: 20)

                keyButton("Esc") { workspace.sendControlKey(0x1B) }
                keyButton("Tab") { workspace.sendControlKey(0x09) }
                keyButton(ctrlPressed ? "Ctrl ✓" : "Ctrl") { ctrlPressed.toggle() }
                keyButton("Ctrl+C") { workspace.sendControlKey(0x03); ctrlPressed = false }
                keyButton("Ctrl+J") { workspace.sendControlKey(0x0A); ctrlPressed = false }
                keyButton("⇧Tab") { workspace.sendEscapeSequence("\u{1b}[Z") }
                keyButton("PgUp") { workspace.sendEscapeSequence("\u{1b}[5~") }
                keyButton("PgDn") { workspace.sendEscapeSequence("\u{1b}[6~") }
                keyButton("↑") { workspace.sendEscapeSequence("\u{1b}[A") }
                keyButton("↓") { workspace.sendEscapeSequence("\u{1b}[B") }
                keyButton("←") { workspace.sendEscapeSequence("\u{1b}[D") }
                keyButton("→") { workspace.sendEscapeSequence("\u{1b}[C") }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(SwiftUI.Color(uiColor: .secondarySystemBackground))
    }

    private func keyButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(SwiftUI.Color(uiColor: .tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
