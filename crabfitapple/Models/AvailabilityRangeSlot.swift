import Foundation

struct AvailabilityRangeSlot: Equatable, Identifiable, Sendable {
    let rawValue: String
    let startDate: Date
    let endDate: Date
    let startSortValue: TimeInterval
    let endSortValue: TimeInterval
    let startBoundaryID: String
    let endBoundaryID: String
    let usesWeekdayLabel: Bool

    var id: String { rawValue }

    init?(gridSlot: AvailabilityGridSlot, durationMinutes: Int) {
        guard durationMinutes > 0,
              let timeSlot = CrabFitTimeSlot(rawValue: gridSlot.rawValue),
              let startDate = timeSlot.startDate else {
            return nil
        }

        let durationSortOffset: TimeInterval
        switch timeSlot.day {
        case .specific:
            usesWeekdayLabel = false
            durationSortOffset = TimeInterval(durationMinutes * 60)
            startSortValue = gridSlot.daySortValue + TimeInterval(gridSlot.timeID * 60)
        case .weekday:
            usesWeekdayLabel = true
            durationSortOffset = TimeInterval(durationMinutes)
            startSortValue = gridSlot.daySortValue + TimeInterval(gridSlot.timeID)
        }

        rawValue = gridSlot.rawValue
        self.startDate = startDate
        endDate = startDate.addingTimeInterval(TimeInterval(durationMinutes * 60))
        endSortValue = startSortValue + durationSortOffset
        startBoundaryID = AvailabilityRangeBoundary.id(
            for: startSortValue,
            usesWeekdayLabel: usesWeekdayLabel
        )
        endBoundaryID = AvailabilityRangeBoundary.id(
            for: endSortValue,
            usesWeekdayLabel: usesWeekdayLabel
        )
    }

    static func slots(from gridSlots: [AvailabilityGridSlot], durationMinutes: Int) -> [AvailabilityRangeSlot] {
        gridSlots
            .compactMap { AvailabilityRangeSlot(gridSlot: $0, durationMinutes: durationMinutes) }
            .sorted { firstSlot, secondSlot in
                firstSlot.startSortValue < secondSlot.startSortValue
            }
    }
}
