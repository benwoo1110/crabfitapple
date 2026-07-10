import Foundation
import FoundationModels

@MainActor
final class NaturalLanguageAvailabilityParser {
    private lazy var foundationModelAvailabilityParser = FoundationModelAvailabilityParser()

    func prewarm(
        boundaries: [AvailabilityRangeBoundary],
        timeZoneIdentifier: String
    ) {
        guard boundaries.count >= 2 else { return }

        foundationModelAvailabilityParser.prewarm(timeZoneIdentifier: timeZoneIdentifier)
    }

    func ranges(
        from prompt: String,
        boundaries: [AvailabilityRangeBoundary],
        rangeSlots: [AvailabilityRangeSlot],
        timeZoneIdentifier: String
    ) async throws -> [AvailabilityEditRange] {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw NaturalLanguageAvailabilityParserError.emptyPrompt
        }

        guard boundaries.count >= 2, !rangeSlots.isEmpty else {
            throw NaturalLanguageAvailabilityParserError.noAvailableBoundaries
        }

        return try await foundationModelAvailabilityParser.ranges(
            from: trimmedPrompt,
            rangeSlots: rangeSlots,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }
}

enum NaturalLanguageAvailabilityParserError: LocalizedError {
    case emptyPrompt
    case noAvailableBoundaries
    case foundationModelsUnavailable(String)
    case noMatchingRanges
    case invalidGeneratedRanges
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            "Describe when you are available."
        case .noAvailableBoundaries:
            "This event does not have any available time boundaries to match."
        case .foundationModelsUnavailable(let message):
            message
        case .noMatchingRanges:
            "I could not match that description to the event's available time slots."
        case .invalidGeneratedRanges:
            "I matched the description, but the generated time ranges did not line up with this event."
        case .generationFailed(let message):
            "I could not interpret that availability: \(message)"
        }
    }
}

@MainActor
private final class FoundationModelAvailabilityParser {
    private var prewarmedSession: LanguageModelSession?
    private var prewarmedContext: AvailabilityPromptContext?

    func prewarm(timeZoneIdentifier: String) {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return }

