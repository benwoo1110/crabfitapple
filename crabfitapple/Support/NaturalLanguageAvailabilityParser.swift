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
                generating: GeneratedAvailabilityResponse.self,
                options: GenerationOptions(samplingMode: .random(top: 5, seed: 91827397), temperature: 0.5)
            )

            print(response.content.rules)

            return try editRanges(
                from: response.content.rules,
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
        Extract the user's intended availability rules as local date and time data only.
        Do not use or infer any event details. Do not decide whether a date or time is valid for an event.
        Use include for available time and exclude for exception phrases such as except, excluding, but not, unavailable, or not.
        For "every day except Friday 1pm-3pm", return an include everyday rule and then an exclude Friday rule.
        Targets are everyday, weekday, weekend, a named weekday target, or specificDate.
        Return the minimum number of rules needed. Do not expand everyday into weekday, weekend, named weekdays, or specificDate rules.
        Use named weekday targets only for named weekdays. Use specificDate only for explicit or relative calendar dates.
        Resolve relative dates with the provided today value and timezone.
        Times are local 24-hour clock times with hour and minute fields. 3pm is hour 15 minute 0.
        Use 00:00 for start of day and 24:00 for end of day.
        If no time is stated, use 00:00 to 24:00. "After 2pm" means 14:00 to 24:00. "Any day after 3pm" means one everyday rule from 15:00 to 24:00. "Before noon" means 00:00 to 12:00.
        Split overnight ranges into two same-day rules, such as Monday 22:00-24:00 and Tuesday 00:00-02:00.
        Preserve the rule order needed to apply includes and excludes correctly.
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
        from generatedRules: [GeneratedAvailabilityRule],
        rangeSlots: [AvailabilityRangeSlot],
        timeZoneIdentifier: String
    ) throws -> [AvailabilityEditRange] {
        let rules = Self.normalizedRules(from: generatedRules.compactMap(AvailabilityRule.init(generatedRule:)))
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

        var selectedRawValues = Set<String>()

        for rule in rules {
            for slot in rangeSlots where Self.rule(rule, matches: slot, calendar: calendar) {
                switch rule.mode {
                case .include:
                    selectedRawValues.insert(slot.rawValue)
                case .exclude:
                    selectedRawValues.remove(slot.rawValue)
                }
            }
        }

        let selectedSlots = rangeSlots
            .filter { selectedRawValues.contains($0.rawValue) }
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
        matches slot: AvailabilityRangeSlot,
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

private struct AvailabilityRule: Equatable {
    let mode: AvailabilityRuleMode
    let target: AvailabilityRuleTarget
    let startMinute: Int
    let endMinute: Int

    init?(generatedRule: GeneratedAvailabilityRule) {
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

    init?(generatedRule: GeneratedAvailabilityRule) {
        switch generatedRule.target {
        case .everyday:
            self = .everyday
        case .weekday:
            self = .weekdays
        case .weekend:
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
        case .specificDate:
            guard let date = Self.specificDate(from: generatedRule.specificDate) else { return nil }
            self = .specificDate(year: date.year, month: date.month, day: date.day)
        @unknown default:
            return nil
        }
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

    private static func specificDate(from generatedDate: GeneratedSpecificDate?) -> (year: Int, month: Int, day: Int)? {
        guard let generatedDate,
              Self.isValidDate(
                  year: generatedDate.year,
                  month: generatedDate.month,
                  day: generatedDate.day
              ) else {
            return nil
        }

        return (generatedDate.year, generatedDate.month, generatedDate.day)
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
    @Guide(description: "The minimum availability rules needed, in application order. Include broad rules before exclude exceptions.", .maximumCount(12))
    var rules: [GeneratedAvailabilityRule]
}

@Generable
private struct GeneratedAvailabilityRule {
    @Guide(description: "include marks available time; exclude removes exceptions from previously included time.")
    var mode: GeneratedAvailabilityRuleMode

    @Guide(description: "The date/day target for this rule.")
    var target: GeneratedAvailabilityTarget

    @Guide(description: "Required only when target is specificDate. Leave nil otherwise.")
    var specificDate: GeneratedSpecificDate?

    @Guide(description: "Start local clock time. Use 00:00 when no start time is stated.")
    var startTime: GeneratedAvailabilityTime

    @Guide(description: "End local clock time, exclusive. Use 24:00 when no end time is stated.")
    var endTime: GeneratedAvailabilityTime
}

@Generable
private enum GeneratedAvailabilityRuleMode {
    case include
    case exclude
}

@Generable
private enum GeneratedAvailabilityTarget {
    case everyday
    case weekday
    case weekend
    case sunday
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case specificDate
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
