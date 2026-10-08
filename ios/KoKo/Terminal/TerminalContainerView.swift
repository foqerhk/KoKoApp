import SwiftTerm
import SwiftUI
import UIKit

struct TerminalContainerView: View {
    @ObservedObject var workspace: TerminalWorkspace
    var showsAccessoryBar: Bool = true
    var acceptsFirstResponder: Bool = true
    @ObservedObject private var hinge = DuoHingeMonitor.shared
    @State private var adapter = TerminalViewAdapter()
    @State private var statusExpanded = false

    /// Native `inputAccessoryView` — used when hinge is flat (not half-folded).
    private var useInlineAccessory: Bool {
        showsAccessoryBar && acceptsFirstResponder && !hinge.prefersFloatingAccessory
    }

    /// Window-level bar glued to keyboard top — used in Duo half-fold / flex.
    private var useFloatingAccessory: Bool {
        showsAccessoryBar && acceptsFirstResponder && hinge.prefersFloatingAccessory
    }

    var body: some View {
        VStack(spacing: 0) {
            LocalStatusBanner(workspace: workspace, expanded: $statusExpanded)

            ZStack(alignment: .bottomTrailing) {
                TerminalRepresentable(
                    terminalView: workspace.terminalView,
                    adapter: adapter,
                    workspace: workspace,
                    interactionEnabled: acceptsFirstResponder,
                    showsAccessoryBar: useInlineAccessory
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
        }
        .onAppear {
            adapter.workspace = workspace
            wireAccessoryHandlers(for: workspace)
            workspace.terminalView.terminalDelegate = adapter
            workspace.ensureMetalRenderer(enabled: false)
            workspace.terminalView.isUserInteractionEnabled = acceptsFirstResponder
            workspace.terminalView.isScrollEnabled = acceptsFirstResponder
            refreshAccessoryMode()
            if acceptsFirstResponder {
                focusTerminal(workspace)
            }
        }
        .onDisappear {
            FloatingAccessoryCoordinator.shared.setActive(false, terminal: workspace.terminalView)
        }
        .onChange(of: acceptsFirstResponder) { _, shouldFocus in
            workspace.terminalView.isUserInteractionEnabled = shouldFocus
            workspace.terminalView.isScrollEnabled = shouldFocus
            refreshAccessoryMode()
            if shouldFocus {
                focusTerminal(workspace)
            } else {
                workspace.terminalView.resignFirstResponder()
            }
        }
        .onChange(of: showsAccessoryBar) { _, _ in
            refreshAccessoryMode()
        }
        .onChange(of: hinge.prefersFloatingAccessory) { _, _ in
            refreshAccessoryMode()
            if acceptsFirstResponder {
                workspace.terminalView.reloadInputViews()
            }
        }
        .onChange(of: workspace.connectionState) { _, state in
            if state == .connected, acceptsFirstResponder {
                focusTerminal(workspace)
            }
        }
    }

    func focusTerminal(_ workspace: TerminalWorkspace) {
        guard acceptsFirstResponder else { return }
        refreshAccessoryMode()
        DispatchQueue.main.async {
            workspace.syncRemoteTerminalSize()
            workspace.terminalView.reloadInputViews()
            _ = workspace.terminalView.becomeFirstResponder()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            workspace.syncRemoteTerminalSize()
            workspace.terminalView.reloadInputViews()
            _ = workspace.terminalView.becomeFirstResponder()
        }
    }

    private func refreshAccessoryMode() {
        FloatingAccessoryCoordinator.shared.setActive(
            useFloatingAccessory,
            terminal: workspace.terminalView
        )
        syncKeyboardAccessory(for: workspace, enabled: useInlineAccessory)
    }

    private func wireAccessoryHandlers(for workspace: TerminalWorkspace) {
        let terminalView = workspace.terminalView
        terminalView.accessoryClearInputHandler = { [weak workspace] in
            workspace?.clearAgentInputLine()
        }
        terminalView.accessoryFontSizeStepHandler = { [weak workspace] step in
            guard let workspace else { return }
            if step < 0 {
                workspace.decreaseTerminalFontSize()
            } else {
                workspace.increaseTerminalFontSize()
            }
        }
    }

    /// Use SwiftTerm's native `TerminalAccessory` as `inputAccessoryView` (flat / unfolded).
    private func syncKeyboardAccessory(for workspace: TerminalWorkspace, enabled: Bool) {
        let terminalView = workspace.terminalView
        if enabled {
            if !(terminalView.inputAccessoryView is TerminalAccessory) {
                let short = UIDevice.current.userInterfaceIdiom == .phone
                let height: CGFloat = short ? 36 : 48
                let width = max(terminalView.bounds.width, UIScreen.main.bounds.width)
                let accessory = TerminalAccessory(
                    frame: CGRect(x: 0, y: 0, width: width, height: height),
                    inputViewStyle: .keyboard,
                    container: terminalView
                )
                accessory.sizeToFit()
                terminalView.inputAccessoryView = accessory
            }
            terminalView.inputAssistantItem.leadingBarButtonGroups = []
            terminalView.inputAssistantItem.trailingBarButtonGroups = []
        } else {
            terminalView.inputAccessoryView = nil
        }
        terminalView.reloadInputViews()
    }
}

/// Collapsible KoKo-local status strip (never mixed into remote PTY output).
/// Collapsed: ▸ message … N   Expanded: ▼ + scrollable history.
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
    var interactionEnabled: Bool = true
    var showsAccessoryBar: Bool = true

    func makeUIView(context: Context) -> TerminalHostView {
        let host = TerminalHostView(terminalView: terminalView)
        host.onPinchFontScale = { proposed in
            workspace.setTerminalFontSize(proposed)
        }
        configure(host.terminalView, interactionEnabled: interactionEnabled, showsAccessoryBar: showsAccessoryBar)
        return host
    }

    func updateUIView(_ uiView: TerminalHostView, context: Context) {
        configure(uiView.terminalView, interactionEnabled: interactionEnabled, showsAccessoryBar: showsAccessoryBar)
        if abs(uiView.terminalView.font.pointSize - workspace.terminalFontSize) >= 0.5 {
            uiView.terminalView.font = UIFont.monospacedSystemFont(
                ofSize: workspace.terminalFontSize,
                weight: .regular
            )
        }
    }

    private func configure(_ uiView: TerminalView, interactionEnabled: Bool, showsAccessoryBar: Bool) {
        uiView.terminalDelegate = adapter
        uiView.accessoryClearInputHandler = { [weak workspace] in
            workspace?.clearAgentInputLine()
        }
        uiView.accessoryFontSizeStepHandler = { [weak workspace] step in
            guard let workspace else { return }
            if step < 0 {
                workspace.decreaseTerminalFontSize()
            } else {
                workspace.increaseTerminalFontSize()
            }
        }
        uiView.isUserInteractionEnabled = interactionEnabled
        uiView.isScrollEnabled = interactionEnabled
        if showsAccessoryBar {
            if !(uiView.inputAccessoryView is TerminalAccessory) {
                let short = UIDevice.current.userInterfaceIdiom == .phone
                let height: CGFloat = short ? 36 : 48
                let width = max(uiView.bounds.width, UIScreen.main.bounds.width)
                let accessory = TerminalAccessory(
                    frame: CGRect(x: 0, y: 0, width: width, height: height),
                    inputViewStyle: .keyboard,
                    container: uiView
                )
                accessory.sizeToFit()
                uiView.inputAccessoryView = accessory
            }
            uiView.inputAssistantItem.leadingBarButtonGroups = []
            uiView.inputAssistantItem.trailingBarButtonGroups = []
        } else {
            uiView.inputAccessoryView = nil
        }
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
