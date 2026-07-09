import SwiftUI

struct EventAvailabilityGridView: View {
    let slots: [AvailabilityGridSlot]
    let people: [CrabFitPerson]
    let availabilityByPerson: [String: Set<String>]
    let availabilityCountByRawValue: [String: Int]
    let highlightedSlotRawValues: Set<String>

    @State private var selectedSlot: AvailabilityGridSlot?

    private let timeColumnWidth: CGFloat = 36
    private let dayColumnWidth: CGFloat = 64
    private let headerHeight: CGFloat = 38
    private let hourRowHeight: CGFloat = 48
    private let segmentOffsets = [0, 15, 30, 45]

    var body: some View {
        let dayIDs = orderedDayIDs(from: slots)
        let hourIDs = orderedHourIDs(from: slots)
        let slotLookup = slotLookup(from: slots)

        if slots.isEmpty {
            Text("No time slots returned by the API.")
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(width: timeColumnWidth, height: headerHeight)

                    ForEach(hourIDs, id: \.self) { hourID in
                        Text(hourLabel(for: hourID))
                            .font(.caption)
                            .bold()
                            .lineLimit(1)
                            .frame(width: timeColumnWidth, height: hourRowHeight, alignment: .topTrailing)
                    }
                }

                ScrollView(.horizontal) {
                    Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow {
                            ForEach(dayIDs, id: \.self) { dayID in
                                let headerLabels = dayHeaderLabels(for: dayID, in: slots)

                                VStack(spacing: 0) {
                                    Text(headerLabels.dayLabel)

                                    if let weekdayLabel = headerLabels.weekdayLabel {
                                        Text(weekdayLabel)
                                    }
                                }
                                .font(.caption)
                                .bold()
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(width: dayColumnWidth, height: headerHeight)
                                .overlay {
                                    Rectangle()
                                        .stroke(Color.secondary.opacity(0.32), lineWidth: 0.5)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(accessibilityDayHeaderLabel(for: headerLabels))
                            }
                        }

                        ForEach(hourIDs, id: \.self) { hourID in
                            GridRow {
                                ForEach(dayIDs, id: \.self) { dayID in
                                    AvailabilityHourCellView(
                                        slots: segmentSlots(
                                            dayID: dayID,
                                            hourID: hourID,
                                            slotLookup: slotLookup
                                        ),
                                        people: people,
                                        availabilityByPerson: availabilityByPerson,
                                        availabilityCountByRawValue: availabilityCountByRawValue,
                                        highlightedSlotRawValues: highlightedSlotRawValues,
                                        selectedSlot: $selectedSlot
                                    )
                                    .frame(width: dayColumnWidth, height: hourRowHeight)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private func orderedDayIDs(from slots: [AvailabilityGridSlot]) -> [String] {
        orderedUniqueValues(slots.map(\.dayID))
    }

    private func orderedHourIDs(from slots: [AvailabilityGridSlot]) -> [Int] {
        orderedUniqueValues(slots.map { hourID(for: $0.timeID) })
    }

    private func slotLookup(from slots: [AvailabilityGridSlot]) -> [String: AvailabilityGridSlot] {
        Dictionary(slots.map { slot in
            (lookupKey(dayID: slot.dayID, timeID: slot.timeID), slot)
        }, uniquingKeysWith: { firstSlot, _ in firstSlot })
    }

    private func segmentSlots(
        dayID: String,
        hourID: Int,
        slotLookup: [String: AvailabilityGridSlot]
    ) -> [AvailabilityGridSlot?] {
        segmentOffsets.map { offset in
            slotLookup[lookupKey(dayID: dayID, timeID: hourID + offset)]
        }
    }

    private func lookupKey(dayID: String, timeID: Int) -> String {
        "\(dayID)-\(timeID)"
    }

    private func dayHeaderLabels(
        for dayID: String,
        in slots: [AvailabilityGridSlot]
    ) -> (dayLabel: String, weekdayLabel: String?) {
        guard let slot = slots.first(where: { $0.dayID == dayID }) else {
            return (dayID, nil)
        }

        return (slot.dayLabel, slot.weekdayLabel)
    }

    private func accessibilityDayHeaderLabel(for headerLabels: (dayLabel: String, weekdayLabel: String?)) -> String {
        guard let weekdayLabel = headerLabels.weekdayLabel else {
            return headerLabels.dayLabel
        }

        return "\(headerLabels.dayLabel), \(weekdayLabel)"
    }

    private func hourID(for timeID: Int) -> Int {
        (timeID / 60) * 60
    }

    private func hourLabel(for hourID: Int) -> String {
        let hour = hourID / 60
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        let period = hour < 12 ? "AM" : "PM"
        return "\(displayHour) \(period)"
    }

    private func orderedUniqueValues<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seenValues: Set<Value> = []

        return values.filter { value in
            seenValues.insert(value).inserted
        }
    }
}
