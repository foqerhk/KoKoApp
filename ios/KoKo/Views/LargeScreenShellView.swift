import SwiftUI
import UIKit
import SwiftTerm

/// Full-screen terminal workspace for iPad / Duo with 1–4 in-window slots and optional new windows.
struct LargeScreenShellView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow

    let maxSlots: Int
    let defaultSlotCount: Int
    let supportsExtraWindows: Bool
    let edgeToEdge: Bool

    @StateObject private var layout: LargeScreenLayoutState
    @ObservedObject private var hinge = DuoHingeMonitor.shared
    @State private var pickerTargetSlot: Int?
    /// Mirrors Safari: Duo floating status capsule hides while the keyboard is up.
    @State private var keyboardVisible = false
    @State private var keyboardOverlap: CGFloat = 0

    init(
        maxSlots: Int = 4,
        defaultSlotCount: Int = 1,
        supportsExtraWindows: Bool = true,
        edgeToEdge: Bool = false
    ) {
        self.maxSlots = maxSlots
        self.defaultSlotCount = defaultSlotCount
        self.supportsExtraWindows = supportsExtraWindows
        self.edgeToEdge = edgeToEdge
        _layout = StateObject(
            wrappedValue: LargeScreenLayoutState(maxSlots: maxSlots, defaultSlotCount: defaultSlotCount)
        )
    }

    var body: some View {
        Group {
            if edgeToEdge {
                edgeToEdgeShell
            } else {
                insetShell
            }
        }
        .environment(\.kokoKeyboardVisible, keyboardVisible)
        .observeKeyboardVisibility($keyboardVisible, overlapHeight: $keyboardOverlap)
        // Duo unfolded (edge-to-edge): hide the floating time/Wi‑Fi capsule for good,
        // not only while the keyboard is up — keeps topChrome ⋯ from fighting it.
        .statusBarHidden(edgeToEdge)
        .sheet(isPresented: $layout.showingSessionPicker) {
            sessionPickerSheet
        }
        .sheet(item: $layout.showingManagement) { section in
            NavigationStack {
                managementView(for: section)
            }
        }
        .sheet(item: $store.hostKeyPrompt) { prompt in
            HostKeyConfirmView(prompt: prompt)
        }
        .onChange(of: store.e2eOpenSessionId) { _, sessionId in
            guard let sessionId else { return }
            layout.openSession(sessionId)
            store.e2eOpenSessionId = nil
        }
        .onAppear {
            if layout.activeSessionIds.isEmpty,
               let first = store.sessions.sorted(by: { ($0.lastConnectedAt ?? $0.createdAt) > ($1.lastConnectedAt ?? $1.createdAt) }).first {
                layout.openSession(first.id)
            }
        }
    }

    private var insetShell: some View {
        ZStack {
            MultiSessionGridView(layout: layout) { slot in
                presentSessionPicker(for: slot)
            }
        }
        .padding(.bottom, keyboardBottomLift)
        .animation(.easeOut(duration: 0.25), value: keyboardOverlap)
        .safeAreaInset(edge: .top, spacing: 0) {
            topChrome
        }
    }

    /// Keyboard avoidance: shrink the shell by the live keyboard overlap.
    /// Inline `inputAccessoryView` is already inside `keyboardOverlap`; the floating
    /// half-fold bar is not, so add its height separately. Non-English IMEs get a
    /// small extra lift — their candidate chrome is often under-reported.
    private var keyboardBottomLift: CGFloat {
        guard keyboardVisible, keyboardOverlap > 1 else { return 0 }
        var lift = keyboardOverlap
        if hinge.prefersFloatingAccessory {
            lift += Self.floatingAccessoryBarHeight
        }
        if !Self.isEnglishInput {
            lift += 8
        }
        return lift
    }

    private static var isEnglishInput: Bool {
        let lang = (FloatingAccessoryCoordinator.shared.terminalView?
            .textInputMode?.primaryLanguage ?? "").lowercased()
        if lang.isEmpty { return true }
        return lang == "en" || lang == "ascii"
            || lang.hasPrefix("en-") || lang.hasPrefix("en_")
    }

    private static var floatingAccessoryBarHeight: CGFloat {
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        if DuoHingeMonitor.shared.prefersFloatingAccessory, !isEnglishInput {
            return phone ? 28 : 34
        }
        return phone ? 40 : 48
    }

    /// Terminals fill the display; top chrome matches Safari/Duo floating capsule height.
    /// In Duo half-fold / flex: session stays on the upper half; lower half is for keyboard + KoKo toolbar.
    /// Top chrome is an overlay so the grid can never push 1–4 / ⋯ off-screen or out of the clip.
    private var edgeToEdgeShell: some View {
        ZStack {
            Color(uiColor: (keyboardVisible || hinge.prefersFloatingAccessory)
                  ? .secondarySystemBackground
                  : .systemBackground)
                .ignoresSafeArea()

            GeometryReader { geo in
                let insets = geo.safeAreaInsets
                // Duo flex often reports a tiny top inset (floating capsule); keep a floor under the notch.
                let topPad = max(insets.top, 20)
                let chromeTotalHeight = topPad + DuoChromeMetrics.barHeight
                // Only real half-fold uses the upper-pane clip; single-screen uses bottom lift.
                let flex = hinge.isHalfFoldLayout
                let bottomLift = keyboardBottomLift
                let usableHeight = max(geo.size.height - (flex ? 0 : bottomLift), chromeTotalHeight + 80)
                let upperHeight: CGFloat = {
                    if flex, hinge.upperContentMaxY > chromeTotalHeight + 80 {
                        return min(hinge.upperContentMaxY, usableHeight)
                    }
                    if flex {
                        return min(max(usableHeight * 0.5 - 6, chromeTotalHeight + 120), usableHeight)
                    }
                    return usableHeight
                }()

                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        MultiSessionGridView(layout: layout) { slot in
                            presentSessionPicker(for: slot)
                        }
                        .padding(.top, chromeTotalHeight)
                        .frame(width: geo.size.width, height: upperHeight, alignment: .top)
                        .clipped()

                        topChromeControls
                            // Always clear the system time/Wi‑Fi capsule — do not shrink
                            // when the keyboard is up, so ⋯ stays put across fold + keyboard.
                            .padding(.leading, insets.chromeLeadingPadding)
                            .padding(.trailing, insets.chromeTrailingPadding)
                            .frame(maxWidth: .infinity)
                            .frame(height: DuoChromeMetrics.barHeight, alignment: .center)
                            .padding(.top, topPad)
                            .frame(width: geo.size.width, height: chromeTotalHeight, alignment: .bottom)
                            .background {
                                Rectangle()
                                    .fill(.ultraThinMaterial)
                            }
                            .zIndex(10)
                    }
                    .frame(width: geo.size.width, height: upperHeight, alignment: .top)

                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width, height: usableHeight, alignment: .top)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            .ignoresSafeArea()
            .animation(.easeOut(duration: 0.25), value: keyboardOverlap)
            .animation(.easeOut(duration: 0.25), value: keyboardVisible)
        }
    }

    @ViewBuilder
    private var restorePaneButton: some View {
        if layout.isMaximized {
            SafariChromeCircleButton {
                if let slot = layout.maximizedSlot {
                    layout.toggleMaximize(at: slot)
                }
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .accessibilityLabel("Restore pane size")
        }
    }

    /// Shared chrome row — slot picker | title · status · session⋯ | management⋯
    /// Left (1–4) and right (⋯) stay pinned; only the center session strip may shrink/empty.
    private var topChromeControls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                restorePaneButton

                slotCountPicker
                    .frame(width: CGFloat(min(maxSlots, 4)) * 44)
                    .frame(height: DuoChromeMetrics.circleButton)
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)

            focusedSessionChrome
                .frame(minWidth: 0, maxWidth: .infinity)
                .layoutPriority(0)

            HStack(spacing: 10) {
                if supportsExtraWindows, let focusedId = layout.sessionId(at: layout.focusedSlot) {
                    SafariChromeCircleButton {
                        openWindow(id: SessionWindowScene.session, value: focusedId)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Window")
                }

                // Always trailing in topChrome (expanded / half-fold / keyboard up or down).
                managementMenu
                ChromeStatusCluster()
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var focusedSessionChrome: some View {
        let slot = layout.focusedSlot
        if let sessionId = layout.sessionId(at: slot),
           let session = store.sessions.first(where: { $0.id == sessionId }) {
            SessionChromeBar(
                workspace: WorkspaceRegistry.shared.workspace(for: sessionId),
                session: session,
                slotIndex: slot,
                slotCount: layout.slotCount,
                isMaximized: layout.maximizedSlot == slot,
                showsSlotHandle: false,
                trailingInset: 0,
                onToggleMaximize: (layout.slotCount > 1 || layout.maximizedSlot != nil)
                    ? { layout.toggleMaximize(at: slot) }
                    : nil,
                onRemoveFromSlot: layout.maximizedSlot == nil
                    ? { layout.clearSlot(slot) }
                    : nil,
                onSwitchSession: {
                    presentSessionPicker(for: slot)
                },
                style: .chrome
            )
            .frame(minWidth: 0, maxWidth: .infinity)
        } else {
            Button {
                presentSessionPicker(for: slot)
            } label: {
                Label("Choose Session", systemImage: "plus.circle")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: DuoChromeMetrics.circleButton)
                    .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
            }
            .buttonStyle(.plain)
        }
    }

    private var topChrome: some View {
        topChromeControls
            .frame(maxWidth: .infinity)
            .frame(height: DuoChromeMetrics.barHeight)
            .background {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea(edges: .horizontal)
            }
    }

    private var slotCountPicker: some View {
        Picker("Layout", selection: Binding(
            get: { layout.slotCount },
            set: { layout.setSlotCount($0) }
        )) {
            ForEach(1...maxSlots, id: \.self) { count in
                Text(slotLabel(count)).tag(count)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var managementMenu: some View {
        Menu {
            ForEach(SidebarSection.allCases) { section in
                Button {
                    layout.showingManagement = section
                } label: {
                    Label(section.title, systemImage: section.icon)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: DuoChromeMetrics.symbolPointSize, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: DuoChromeMetrics.circleButton, height: DuoChromeMetrics.circleButton)
                .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
        }
        .accessibilityLabel("More")
    }

    private var sessionPickerSheet: some View {
        NavigationStack {
            SessionListView(
                onPickSession: { session in
                    let slot = pickerTargetSlot ?? layout.focusedSlot
                    layout.assign(sessionId: session.id, to: slot)
                    pickerTargetSlot = nil
                },
                onOpenInNewWindow: supportsExtraWindows ? { session in
                    openWindow(id: SessionWindowScene.session, value: session.id)
                } : nil,
                highlightedSessionIds: Set(layout.activeSessionIds)
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        layout.showingSessionPicker = false
                        pickerTargetSlot = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func managementView(for section: SidebarSection) -> some View {
        switch section {
        case .hosts:
            HostListView(onPickSession: openSessionFromManagement)
                .navigationTitle("Hosts")
        case .sessions:
            SessionListView(
                onPickSession: openSessionFromManagement,
                onOpenInNewWindow: supportsExtraWindows ? { openWindow(id: SessionWindowScene.session, value: $0.id) } : nil,
                highlightedSessionIds: Set(layout.activeSessionIds)
            )
            .navigationTitle("Sessions")
        case .keys:
            KeyListView()
                .navigationTitle("Keys")
        case .settings:
            SettingsView()
                .navigationTitle("Settings")
        }
    }

    private func presentSessionPicker(for slot: Int) {
        pickerTargetSlot = slot
        // Present after Menu dismisses — otherwise the sheet often never appears.
        DispatchQueue.main.async {
            layout.showingSessionPicker = true
        }
    }

    private func openSessionFromManagement(_ session: TerminalSession) {
        layout.openSession(session.id)
        layout.showingManagement = nil
    }

    private func slotLabel(_ count: Int) -> String {
        switch count {
        case 1: "1"
        case 2: "2"
        case 3: "3"
        default: "4"
        }
    }
}

enum SessionWindowScene {
    static let session = "terminal-session"
}
