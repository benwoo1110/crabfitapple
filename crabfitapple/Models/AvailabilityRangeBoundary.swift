import Foundation

struct AvailabilityRangeBoundary: Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let date: Date
    let sortValue: TimeInterval
    let label: String
    let usesWeekdayLabel: Bool

    init(date: Date, sortValue: TimeInterval, timeZoneIdentifier: String, usesWeekdayLabel: Bool) {
        id = Self.id(for: sortValue, usesWeekdayLabel: usesWeekdayLabel)
        self.date = date
        self.sortValue = sortValue
        self.usesWeekdayLabel = usesWeekdayLabel
        label = Self.formattedLabel(
            for: date,
            timeZoneIdentifier: timeZoneIdentifier,
            usesWeekdayLabel: usesWeekdayLabel
        )
    }

    static func boundaries(
        from slots: [AvailabilityGridSlot],
        durationMinutes: Int,
        timeZoneIdentifier: String
    ) -> [AvailabilityRangeBoundary] {
        var boundaryByID: [String: AvailabilityRangeBoundary] = [:]

        for slot in AvailabilityRangeSlot.slots(from: slots, durationMinutes: durationMinutes) {
            let startBoundary = AvailabilityRangeBoundary(
                date: slot.startDate,
                sortValue: slot.startSortValue,
                timeZoneIdentifier: timeZoneIdentifier,
                usesWeekdayLabel: slot.usesWeekdayLabel
            )
            let endBoundary = AvailabilityRangeBoundary(
                date: slot.endDate,
                sortValue: slot.endSortValue,
                timeZoneIdentifier: timeZoneIdentifier,
                usesWeekdayLabel: slot.usesWeekdayLabel
            )

            boundaryByID[startBoundary.id] = startBoundary
            boundaryByID[endBoundary.id] = endBoundary
        }

        return boundaryByID.values.sorted { firstBoundary, secondBoundary in
            firstBoundary.sortValue < secondBoundary.sortValue
        }
    }

    static func id(for sortValue: TimeInterval, usesWeekdayLabel: Bool) -> String {
        let prefix = usesWeekdayLabel ? "weekday" : "specific"
        return "\(prefix)-\(Int((sortValue * 1000).rounded()))"
    }

    private static func formattedLabel(
        for date: Date,
        timeZoneIdentifier: String,
        usesWeekdayLabel: Bool
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = usesWeekdayLabel ? "EEE, h:mm a" : "EEE, d MMM, h:mm a"
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(identifier: "UTC") ?? .current
        return formatter.string(from: date)
    }
}