        let context = Self.promptContext(timeZoneIdentifier: timeZoneIdentifier)
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        prewarmedSession = session
        prewarmedContext = context
        session.prewarm(promptPrefix: Prompt(Self.promptPrefix(for: context)))
    }

    func ranges(
        from prompt: String,
        rangeSlots: [AvailabilityRangeSlot],
        timeZoneIdentifier: String
    ) async throws -> [AvailabilityEditRange] {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw NaturalLanguageAvailabilityParserError.foundationModelsUnavailable(
                availabilityMessage(for: model.availability)
            )
        }

        let context = Self.promptContext(timeZoneIdentifier: timeZoneIdentifier)
        let session = session(for: model, context: context)
        defer {
            prewarmedSession = nil
            prewarmedContext = nil
        }

        do {
            let response = try await session.respond(
                to: Self.prompt(for: prompt, context: context),
                generating: GeneratedAvailabilityResponse.self
            )
            
            print(prompt)
            print(response.content.recurringRules)
            print(response.content.specificDateRules)

            return try editRanges(
                from: response.content,
                rangeSlots: rangeSlots,
                timeZoneIdentifier: timeZoneIdentifier
            )
        } catch let error as NaturalLanguageAvailabilityParserError {
            throw error
        } catch {
            throw NaturalLanguageAvailabilityParserError.generationFailed(error.localizedDescription)
        }
    }

    private func session(
        for model: SystemLanguageModel,
        context: AvailabilityPromptContext
    ) -> LanguageModelSession {
        if prewarmedContext == context,
           let prewarmedSession {
            self.prewarmedSession = nil
            prewarmedContext = nil
            return prewarmedSession
        }

        return LanguageModelSession(model: model, instructions: Self.instructions)
    }

    private static var instructions: String {
        """
        Extract only the user's stated date/day/time availability. Do not use event details or validate against an event.
        Process each top-level clause separately; clauses may be separated by commas, semicolons, "and", or "also".
        Each rule must come from one clause. A time phrase alone never creates a broad recurring rule.

        Put calendar-date clauses in specificDateRules. Dates include "18 July", "July 18", "tomorrow", "this Friday", and "next Friday"; resolve omitted years to the next occurrence on or after today in the prompt timezone.
        Put repeated-day clauses in recurringRules only when the clause says a recurrence:
        allSevenDays = every day, everyday, any day, all days, daily.
        mondayToFriday = weekdays, workdays, business days, Monday-Friday. Never includes Saturday or Sunday.
        saturdayAndSunday = weekend or weekends.
        Named weekdays = bare weekday names or abbreviations: mon, tue, wed, thu, fri, sat, sun, monday, tuesday, wednesday, thursday, friday, saturday, sunday.
        Bare weekday names and abbreviations are recurringRules, not specificDateRules. Use specificDateRules for weekdays only when the same clause says this/next plus a weekday.

        Use include for available time. Use exclude for exceptions such as except, excluding, but not, unavailable, or not.
        Return the minimum rules needed; do not expand broad targets into narrower targets.

        Times are local 24-hour clock times. Use 00:00 for start of day and 24:00 for end of day.
        No time means 00:00-24:00. After/from/onwards means start-24:00. Before/until means 00:00-end.
        Morning = 00:00-12:00. Afternoon = 12:00-17:00. Evening = 17:00-24:00.
        Split overnight ranges into two same-day rules.

        Example: "18 July 3pm onwards, 19 July only morning, weekdays 1pm onwards"
        => specificDateRules: 18 July 15:00-24:00, 19 July 00:00-12:00; recurringRules: mondayToFriday 13:00-24:00.
        Example: "Weekdays 1pm onwards, sat 2-4pm, sun 1-3pm"
        => recurringRules: mondayToFriday 13:00-24:00, saturday 14:00-16:00, sunday 13:00-15:00; specificDateRules: empty.
        """
    }

    private static func promptContext(timeZoneIdentifier: String) -> AvailabilityPromptContext {
        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? Self.utcTimeZone
        let today = dateFormatter(timeZone: timeZone).string(from: Date())

        return AvailabilityPromptContext(
            timeZoneIdentifier: timeZoneIdentifier,
            today: today
        )
    }

    private static func prompt(for request: String, context: AvailabilityPromptContext) -> String {
        """
        \(Self.promptPrefix(for: context))
        req=\(request)
        """
    }

    private static func promptPrefix(for context: AvailabilityPromptContext) -> String {
        """
        tz=\(context.timeZoneIdentifier)
        today=\(context.today)
        """
    }

    private func editRanges(
        from response: GeneratedAvailabilityResponse,
        rangeSlots: [AvailabilityRangeSlot],
        timeZoneIdentifier: String
    ) throws -> [AvailabilityEditRange] {
        let rules = Self.normalizedRules(from: AvailabilityRule.rules(from: response))
        guard !rules.isEmpty else {
            throw NaturalLanguageAvailabilityParserError.invalidGeneratedRanges
        }

        return try editRanges(
            from: rules,
            rangeSlots: rangeSlots,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    private func editRanges(
        from rules: [AvailabilityRule],
        rangeSlots: [AvailabilityRangeSlot],
        timeZoneIdentifier: String
    ) throws -> [AvailabilityEditRange] {
        let rules = Self.normalizedRules(from: rules)
        guard !rules.isEmpty else {
            throw NaturalLanguageAvailabilityParserError.invalidGeneratedRanges
        }

        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? Self.utcTimeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let includeRules = rules.filter(\.isInclude)
        let excludeRules = rules.filter { !$0.isInclude }
        var includedRawValues = includeRules.isEmpty ? Set(rangeSlots.map(\.rawValue)) : Set<String>()
        var excludedRawValues = Set<String>()

        for rule in includeRules {
            for slot in rangeSlots where Self.rule(rule, contains: slot, calendar: calendar) {
                includedRawValues.insert(slot.rawValue)
            }
        }

        for rule in excludeRules {
            for slot in rangeSlots where Self.rule(rule, overlaps: slot, calendar: calendar) {
                excludedRawValues.insert(slot.rawValue)
            }
        }

        let selectedSlots = rangeSlots
            .filter { includedRawValues.contains($0.rawValue) && !excludedRawValues.contains($0.rawValue) }
            .sorted { firstSlot, secondSlot in
                firstSlot.startSortValue < secondSlot.startSortValue
            }

        let editRanges = Self.editRanges(from: selectedSlots)
        guard !editRanges.isEmpty else {
            throw NaturalLanguageAvailabilityParserError.noMatchingRanges
        }

        return editRanges
    }

    private static func normalizedRules(from rules: [AvailabilityRule]) -> [AvailabilityRule] {
        var normalizedRules: [AvailabilityRule] = []

        for rule in rules {
            guard !normalizedRules.contains(rule) else { continue }

            if rule.isEverydayInclude {
                normalizedRules.removeAll { existingRule in
                    existingRule.isInclude
                        && existingRule.startMinute == rule.startMinute
                        && existingRule.endMinute == rule.endMinute
                        && existingRule.target.isCoveredByEveryday
                }
                normalizedRules.append(rule)
                continue
            }

            let isCoveredByExistingEverydayRule = rule.isInclude
                && rule.target.isCoveredByEveryday
                && normalizedRules.contains { existingRule in
                    existingRule.isEverydayInclude
                        && existingRule.startMinute == rule.startMinute
                        && existingRule.endMinute == rule.endMinute
                }

            if !isCoveredByExistingEverydayRule {
                normalizedRules.append(rule)
            }
        }

        return normalizedRules
    }

    private static func rule(
        _ rule: AvailabilityRule,
        contains slot: AvailabilityRangeSlot,
        calendar: Calendar
    ) -> Bool {
        guard let localSlot = LocalAvailabilitySlot(slot: slot, calendar: calendar),
              rule.target.matches(localSlot),
              localSlot.startMinute >= rule.startMinute,
              localSlot.endMinute <= rule.endMinute else {
            return false
        }

        return true
    }

    private static func rule(
        _ rule: AvailabilityRule,
        overlaps slot: AvailabilityRangeSlot,
        calendar: Calendar
    ) -> Bool {
        guard let localSlot = LocalAvailabilitySlot(slot: slot, calendar: calendar),
              rule.target.matches(localSlot),
              localSlot.startMinute < rule.endMinute,
              localSlot.endMinute > rule.startMinute else {
            return false
        }

        return true
    }

    private static func editRanges(from selectedSlots: [AvailabilityRangeSlot]) -> [AvailabilityEditRange] {
        guard let firstSlot = selectedSlots.first else { return [] }

        var editRanges: [AvailabilityEditRange] = []
        var rangeStartSlot = firstSlot
        var previousSlot = firstSlot

        for slot in selectedSlots.dropFirst() {
            if areSlotsContinuous(previousSlot, slot) {
                previousSlot = slot
            } else {
                editRanges.append(editRange(from: rangeStartSlot, through: previousSlot))
                rangeStartSlot = slot
                previousSlot = slot
            }
        }

        editRanges.append(editRange(from: rangeStartSlot, through: previousSlot))
        return editRanges
    }

    private static func editRange(
        from startSlot: AvailabilityRangeSlot,
        through endSlot: AvailabilityRangeSlot
    ) -> AvailabilityEditRange {
        AvailabilityEditRange(
            startBoundaryID: startSlot.startBoundaryID,
            endBoundaryID: endSlot.endBoundaryID
        )
    }

    private static func areSlotsContinuous(
        _ firstSlot: AvailabilityRangeSlot,
        _ secondSlot: AvailabilityRangeSlot
    ) -> Bool {
        abs(secondSlot.startSortValue - firstSlot.endSortValue) < 0.5
    }

    private func availabilityMessage(for availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            "Apple Intelligence is available."
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                "Apple Intelligence is not enabled on this device."
            case .deviceNotEligible:
                "This device does not support Apple Intelligence."
            case .modelNotReady:
                "The on-device language model is not ready yet. It may still be downloading."
            @unknown default:
                "The on-device language model is unavailable."
            }
        @unknown default:
            "The on-device language model is unavailable."
        }
    }

    private static func dateFormatter(timeZone: TimeZone) -> DateFormatter {
        formatter(dateFormat: "yyyy-MM-dd", timeZone: timeZone)
    }

    private static func formatter(dateFormat: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        return formatter
    }

    private static var utcTimeZone: TimeZone {
        TimeZone(identifier: "UTC") ?? .current
    }
}

