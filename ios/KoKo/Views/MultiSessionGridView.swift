import SwiftUI

/// Renders 1–4 terminal panes in a grid; panes can be maximized, focused, and drag-reordered.
struct MultiSessionGridView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var layout: LargeScreenLayoutState
    var onPickSessionForSlot: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let portrait = proxy.size.height > proxy.size.width
            gridBody(portrait: portrait)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private func gridBody(portrait: Bool) -> some View {
        let gap: CGFloat = layout.maximizedSlot != nil || layout.slotCount == 1 ? 0 : 6

        if let maximized = layout.maximizedSlot, maximized >= 0, maximized < layout.slotCount {
            paneView(for: maximized)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch layout.slotCount {
            case 1:
                paneView(for: 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case 2:
                if portrait {
                    VStack(spacing: gap) {
                        paneView(for: 0)
                        paneView(for: 1)
                    }
                } else {
                    HStack(spacing: gap) {
                        paneView(for: 0)
                        paneView(for: 1)
                    }
                }
            case 3:
                // One pane on top, two on the bottom.
                VStack(spacing: gap) {
                    paneView(for: 0)
                        .frame(maxHeight: .infinity)
                    HStack(spacing: gap) {
                        paneView(for: 1)
                        paneView(for: 2)
                    }
                    .frame(maxHeight: .infinity)
                }
            default:
                if portrait {
                    VStack(spacing: gap) {
                        paneView(for: 0)
                            .frame(maxHeight: .infinity)
                        paneView(for: 1)
                            .frame(maxHeight: .infinity)
                        paneView(for: 2)
                            .frame(maxHeight: .infinity)
                        paneView(for: 3)
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: gap) {
                        HStack(spacing: gap) {
                            paneView(for: 0)
                            paneView(for: 1)
                        }
                        .frame(maxHeight: .infinity)
                        HStack(spacing: gap) {
                            paneView(for: 2)
                            paneView(for: 3)
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func paneView(for index: Int) -> some View {
        let isFocused = layout.focusedSlot == index
        let isMaximized = layout.maximizedSlot == index
        let dragEnabled = layout.slotCount > 1 && layout.maximizedSlot == nil

        ZStack {
            if let sessionId = layout.sessionId(at: index),
               let session = store.sessions.first(where: { $0.id == sessionId }) {
                TerminalScreenView(
                    session: session,
                    compactChrome: true,
                    showsCompactHeader: false,
                    slotIndex: index,
                    slotCount: layout.slotCount,
                    showsAccessoryBar: isFocused,
                    acceptsFirstResponder: isFocused,
                    isMaximized: isMaximized,
                    onToggleMaximize: layout.slotCount > 1 || layout.maximizedSlot != nil
                        ? { layout.toggleMaximize(at: index) }
                        : nil,
                    onRemoveFromSlot: layout.maximizedSlot == nil ? { layout.clearSlot(index) } : nil,
                onSwitchSession: { onPickSessionForSlot(index) },
                    compactChromeTrailingInset: 0
                )
            } else {
                emptySlotView(index: index)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: paneCornerRadius, style: .continuous))
        .overlay {
            if layout.slotCount > 1 || layout.maximizedSlot != nil {
                RoundedRectangle(cornerRadius: paneCornerRadius, style: .continuous)
                    .strokeBorder(isFocused ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isFocused ? 2 : 1)
            }
        }
        .opacity(isFocused || layout.slotCount == 1 ? 1 : 0.88)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isFocused else { return }
            layout.focusedSlot = index
        }
        .modifier(SlotDragReorderModifier(
            slotIndex: index,
            enabled: dragEnabled,
            onDrop: { source in layout.moveSession(from: source, to: index) }
        ))
    }

    private func emptySlotView(index: Int) -> some View {
        ContentUnavailableView {
            Label(
                String(format: String(localized: "Empty Slot %lld"), Int64(index + 1)),
                systemImage: "terminal"
            )
        } description: {
            Text("Choose a conversation to run an agent here.")
        } actions: {
            Button("Choose Session") {
                layout.focusedSlot = index
                onPickSessionForSlot(index)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var paneCornerRadius: CGFloat {
        if layout.maximizedSlot != nil { return 0 }
        return layout.slotCount == 1 ? 0 : 8
    }
}
