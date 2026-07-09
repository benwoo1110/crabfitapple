import SwiftUI

struct AvailabilitySlotPopoverView: View {
    let slot: AvailabilityGridSlot
    let availablePeople: [CrabFitPerson]
    let unavailablePeople: [CrabFitPerson]

    private var totalPeople: Int {
        availablePeople.count + unavailablePeople.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(availablePeople.count) / \(totalPeople) available")
                    .font(.headline)

                Text(slot.detailLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if totalPeople == 0 {
                ContentUnavailableView("No People", systemImage: "person.crop.circle.badge.xmark")
                    .frame(minWidth: 220, minHeight: 140)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(availablePeople) { person in
                        Label(person.name, systemImage: "person.fill")
                            .font(.body)
                    }

                    ForEach(unavailablePeople) { person in
                        Label(person.name, systemImage: "person.slash")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 240, alignment: .leading)
    }
}
