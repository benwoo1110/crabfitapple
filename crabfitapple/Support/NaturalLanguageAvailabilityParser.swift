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
            print(response.content)

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
        Extract only the user's stated date/day/time availability from the Availability request.
        Do not infer intent, and do not add coverage that is not stated.

        Source text and rules:
        Split the full request into source phrases first. Semicolons, "also", and commas usually separate source phrases. A comma inside a date list stays in the same source phrase.
        Comma plus "and" separates source phrases when the text after "and" contains its own date/day target and time, such as "12 to 14 July 2-4pm, and 17 to 19 July morning".
        Generate exactly one positive availability rule for each source phrase that contains date/day target(s) and time.
        Every generated rule must include sourceText copied exactly from the request.
        A sourceText must appear in only one generated rule.
        Put recurring-day source phrases in recurringRules. Put calendar-date source phrases in specificDateRules.
        Do not output a rule unless its sourceText literally supports that rule's targets, dateSpans, and times.
        Never copy dateSpans or timeRanges from one sourceText into another rule.
        Keep "and" in one source phrase when it joins multiple time ranges for the same target.
        This schema represents positive availability only. Do not generate removal or exclusion rules.

        Targets:
        specificDateRules is required for explicit calendar dates, date lists, date ranges, tomorrow, or this/next plus a weekday.
        recurringRules is only for explicit recurring targets: weekends, weekdays, every day, or bare weekday names such as mon, wed, fri, sat, sun, Wednesday, Fridays, Saturday, or Sunday.
        Bare weekday names and abbreviations are recurring targets, case-insensitive. Never resolve bare mon/tue/wed/thu/fri/sat/sun into calendar dates.
        allSevenDays is only for every day, everyday, any day, all days, or daily. "Anytime" is a time phrase, not allSevenDays.
        Normal "weekdays" means Monday through Friday, including Friday. Use mondayToFriday for ordinary weekdays.
        Do not expand allSevenDays, weekdays, or weekends into individual weekdays.
        Do not add Monday/Tuesday/etc unless the request names them.
        If sourceText contains a month name, calendar date, or date range like "12 to 14 July", it belongs in specificDateRules.
        If sourceText is a list of named weekdays sharing one time phrase, put every named weekday in recurringTargets; do not replace them with mondayToFriday.

        Dates:
        Resolve omitted years to the prompt year.
        Date ranges are inclusive and consecutive. Put each range in one dateSpan with startDate and endDate.
        For day ranges with the month after the range, the month applies to every day: "12 to 14 July" means 12 July, 13 July, and 14 July.
        Treat "12 to 14 July", "12-14 July", "July 12 to 14", and "July 12-14" as inclusive date ranges.
        A written date range creates exactly one dateSpan. Do not add overlapping, shifted, or adjacent dateSpans. "13 to 15 July" is exactly 13 July-15 July, not 13 July-15 July plus 15 July-17 July.
        Single dates and date-list items use one-day dateSpans where startDate equals endDate.
        dateSpans come only from date words/numbers, not from clock time ranges or weekday abbreviations. In "17 July 12-3pm", the only dateSpan is 17 July-17 July. In "sun 10-1pm", dateSpans is empty.

        Times:
        Use local 24-hour clock times. Use 00:00 for start of day and 24:00 for end of day.
        No time or anytime means 00:00-24:00 for the stated target only.
        After/from/onwards means start-24:00. Before/until means 00:00-end.
        Hyphenated values with am/pm are clock time ranges, not date ranges or durations. Spaces around hyphens do not change the meaning. "12-3pm" means 12:00-15:00; "1-3pm" means 13:00-15:00; "2-4pm" means 14:00-16:00; "2-5pm" means 14:00-17:00, never 14:00-21:00; "9-11am" means 09:00-11:00; "11- 2pm" means 11:00-14:00.
        When only the end of a time range has am/pm, apply that meridiem to the start too, except 12pm stays 12:00.
        A written start time before a hyphen is the startTime. Never turn "1-3pm" into 00:00-15:00.
        Morning = exactly 00:00-12:00. Afternoon = exactly 12:00-17:00. Evening = exactly 17:00-24:00.
        Never output zero-length time ranges such as 00:00-00:00.
        Multiple time ranges for the same sourceText and target go in one rule's timeRanges array.

        Examples:
        Request: "Weekends mornings, 17 August anytime, Wednesday 2pm onwards"
        recurringRules:
        - sourceText "Weekends mornings", recurringTargets [saturdayAndSunday], timeRanges [00:00-12:00]
        - sourceText "Wednesday 2pm onwards", recurringTargets [wednesday], timeRanges [14:00-24:00]
        specificDateRules:
        - sourceText "17 August anytime", dateSpans [17 August-17 August], timeRanges [00:00-24:00]

        Request: "mon, wed, fridays after 2"
        recurringRules:
        - sourceText "mon, wed, fridays after 2", recurringTargets [monday, wednesday, friday], timeRanges [14:00-24:00]
        specificDateRules: []

        Request: "1-3pm on weekdays"
        recurringRules:
        - sourceText "1-3pm on weekdays", recurringTargets [mondayToFriday], timeRanges [13:00-15:00]
        specificDateRules: []

        Request: "Weekdays 3pm onwards, sat 11- 2pm"
        recurringRules:
        - sourceText "Weekdays 3pm onwards", recurringTargets [mondayToFriday], timeRanges [15:00-24:00]
        - sourceText "sat 11- 2pm", recurringTargets [saturday], timeRanges [11:00-14:00]
        specificDateRules: []

        Request: "Weekdays after 3pm, sun 10-1pm"
        recurringRules:
        - sourceText "Weekdays after 3pm", recurringTargets [mondayToFriday], timeRanges [15:00-24:00]
        - sourceText "sun 10-1pm", recurringTargets [sunday], timeRanges [10:00-13:00]
        specificDateRules: []

        Request: "12, 14, 17 July morning"
        recurringRules: []
        specificDateRules:
        - sourceText "12, 14, 17 July morning", dateSpans [12 July-12 July, 14 July-14 July, 17 July-17 July], timeRanges [00:00-12:00]

        Request: "12 to 16 May 2pm onwards"
        recurringRules: []
        specificDateRules:
        - sourceText "12 to 16 May 2pm onwards", dateSpans [12 May-16 May], timeRanges [14:00-24:00]

        Request: "13 to 15 july 2-5pm, july 17 and 19 anytime"
        recurringRules: []
        specificDateRules:
        - sourceText "13 to 15 july 2-5pm", dateSpans [13 July-15 July], timeRanges [14:00-17:00]
        - sourceText "july 17 and 19 anytime", dateSpans [17 July-17 July, 19 July-19 July], timeRanges [00:00-24:00]

        Request: "Weekends mornings, 17 July 12-3pm, Wed 2pm onwards"
        recurringRules:
        - sourceText "Weekends mornings", recurringTargets [saturdayAndSunday], timeRanges [00:00-12:00]
        - sourceText "Wed 2pm onwards", recurringTargets [wednesday], timeRanges [14:00-24:00]
        specificDateRules:
        - sourceText "17 July 12-3pm", dateSpans [17 July-17 July], timeRanges [12:00-15:00]

        Request: "Sunday 10-2pm and 3pm onwards"
        recurringRules:
        - sourceText "Sunday 10-2pm and 3pm onwards", recurringTargets [sunday], timeRanges [10:00-14:00, 15:00-24:00]
        specificDateRules: []
        """
    }

    private static func promptContext(timeZoneIdentifier: String) -> AvailabilityPromptContext {
        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? Self.utcTimeZone
        let year = yearFormatter(timeZone: timeZone).string(from: Date())

        return AvailabilityPromptContext(
            timeZoneIdentifier: timeZoneIdentifier,
            year: year
        )
    }

    private static func prompt(for request: String, context: AvailabilityPromptContext) -> String {
        """
        Availability request:
        \(request)
        
        \(Self.promptPrefix(for: context))
        """
    }

    private static func promptPrefix(for context: AvailabilityPromptContext) -> String {
        """
        Context:
        - Time zone: \(context.timeZoneIdentifier)
        - Year: \(context.year)
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

        var includedRawValues = Set<String>()

        for rule in rules {
            for slot in rangeSlots where Self.rule(rule, contains: slot, calendar: calendar) {
                includedRawValues.insert(slot.rawValue)
            }
        }

        let selectedSlots = rangeSlots
            .filter { includedRawValues.contains($0.rawValue) }
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
                    existingRule.startMinute == rule.startMinute
                        && existingRule.endMinute == rule.endMinute
                        && existingRule.target.isCoveredByEveryday
                }
                normalizedRules.append(rule)
                continue
            }

            let isCoveredByExistingEverydayRule = rule.target.isCoveredByEveryday
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

    private static func yearFormatter(timeZone: TimeZone) -> DateFormatter {
        formatter(dateFormat: "yyyy", timeZone: timeZone)
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
    let year: String
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
    let target: AvailabilityRuleTarget
    let startMinute: Int
    let endMinute: Int

    init?(
        generatedTarget: GeneratedRecurringAvailabilityTarget,
        timeRange: GeneratedAvailabilityTimeRange
    ) {
        guard let startMinute = timeRange.startTime.minuteAfterMidnight,
              let endMinute = timeRange.endTime.minuteAfterMidnight else {
            return nil
        }

        guard let target = AvailabilityRuleTarget(generatedTarget: generatedTarget),
              startMinute < endMinute else {
            return nil
        }

        self.target = target
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    init?(
        generatedRule: GeneratedSpecificDateAvailabilityRule,
        generatedDate: GeneratedSpecificDate,
        timeRange: GeneratedAvailabilityTimeRange
    ) {
        guard let startMinute = timeRange.startTime.minuteAfterMidnight,
              let endMinute = timeRange.endTime.minuteAfterMidnight,
              let target = AvailabilityRuleTarget(generatedDate: generatedDate),
              startMinute < endMinute else {
            return nil
        }

        self.target = target
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    static func rules(from response: GeneratedAvailabilityResponse) -> [AvailabilityRule] {
        response.recurringRules.flatMap(AvailabilityRule.rules(from:))
            + response.specificDateRules.flatMap(AvailabilityRule.rules(from:))
    }

    private static func rules(from generatedRule: GeneratedRecurringAvailabilityRule) -> [AvailabilityRule] {
        generatedRule.recurringTargets.flatMap { generatedTarget in
            generatedRule.timeRanges.compactMap { timeRange in
                AvailabilityRule(generatedTarget: generatedTarget, timeRange: timeRange)
            }
        }
    }

    private static func rules(from generatedRule: GeneratedSpecificDateAvailabilityRule) -> [AvailabilityRule] {
        generatedRule.specificDates.flatMap { generatedDate in
            generatedRule.timeRanges.compactMap { timeRange in
                AvailabilityRule(
                    generatedRule: generatedRule,
                    generatedDate: generatedDate,
                    timeRange: timeRange
                )
            }
        }
    }

    var isEverydayInclude: Bool {
        target == .everyday
    }
}

private enum AvailabilityRuleTarget: Equatable {
    case everyday
    case weekdays
    case weekend
    case dayOfWeek(Int)
    case specificDate(year: Int, month: Int, day: Int)

    init?(generatedTarget: GeneratedRecurringAvailabilityTarget) {
        switch generatedTarget {
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
    @Guide(description: "Recurring-day availability only: weekends, weekdays, every day, or bare weekday names/abbreviations such as mon, wed, fri, sat, sun, Sunday. Do not put calendar dates or month names here.", .maximumCount(12))
    var recurringRules: [GeneratedRecurringAvailabilityRule]

    @Guide(description: "Calendar-date availability only: explicit dates, date lists, date ranges, month names, tomorrow, or this/next plus a weekday. Every item must have at least one dateSpan.", .maximumCount(12))
    var specificDateRules: [GeneratedSpecificDateAvailabilityRule]
}

@Generable
private struct GeneratedRecurringAvailabilityRule {
    @Guide(description: "Exact substring copied from the request for this recurring-day rule, such as Weekends mornings, Wednesday 2pm onwards, mon, wed, fridays after 2, sat 11- 2pm, or sun 10-1pm.")
    var sourceText: String

    @Guide(description: "Recurring targets stated by sourceText. Use mondayToFriday for ordinary weekdays. Use sunday for sun/Sun/Sunday, saturday for sat/Sat/Saturday, and multiple named weekdays for phrases like mon, wed, fridays after 2. Use allSevenDays only for every day/everyday/any day/all days/daily.", .minimumCount(1), .maximumCount(8))
    var recurringTargets: [GeneratedRecurringAvailabilityTarget]

    @Guide(description: "Local clock time ranges stated by sourceText. Include multiple ranges for phrases like Sunday 10-2pm and 3pm onwards. 1-3pm means 13:00-15:00, never 00:00-15:00. 2-5pm means 14:00-17:00, never 14:00-21:00. Use one 00:00-24:00 range only when no time or anytime is stated.", .minimumCount(1), .maximumCount(8))
    var timeRanges: [GeneratedAvailabilityTimeRange]
}

@Generable
private struct GeneratedSpecificDateAvailabilityRule {
    @Guide(description: "Exact substring copied from the request for this calendar-date rule, such as 17 August anytime, 12 to 16 May 2pm onwards, or july 17 and 19 anytime.")
    var sourceText: String

    @Guide(description: "Resolved date spans supported by this rule's sourceText only. Use one-day spans for single dates and date list items. Use exactly one inclusive span for each written date range, such as 13 July-15 July for 13 to 15 July. Do not copy spans from adjacent source phrases or add overlapping, shifted, or adjacent ranges.", .minimumCount(1), .maximumCount(31))
    var dateSpans: [GeneratedSpecificDateSpan]

    @Guide(description: "Local clock time ranges stated by sourceText. 2-5pm means 14:00-17:00, never 14:00-21:00. Use one 00:00-24:00 range only when no time or anytime is stated.", .minimumCount(1), .maximumCount(8))
    var timeRanges: [GeneratedAvailabilityTimeRange]

    nonisolated var specificDates: [GeneratedSpecificDate] {
        dateSpans.flatMap(\.dates)
    }
}

@Generable(description: "One recurring target stated by a recurringDays source phrase.")
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
private struct GeneratedSpecificDateSpan {
    @Guide(description: "First date in the inclusive span. For a single date, this equals endDate.")
    var startDate: GeneratedSpecificDate

    @Guide(description: "Last date in the inclusive span. For a single date, this equals startDate.")
    var endDate: GeneratedSpecificDate

    nonisolated var dates: [GeneratedSpecificDate] {
        guard let startDateValue = startDate.dateValue,
              let endDateValue = endDate.dateValue,
              startDateValue <= endDateValue else {
            return []
        }

        var dates: [GeneratedSpecificDate] = []
        var currentDate = startDateValue
        while currentDate <= endDateValue, dates.count < 31 {
            let components = Self.calendar.dateComponents([.year, .month, .day], from: currentDate)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                break
            }

            dates.append(GeneratedSpecificDate(year: year, month: month, day: day))

            guard let nextDate = Self.calendar.date(byAdding: .day, value: 1, to: currentDate) else {
                break
            }
            currentDate = nextDate
        }

        return dates
    }

    private nonisolated static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }
}

@Generable
private struct GeneratedSpecificDate {
    @Guide(description: "Four digit year in the prompt timezone.", .range(1...9999))
    var year: Int

    @Guide(description: "Month number in the prompt timezone.", .range(1...12))
    var month: Int

    @Guide(description: "Day of month in the prompt timezone.", .range(1...31))
    var day: Int

    nonisolated init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    nonisolated var dateValue: Date? {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC") ?? .current
        components.year = year
        components.month = month
        components.day = day
        return components.date
    }
}

@Generable
private struct GeneratedAvailabilityTimeRange {
    @Guide(description: "Start local clock time. Use 00:00 when no start time is stated. If a start is written before a hyphen, such as 1-3pm, use that start as 13:00. Must be earlier than endTime.")
    var startTime: GeneratedAvailabilityTime

    @Guide(description: "End local clock time, exclusive. Use 24:00 when no end time is stated. Must be later than startTime; never output a zero-length range like 00:00-00:00.")
    var endTime: GeneratedAvailabilityTime
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
