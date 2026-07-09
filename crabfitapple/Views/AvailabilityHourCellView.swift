import SwiftUI

struct AvailabilityHourCellView: View {
    let slots: [AvailabilityGridSlot?]
    let people: [CrabFitPerson]
    let availabilityByPerson: [String: Set<String>]
    let availabilityCountByRawValue: [String: Int]
    let highlightedSlotRawValues: Set<String>
    @Binding var selectedSlot: AvailabilityGridSlot?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(slots.indices, id: \.self) { index in
                if let slot = slots[index] {
                    let availableCount = availabilityCountByRawValue[slot.rawValue, default: 0]

                    Button {
                        selectedSlot = slot
                    } label: {
                        AvailabilityCellView(
                            availableCount: availableCount,
                            totalPeople: people.count,
                            isHighlighted: highlightedSlotRawValues.contains(slot.rawValue)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(slot.detailLabel)
                    .accessibilityValue(accessibilityValue(for: availableCount))
                    .popover(isPresented: popoverBinding(for: slot)) {
                        AvailabilitySlotPopoverView(
                            slot: slot,
                            availablePeople: availablePeople(for: slot),
                            unavailablePeople: unavailablePeople(for: slot)
                        )
                        .presentationCompactAdaptation(.popover)
                    }
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.16))
                        .frame(width: 64, height: 12)
                        .overlay {
                            Rectangle()
                                .stroke(Color.secondary.opacity(0.32), lineWidth: 0.5)
                        }
                        .accessibilityHidden(true)
                }
            }
        }
        .overlay {
            Rectangle()
                .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
        }
    }

    private func availablePeople(for slot: AvailabilityGridSlot) -> [CrabFitPerson] {
        people.filter { person in
            isAvailable(person, for: slot)
        }
    }

    private func unavailablePeople(for slot: AvailabilityGridSlot) -> [CrabFitPerson] {
        people.filter { person in
            !isAvailable(person, for: slot)
        }
    }

    private func isAvailable(_ person: CrabFitPerson, for slot: AvailabilityGridSlot) -> Bool {
        availabilityByPerson[person.id, default: []].contains(slot.rawValue)
    }

    private func popoverBinding(for slot: AvailabilityGridSlot) -> Binding<Bool> {
        Binding {
            selectedSlot == slot
        } set: { isPresented in
            if !isPresented {
                selectedSlot = nil
            }
        }
    }

    private func accessibilityValue(for availableCount: Int) -> String {
        if availableCount == 1 {
            return "1 person available"
        }

        return "\(availableCount) people available"
    }
}
