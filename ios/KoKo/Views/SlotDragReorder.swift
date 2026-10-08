import SwiftUI

/// Drag a slot index onto another pane or chip to swap session order.
struct SlotDragReorderModifier: ViewModifier {
    let slotIndex: Int
    let enabled: Bool
    let onDrop: (Int) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(String(slotIndex), preview: { Color.clear.frame(width: 1, height: 1) })
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, let source = Int(raw), source != slotIndex else {
                        return false
                    }
                    onDrop(source)
                    return true
                }
        } else {
            content
        }
    }
}

/// Horizontal strip of open slots; drag chips to reorder.
struct SlotOrderStrip: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var layout: LargeScreenLayoutState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<layout.slotCount, id: \.self) { index in
                    slotChip(for: index)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: 360)
    }

    private func slotChip(for index: Int) -> some View {
        let session = layout.sessionId(at: index).flatMap { id in
            store.sessions.first(where: { $0.id == id })
        }
        let isFocused = layout.focusedSlot == index

        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(session?.displayName ?? "Slot \(index + 1)")
                .font(.caption.weight(isFocused ? .semibold : .regular))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isFocused ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        }
        .onTapGesture {
            layout.focusedSlot = index
        }
        .modifier(SlotDragReorderModifier(
            slotIndex: index,
            enabled: true,
            onDrop: { source in layout.moveSession(from: source, to: index) }
        ))
        .accessibilityLabel(session?.displayName ?? "Slot \(index + 1)")
        .accessibilityHint("Drag to reorder sessions")
    }
}