private struct AvailabilityPromptContext: Equatable {
    let timeZoneIdentifier: String
    let today: String
}

private struct LocalAvailabilitySlot {
    let usesWeekdayLabel: Bool
    let year: Int
    let month: Int
    let day: Int
    let weekdayIndex: Int
    let startMinute: Int
    let endMinute: Int

    init?(slot: AvailabilityRangeSlot, calendar: Calendar) {
        let startComponents = calendar.dateComponents([.year, .month, .day, .weekday], from: slot.startDate)
        guard let year = startComponents.year,
              let month = startComponents.month,
              let day = startComponents.day,
              let weekday = startComponents.weekday else {
            return nil
        }

        let dayStart = calendar.startOfDay(for: slot.startDate)
        let startMinute = Int((slot.startDate.timeIntervalSince(dayStart) / 60).rounded())
        let endMinute = Int((slot.endDate.timeIntervalSince(dayStart) / 60).rounded())

        guard (0...Self.minutesPerDay).contains(startMinute),
              (0...Self.minutesPerDay).contains(endMinute),
              startMinute < endMinute else {
            return nil
        }

        self.usesWeekdayLabel = slot.usesWeekdayLabel
        self.year = year
        self.month = month
        self.day = day
        weekdayIndex = weekday - 1
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    private static let minutesPerDay = 1_440
}

@MainActor
private struct AvailabilityRule: Equatable {
    let mode: AvailabilityRuleMode
    let target: AvailabilityRuleTarget
    let startMinute: Int
    let endMinute: Int

