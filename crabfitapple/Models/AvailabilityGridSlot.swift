import Foundation

struct AvailabilityGridSlot: Equatable, Hashable, Identifiable, Sendable {
    let rawValue: String
    let dayID: String
    let dayLabel: String
    let weekdayLabel: String?
    let daySortValue: TimeInterval
    let timeID: Int
    let timeLabel: String
    let detailLabel: String

    var id: String { rawValue }

    init?(rawValue: String, timeZoneIdentifier: String, durationMinutes: Int) {
        guard let timeSlot = CrabFitTimeSlot(rawValue: rawValue),
              let startDate = timeSlot.startDate else {
            return nil
        }

        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(identifier: "UTC") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: startDate)
        guard let hour = components.hour,
              let minute = components.minute else {
            return nil
        }

        let dayID: String
        let dayLabel: String
        let weekdayLabel: String?
        let daySortValue: TimeInterval

        switch timeSlot.day {
        case .specific:
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day,
                  let dayStart = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
                return nil
            }

            dayID = String(format: "%04d-%02d-%02d", year, month, day)
            dayLabel = Self.dayFormatter(timeZone: timeZone).string(from: startDate)
            weekdayLabel = Self.weekdayFormatter(timeZone: timeZone).string(from: startDate)
            daySortValue = dayStart.timeIntervalSinceReferenceDate
        case .weekday:
            guard let calendarWeekday = components.weekday else { return nil }
            let weekday = calendarWeekday - 1

            dayID = "weekday-\(weekday)"
            dayLabel = Self.weekdayFormatter(timeZone: timeZone).string(from: startDate)
            weekdayLabel = nil
            daySortValue = TimeInterval(weekday * Self.minutesPerDay)
        }

        self.rawValue = rawValue
        self.dayID = dayID
        self.dayLabel = dayLabel
        self.weekdayLabel = weekdayLabel
        self.daySortValue = daySortValue
        self.timeID = hour * 60 + minute
        self.timeLabel = Self.timeFormatter(timeZone: timeZone).string(from: startDate)
        self.detailLabel = CrabFitTimeSlot.formattedRanges(
            for: [rawValue],
            durationMinutes: durationMinutes,
            timeZoneIdentifier: timeZoneIdentifier
        ).first ?? rawValue
    }

    private static func dayFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.timeZone = timeZone
        return formatter
    }

    private static func timeFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = timeZone
        return formatter
    }

    private static func weekdayFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        formatter.timeZone = timeZone
        return formatter
    }

    private static let minutesPerDay = 1_440
}
