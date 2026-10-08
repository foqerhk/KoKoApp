import SwiftUI

/// Tracks 1–4 concurrent terminal slots for iPad / Duo layouts.
@MainActor
final class LargeScreenLayoutState: ObservableObject {
    private static let slotCountDefaultsKey = "koko.largeScreen.slotCount"

    @Published var slotCount: Int
    @Published private(set) var slots: [UUID?] = Array(repeating: nil, count: 4)
    @Published var focusedSlot: Int = 0
    @Published var maximizedSlot: Int?
    @Published var showingSessionPicker = false
    @Published var showingManagement: SidebarSection?

    let maxSlots: Int
    let defaultSlotCount: Int

    init(maxSlots: Int = 4, defaultSlotCount: Int = 1) {
        self.maxSlots = min(max(maxSlots, 1), 4)
        self.defaultSlotCount = min(max(defaultSlotCount, 1), self.maxSlots)
        let saved = UserDefaults.standard.integer(forKey: Self.slotCountDefaultsKey)
        if (1...self.maxSlots).contains(saved) {
            self.slotCount = saved
        } else {
            self.slotCount = self.defaultSlotCount
        }
    }

    var activeSessionIds: [UUID] {
        slots.prefix(slotCount).compactMap { $0 }
    }

    private var firstEmptySlot: Int? {
        slots.prefix(slotCount).firstIndex(where: { $0 == nil })
    }

    /// `@Published` does not fire for in-place `slots[i] = …` — always replace the array.
    private func writeSlots(_ update: (inout [UUID?]) -> Void) {
        var next = slots
        update(&next)
        slots = next
    }

    func setSlotCount(_ count: Int) {
        let clamped = min(max(count, 1), maxSlots)
        slotCount = clamped
        UserDefaults.standard.set(clamped, forKey: Self.slotCountDefaultsKey)
        writeSlots { slots in
            for index in clamped..<slots.count {
                slots[index] = nil
            }
        }
        focusedSlot = min(focusedSlot, max(clamped - 1, 0))
        if let maximizedSlot, maximizedSlot >= clamped {
            self.maximizedSlot = nil
        }
    }

    func assign(sessionId: UUID, to slot: Int? = nil) {
        let target: Int
        if let slot, slot >= 0, slot < slotCount {
            target = slot
        } else if let empty = firstEmptySlot {
            target = empty
        } else {
            target = min(focusedSlot, slotCount - 1)
        }

        // Already in the requested pane — just dismiss the picker.
        if slots[target] == sessionId {
            focusedSlot = target
            showingSessionPicker = false
            return
        }

        // Session open in another pane: move it into the target (switch), don't only focus.
        if let existing = slots.prefix(slotCount).firstIndex(of: sessionId), existing != target {
            writeSlots { slots in
                slots[existing] = nil
                slots[target] = sessionId
            }
            focusedSlot = target
            showingSessionPicker = false
            return
        }

        writeSlots { $0[target] = sessionId }
        focusedSlot = target
        showingSessionPicker = false
    }

    func openSession(_ sessionId: UUID) {
        if activeSessionIds.contains(sessionId) {
            if let index = slots.prefix(slotCount).firstIndex(of: sessionId) {
                focusedSlot = index
            }
            showingSessionPicker = false
            return
        }
        assign(sessionId: sessionId)
    }

    func clearSlot(_ index: Int) {
        guard index >= 0, index < slots.count else { return }
        writeSlots { $0[index] = nil }
    }

    func replaceFocusedSession(with sessionId: UUID) {
        assign(sessionId: sessionId, to: min(focusedSlot, slotCount - 1))
    }

    func sessionId(at index: Int) -> UUID? {
        guard index >= 0, index < slotCount else { return nil }
        return slots[index]
    }

    /// Swap two slot positions (drag pane A onto pane B).
    func moveSession(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, destination >= 0,
              source < slotCount, destination < slotCount else { return }
        let focusedId = sessionId(at: focusedSlot)
        let wasMaximized = maximizedSlot
        writeSlots { $0.swapAt(source, destination) }
        if wasMaximized == source {
            maximizedSlot = destination
        } else if wasMaximized == destination {
            maximizedSlot = source
        }
        if let focusedId, let newIndex = slots.prefix(slotCount).firstIndex(of: focusedId) {
            focusedSlot = newIndex
        }
    }

    /// Reorder slots from the top strip (supports empty slots).
    func moveSlots(fromOffsets: IndexSet, toOffset: Int) {
        let focusedId = sessionId(at: focusedSlot)
        let maximizedId = maximizedSlot.flatMap { sessionId(at: $0) }
        var slice = Array(slots.prefix(slotCount))
        slice.move(fromOffsets: fromOffsets, toOffset: toOffset)
        writeSlots { slots in
            for index in 0..<slotCount {
                slots[index] = slice[index]
            }
        }
        if let focusedId, let newIndex = slots.prefix(slotCount).firstIndex(of: focusedId) {
            focusedSlot = newIndex
        } else {
            focusedSlot = min(focusedSlot, max(slotCount - 1, 0))
        }
        if let maximizedId, let newIndex = slots.prefix(slotCount).firstIndex(of: maximizedId) {
            maximizedSlot = newIndex
        }
    }

    func toggleMaximize(at index: Int) {
        guard index >= 0, index < slotCount else { return }
        if maximizedSlot == index {
            maximizedSlot = nil
        } else {
            maximizedSlot = index
            focusedSlot = index
        }
    }

    var isMaximized: Bool { maximizedSlot != nil }
}