    init?(generatedRule: GeneratedRecurringAvailabilityRule) {
        guard let startMinute = generatedRule.startTime.minuteAfterMidnight,
              let endMinute = generatedRule.endTime.minuteAfterMidnight else {
            return nil
        }

        guard let mode = AvailabilityRuleMode(generatedMode: generatedRule.mode),
              let target = AvailabilityRuleTarget(generatedRule: generatedRule),
              startMinute < endMinute else {
            return nil
        }

        self.mode = mode
        self.target = target
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    init?(generatedRule: GeneratedSpecificDateAvailabilityRule) {
        guard let startMinute = generatedRule.startTime.minuteAfterMidnight,
              let endMinute = generatedRule.endTime.minuteAfterMidnight,
              let mode = AvailabilityRuleMode(generatedMode: generatedRule.mode),
              let target = AvailabilityRuleTarget(generatedDate: generatedRule.specificDate),
              startMinute < endMinute else {
            return nil
        }

        self.mode = mode
        self.target = target
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    static func rules(from response: GeneratedAvailabilityResponse) -> [AvailabilityRule] {
        response.recurringRules.compactMap(AvailabilityRule.init(generatedRule:))
            + response.specificDateRules.compactMap(AvailabilityRule.init(generatedRule:))
    }

    var isInclude: Bool {
        mode == .include
    }

    var isEverydayInclude: Bool {
        isInclude && target == .everyday
    }
}

private enum AvailabilityRuleMode: Equatable {
    case include
    case exclude

    init?(generatedMode: GeneratedAvailabilityRuleMode) {
        switch generatedMode {
        case .include:
            self = .include
        case .exclude:
            self = .exclude
        @unknown default:
            return nil
        }
    }
}

private enum AvailabilityRuleTarget: Equatable {
    case everyday
    case weekdays
    case weekend
    case dayOfWeek(Int)
    case specificDate(year: Int, month: Int, day: Int)

    init?(generatedRule: GeneratedRecurringAvailabilityRule) {
        switch generatedRule.target {
        case .allSevenDays:
            self = .everyday
        case .mondayToFriday:
            self = .weekdays
        case .saturdayAndSunday:
            self = .weekend
        case .sunday:
            self = .dayOfWeek(0)
        case .monday:
            self = .dayOfWeek(1)
        case .tuesday:
            self = .dayOfWeek(2)
        case .wednesday:
            self = .dayOfWeek(3)
        case .thursday:
            self = .dayOfWeek(4)
        case .friday:
            self = .dayOfWeek(5)
        case .saturday:
            self = .dayOfWeek(6)
        @unknown default:
            return nil
        }
    }

    init?(generatedDate: GeneratedSpecificDate) {
        guard Self.isValidDate(
            year: generatedDate.year,
            month: generatedDate.month,
            day: generatedDate.day
        ) else {
            return nil
        }

        self = .specificDate(
            year: generatedDate.year,
            month: generatedDate.month,
            day: generatedDate.day
        )
    }

    func matches(_ slot: LocalAvailabilitySlot) -> Bool {
        switch self {
        case .everyday:
            true
        case .weekdays:
            (1...5).contains(slot.weekdayIndex)
        case .weekend:
            slot.weekdayIndex == 0 || slot.weekdayIndex == 6
        case .dayOfWeek(let weekdayIndex):
            slot.weekdayIndex == weekdayIndex
        case .specificDate(let year, let month, let day):
            !slot.usesWeekdayLabel && slot.year == year && slot.month == month && slot.day == day
        }
    }

    private static func isValidDate(year: Int, month: Int, day: Int) -> Bool {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC") ?? .current
        components.year = year
        components.month = month
        components.day = day

        guard let date = components.date,
              let normalizedComponents = components.calendar?.dateComponents([.year, .month, .day], from: date) else {
            return false
        }

        return normalizedComponents.year == year
            && normalizedComponents.month == month
            && normalizedComponents.day == day
    }

    var isCoveredByEveryday: Bool {
        switch self {
        case .everyday, .weekdays, .weekend, .dayOfWeek:
            true
        case .specificDate:
            false
        }
    }
}

@Generable
private struct GeneratedAvailabilityResponse {
    @Guide(description: "Repeated-day rules only. Use for weekdays, weekends, and bare weekday names/abbreviations like sat or sun. Never use for date clauses like 18 July, tomorrow, this Friday, or next Friday.", .maximumCount(8))
    var recurringRules: [GeneratedRecurringAvailabilityRule]

    @Guide(description: "Calendar-date rules only, such as 18 July, July 19, tomorrow, this Friday, or next Friday. Return an empty array when there are no date clauses.", .maximumCount(8))
    var specificDateRules: [GeneratedSpecificDateAvailabilityRule]
}

@Generable
private struct GeneratedRecurringAvailabilityRule {
    @Guide(description: "include marks available time; exclude removes exceptions from previously included time.")
    var mode: GeneratedAvailabilityRuleMode

    @Guide(description: "One recurring target. allSevenDays for every/any/all days/daily; mondayToFriday for weekdays/workdays/business days/Mon-Fri; saturdayAndSunday for weekends; saturday for sat; sunday for sun; other named weekday only when named.")
    var target: GeneratedRecurringAvailabilityTarget

    @Guide(description: "Start local clock time. Use 00:00 when no start time is stated.")
    var startTime: GeneratedAvailabilityTime

    @Guide(description: "End local clock time, exclusive. Use 24:00 when no end time is stated.")
    var endTime: GeneratedAvailabilityTime
}

@Generable
private struct GeneratedSpecificDateAvailabilityRule {
    @Guide(description: "include marks available time; exclude removes exceptions from previously included time.")
    var mode: GeneratedAvailabilityRuleMode

    @Guide(description: "The resolved calendar date in the prompt timezone. Required for every specificDateRule.")
    var specificDate: GeneratedSpecificDate

    @Guide(description: "Start local clock time on this date. Use 00:00 when no start time is stated.")
    var startTime: GeneratedAvailabilityTime

    @Guide(description: "End local clock time on this date, exclusive. Use 24:00 when no end time is stated.")
    var endTime: GeneratedAvailabilityTime
}

@Generable
private enum GeneratedAvailabilityRuleMode {
    case include
    case exclude
}

@Generable(description: "The repeated day set targeted by one recurring availability rule.")
private enum GeneratedRecurringAvailabilityTarget {
    case allSevenDays
    case mondayToFriday
    case saturdayAndSunday
    case sunday
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
}

@Generable
private struct GeneratedSpecificDate {
    @Guide(description: "Four digit year in the prompt timezone.", .range(1...9999))
    var year: Int

    @Guide(description: "Month number in the prompt timezone.", .range(1...12))
    var month: Int

    @Guide(description: "Day of month in the prompt timezone.", .range(1...31))
    var day: Int
}

@Generable
private struct GeneratedAvailabilityTime {
    @Guide(description: "24-hour clock hour. Use 24 only for end-of-day 24:00.", .range(0...24))
    var hour: Int

    @Guide(description: "Minute of the hour.", .range(0...59))
    var minute: Int

    var minuteAfterMidnight: Int? {
        guard (0...24).contains(hour), (0..<60).contains(minute) else { return nil }

        if hour == 24 {
            return minute == 0 ? 1_440 : nil
        }

        return hour * 60 + minute
    }
}
