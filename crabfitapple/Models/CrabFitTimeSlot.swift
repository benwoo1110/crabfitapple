import Foundation

struct CrabFitTimeSlot: Equatable, Identifiable, Sendable {
    enum Day: Equatable, Sendable {
        case specific(year: Int, month: Int, day: Int)
        case weekday(Int)
    }

    let rawValue: String
    let hour: Int
    let minute: Int
    let day: Day

    var id: String { rawValue }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }

        let timeText = parts[0]
        guard timeText.count == 4,
              let hour = Int(timeText.prefix(2)),
              let minute = Int(timeText.suffix(2)),
              (0..<24).contains(hour),
              (0..<60).contains(minute) else {
            return nil
        }

        let dayText = parts[1]
        if dayText.count == 8,
           let day = Int(dayText.prefix(2)),
           let month = Int(dayText.dropFirst(2).prefix(2)),
           let year = Int(dayText.suffix(4)),
           Self.isValidDate(year: year, month: month, day: day) {
            self.day = .specific(year: year, month: month, day: day)
        } else if dayText.count == 1,
                  let weekday = Int(dayText),
                  (0...6).contains(weekday) {
            self.day = .weekday(weekday)
        } else {
            return nil
        }

        self.rawValue = rawValue
        self.hour = hour
        self.minute = minute
    }

    static func formattedRanges(
        for rawValues: [String],
        durationMinutes: Int,
        timeZoneIdentifier: String
    ) -> [String] {
        guard durationMinutes > 0 else { return rawValues }

        var invalidRawValues: [String] = []
        var specificSlots: [(slot: CrabFitTimeSlot, start: Date)] = []
        var weekdaySlots: [(slot: CrabFitTimeSlot, startMinute: Int)] = []

        for rawValue in rawValues {
            guard let slot = CrabFitTimeSlot(rawValue: rawValue) else {
                invalidRawValues.append(rawValue)
                continue
            }

            if let startDate = slot.utcStartDate {
                specificSlots.append((slot, startDate))
            } else if let startMinute = slot.utcWeekMinute {
                weekdaySlots.append((slot, startMinute))
            }
        }

        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? Self.utcTimeZone
        let specificRanges = formattedSpecificRanges(
            from: specificSlots.sorted { $0.start < $1.start },
            durationMinutes: durationMinutes,
            timeZone: timeZone
        )
        let weekdayRanges = formattedWeekdayRanges(
            from: weekdaySlots.sorted { $0.startMinute < $1.startMinute },
            durationMinutes: durationMinutes,
            timeZone: timeZone
        )
        let invalidRanges = invalidRawValues.map { "Unrecognized time: \($0)" }

        return specificRanges + weekdayRanges + invalidRanges
    }

    static func sortedRawValues(_ rawValues: [String]) -> [String] {
        sortedUniqueRawValues(rawValues)
    }

    static func expandedRawValues(
        for rawValues: [String],
        slotDurationMinutes: Int,
        eventDurationMinutes: Int
    ) -> [String] {
        guard slotDurationMinutes > 0, eventDurationMinutes > 0 else {
            return sortedUniqueRawValues(rawValues)
        }

        let expandedValues = sortedUniqueRawValues(rawValues).flatMap { rawValue in
            CrabFitTimeSlot(rawValue: rawValue)?.expandedRawValues(
                slotDurationMinutes: slotDurationMinutes,
                eventDurationMinutes: eventDurationMinutes
            ) ?? [rawValue]
        }

        return orderedUniqueRawValues(expandedValues)
    }

    private func expandedRawValues(slotDurationMinutes: Int, eventDurationMinutes: Int) -> [String] {
        stride(from: 0, to: eventDurationMinutes, by: slotDurationMinutes).compactMap { offsetMinutes in
            rawValue(addingMinutes: offsetMinutes)
        }
    }

    private func rawValue(addingMinutes offsetMinutes: Int) -> String? {
        switch day {
        case .specific:
            guard let date = utcStartDate?.addingTimeInterval(TimeInterval(offsetMinutes * 60)) else {
                return nil
            }

            return Self.rawDateFormatter().string(from: date)
        case .weekday:
            guard let utcWeekMinute else { return nil }

            let totalMinutes = Self.normalizedWeekMinute(utcWeekMinute + offsetMinutes)
            let weekday = totalMinutes / Self.minutesPerDay
            let minuteOfDay = totalMinutes % Self.minutesPerDay
            let hour = minuteOfDay / 60
            let minute = minuteOfDay % 60

            return String(format: "%02d%02d-%d", hour, minute, weekday)
        }
    }

    private static func sortedUniqueRawValues(_ rawValues: [String]) -> [String] {
        orderedUniqueRawValues(rawValues).sorted { firstRawValue, secondRawValue in
            let firstSortKey = sortKey(for: firstRawValue)
            let secondSortKey = sortKey(for: secondRawValue)

            if firstSortKey.category != secondSortKey.category {
                return firstSortKey.category < secondSortKey.category
            }

            if firstSortKey.value != secondSortKey.value {
                return firstSortKey.value < secondSortKey.value
            }

            return firstRawValue < secondRawValue
        }
    }

    private static func orderedUniqueRawValues(_ rawValues: [String]) -> [String] {
        var seenValues: Set<String> = []

        return rawValues.filter { rawValue in
            seenValues.insert(rawValue).inserted
        }
    }

    private static func sortKey(for rawValue: String) -> (category: Int, value: TimeInterval) {
        guard let slot = CrabFitTimeSlot(rawValue: rawValue) else {
            return (2, .greatestFiniteMagnitude)
        }

        if let date = slot.utcStartDate {
            return (0, date.timeIntervalSince1970)
        }

        if let weekMinute = slot.utcWeekMinute {
            return (1, TimeInterval(weekMinute))
        }

        return (2, .greatestFiniteMagnitude)
    }

    private static func normalizedWeekMinute(_ minute: Int) -> Int {
        let minutesPerWeek = minutesPerDay * 7
        return ((minute % minutesPerWeek) + minutesPerWeek) % minutesPerWeek
    }

    var startDate: Date? {
        switch day {
        case .specific:
            utcStartDate
        case .weekday:
            utcWeekMinute.map { weekMinute in
                Self.weekdayReferenceDate.addingTimeInterval(TimeInterval(weekMinute * 60))
            }
        }
    }

    private var utcStartDate: Date? {
        guard case let .specific(year, month, day) = day else { return nil }

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = Self.utcTimeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute

        return components.date
    }

    private var utcWeekMinute: Int? {
        guard case let .weekday(weekday) = day else { return nil }
        return weekday * Self.minutesPerDay + hour * 60 + minute
    }

    private static func formattedSpecificRanges(
        from slots: [(slot: CrabFitTimeSlot, start: Date)],
        durationMinutes: Int,
        timeZone: TimeZone
    ) -> [String] {
        guard let firstSlot = slots.first else { return [] }

        var formattedRanges: [String] = []
        var rangeStart = firstSlot.start
        var rangeEnd = firstSlot.start.addingTimeInterval(TimeInterval(durationMinutes * 60))

        for slot in slots.dropFirst() {
            let slotEnd = slot.start.addingTimeInterval(TimeInterval(durationMinutes * 60))

            if slot.start <= rangeEnd {
                rangeEnd = max(rangeEnd, slotEnd)
            } else {
                formattedRanges.append(formatSpecificRange(start: rangeStart, end: rangeEnd, timeZone: timeZone))
                rangeStart = slot.start
                rangeEnd = slotEnd
            }
        }

        formattedRanges.append(formatSpecificRange(start: rangeStart, end: rangeEnd, timeZone: timeZone))
        return formattedRanges
    }

    private static func formattedWeekdayRanges(
        from slots: [(slot: CrabFitTimeSlot, startMinute: Int)],
        durationMinutes: Int,
        timeZone: TimeZone
    ) -> [String] {
        guard let firstSlot = slots.first else { return [] }

        var formattedRanges: [String] = []
        var rangeStartMinute = firstSlot.startMinute
        var rangeEndMinute = firstSlot.startMinute + durationMinutes

        for slot in slots.dropFirst() {
            let slotEndMinute = slot.startMinute + durationMinutes

            if slot.startMinute <= rangeEndMinute {
                rangeEndMinute = max(rangeEndMinute, slotEndMinute)
            } else {
                formattedRanges.append(formatWeekdayRange(startMinute: rangeStartMinute, endMinute: rangeEndMinute, timeZone: timeZone))
                rangeStartMinute = slot.startMinute
                rangeEndMinute = slotEndMinute
            }
        }

        formattedRanges.append(formatWeekdayRange(startMinute: rangeStartMinute, endMinute: rangeEndMinute, timeZone: timeZone))
        return formattedRanges
    }

    private static func formatSpecificRange(start: Date, end: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        if calendar.isDate(start, inSameDayAs: end) {
            let dateText = dateFormatter(timeZone: timeZone).string(from: start)
            let startText = timeFormatter(timeZone: timeZone).string(from: start)
            let endText = timeFormatter(timeZone: timeZone).string(from: end)
            return "\(dateText), \(startText) to \(endText)"
        }

        let dateTimeFormatter = dateTimeFormatter(timeZone: timeZone)
        return "\(dateTimeFormatter.string(from: start)) to \(dateTimeFormatter.string(from: end))"
    }

    private static func formatWeekdayRange(startMinute: Int, endMinute: Int, timeZone: TimeZone) -> String {
        let start = weekdayReferenceDate.addingTimeInterval(TimeInterval(startMinute * 60))
        let end = weekdayReferenceDate.addingTimeInterval(TimeInterval(endMinute * 60))
        let weekdayFormatter = weekdayFormatter(timeZone: timeZone)
        let timeFormatter = timeFormatter(timeZone: timeZone)

        let startWeekday = weekdayFormatter.string(from: start)
        let endWeekday = weekdayFormatter.string(from: end)
        let startTime = timeFormatter.string(from: start)
        let endTime = timeFormatter.string(from: end)

        if startWeekday == endWeekday {
            return "\(startWeekday), \(startTime) to \(endTime)"
        }

        return "\(startWeekday), \(startTime) to \(endWeekday), \(endTime)"
    }

    private static func isValidDate(year: Int, month: Int, day: Int) -> Bool {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = utcTimeZone
        components.year = year
        components.month = month
        components.day = day

        guard let date = components.date,
              let normalizedComponents = components.calendar?.dateComponents([.year, .month, .day], from: date) else {
            return false
        }

        return normalizedComponents.year == year && normalizedComponents.month == month && normalizedComponents.day == day
    }

    private static func dateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        formatter.timeZone = timeZone
        return formatter
    }

    private static func timeFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        return formatter
    }

    private static func dateTimeFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, h:mm a"
        formatter.timeZone = timeZone
        return formatter
    }

    private static func weekdayFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        formatter.timeZone = timeZone
        return formatter
    }

    private static func rawDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmm-ddMMyyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utcTimeZone
        return formatter
    }

    private static var weekdayReferenceDate: Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = utcTimeZone
        components.year = 2024
        components.month = 1
        components.day = 7

        return components.date ?? Date(timeIntervalSince1970: 1_704_585_600)
    }

    private static var utcTimeZone: TimeZone {
        TimeZone(identifier: "UTC") ?? .current
    }

    private static let minutesPerDay = 1_440
}
