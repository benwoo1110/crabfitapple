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

        foundationModelAvailabilityParser.prewarm(
            boundaries: boundaries,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    func ranges(
        from prompt: String,
        boundaries: [AvailabilityRangeBoundary],
        timeZoneIdentifier: String
    ) async throws -> [AvailabilityEditRange] {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw NaturalLanguageAvailabilityParserError.emptyPrompt
        }

        guard boundaries.count >= 2 else {
            throw NaturalLanguageAvailabilityParserError.noAvailableBoundaries
        }

        return try await foundationModelAvailabilityParser.ranges(
            from: trimmedPrompt,
            boundaries: boundaries,
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

private final class FoundationModelAvailabilityParser {
    private var prewarmedSession: LanguageModelSession?
    private var prewarmedContext: AvailabilityPromptContext?

    func prewarm(
        boundaries: [AvailabilityRangeBoundary],
        timeZoneIdentifier: String
    ) {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return }

        let context = Self.promptContext(
            boundaries: boundaries,
            timeZoneIdentifier: timeZoneIdentifier
        )
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        prewarmedSession = session
        prewarmedContext = context
        session.prewarm(promptPrefix: Prompt(Self.promptPrefix(for: context)))
    }

    func ranges(
        from prompt: String,
        boundaries: [AvailabilityRangeBoundary],
        timeZoneIdentifier: String
    ) async throws -> [AvailabilityEditRange] {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw NaturalLanguageAvailabilityParserError.foundationModelsUnavailable(
                availabilityMessage(for: model.availability)
            )
        }

        let context = Self.promptContext(
            boundaries: boundaries,
            timeZoneIdentifier: timeZoneIdentifier
        )
        let session = session(for: model, context: context)
        defer {
            prewarmedSession = nil
            prewarmedContext = nil
        }

        do {
            let response = try await session.respond(
                to: Self.prompt(for: prompt, context: context),
                generating: GeneratedAvailabilityResponse.self,
                options: GenerationOptions(samplingMode: .greedy)
            )

            return try validatedRanges(
                from: response.content.ranges,
                boundaries: boundaries,
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
            return prewarmedSession
        }

        return LanguageModelSession(model: model, instructions: Self.instructions)
    }

    private static var instructions: String {
        """
        Convert availability text for one Crab Fit event into day codes and local minutes.
        Use only day codes and time codes from the prompt. Times are minutes after midnight, end exclusive.
        Do not calculate times. Select startMinute and endMinute from the times list.
        Weekdays means Monday-Friday. Weekend means Saturday-Sunday. Named days match the wd field.
        Use first-last only when the request says all day/anytime or has no time.
        "From", "after", or "onwards" with no end means start-last. "Until", "before", or "up to" with no start means first-end.
        If the request has explicit times, you must use those times, not first-last.
        If an exact requested time is not in the times list, omit that range.
        Examples: "Monday 10 to 12 noon" => Monday code, startMinute 600, endMinute 720. "2pm onwards Monday" => Monday code, startMinute 840, endMinute last. "anytime weekend" => Saturday/Sunday codes, first-last.
        Return compact ranges; group multiple dayCodes only when they share the same startMinute and endMinute.
        """
    }

    private static func promptContext(
        boundaries: [AvailabilityRangeBoundary],
        timeZoneIdentifier: String
    ) -> AvailabilityPromptContext {
        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? Self.utcTimeZone
        return AvailabilityPromptContext(
            timeZoneIdentifier: timeZoneIdentifier,
            boundaryMode: Self.eventBoundaryMode(for: boundaries),
            timeSummary: Self.timeSummaryLine(for: boundaries, timeZone: timeZone),
            daySummary: Self.daySummaryLines(for: boundaries, timeZone: timeZone)
        )
    }

    private static func prompt(for request: String, context: AvailabilityPromptContext) -> String {
        """
        \(Self.promptPrefix(for: context))
        req=\(request)
        """
    }

    private static func promptPrefix(for context: AvailabilityPromptContext) -> String {
        return """
        tz=\(context.timeZoneIdentifier)
        mode=\(context.boundaryMode)
        times:
        \(context.timeSummary)
        days:
        \(context.daySummary)
        """
    }

    private static func eventBoundaryMode(for boundaries: [AvailabilityRangeBoundary]) -> String {
        let hasWeekdayBoundaries = boundaries.contains { $0.usesWeekdayLabel }
        let hasSpecificDateBoundaries = boundaries.contains { !$0.usesWeekdayLabel }

        switch (hasWeekdayBoundaries, hasSpecificDateBoundaries) {
        case (true, true):
            return "mixed recurring weekdays and specific dates"
        case (true, false):
            return "recurring weekdays"
        case (false, true):
            return "specific calendar dates"
        case (false, false):
            return "empty"
        }
    }

    private static func daySummaryLines(
        for boundaries: [AvailabilityRangeBoundary],
        timeZone: TimeZone
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var summariesByDayKey: [String: BoundaryPromptDaySummary] = [:]

        for boundary in boundaries {
            let components = calendar.dateComponents([.year, .month, .day, .weekday], from: boundary.date)
            guard let weekday = components.weekday else { continue }

            let weekdayIndex = weekday - 1
            let weekdayText = weekdayFormatter(timeZone: timeZone).string(from: boundary.date)
            let time24 = time24Formatter(timeZone: timeZone).string(from: boundary.date)
            let timeMinute = timeMinute(for: boundary.date, timeZone: timeZone)
            let dayKey: String
            let type: String
            let dateText: String?
            let daySortValue: TimeInterval

            if boundary.usesWeekdayLabel {
                dayKey = "w\(weekdayIndex)"
                type = "recurring-weekday"
                dateText = nil
                daySortValue = TimeInterval(weekdayIndex)
            } else {
                guard let year = components.year,
                      let month = components.month,
                      let day = components.day,
                      let dayStart = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
                    continue
                }

                dayKey = String(format: "d%04d%02d%02d", year, month, day)
                type = "specific-date"
                dateText = dateFormatter(timeZone: timeZone).string(from: boundary.date)
                daySortValue = dayStart.timeIntervalSinceReferenceDate
            }

            if var summary = summariesByDayKey[dayKey] {
                summary.lastMinute = timeMinute
                summary.lastTime24 = time24
                summariesByDayKey[dayKey] = summary
            } else {
                summariesByDayKey[dayKey] = BoundaryPromptDaySummary(
                    dayKey: dayKey,
                    type: type,
                    dateText: dateText,
                    weekdayText: weekdayText,
                    weekdayIndex: weekdayIndex,
                    daySortValue: daySortValue,
                    firstMinute: timeMinute,
                    firstTime24: time24,
                    lastMinute: timeMinute,
                    lastTime24: time24
                )
            }
        }

        let lines = summariesByDayKey.values
            .sorted { $0.daySortValue < $1.daySortValue }
            .map(\.line)

        return lines.isEmpty ? "none" : lines.joined(separator: "\n")
    }

    private static func timeSummaryLine(
        for boundaries: [AvailabilityRangeBoundary],
        timeZone: TimeZone
    ) -> String {
        let timeMinutes = Set(boundaries.map { timeMinute(for: $0.date, timeZone: timeZone) })

        let timeParts = timeMinutes.sorted().map { minute in
            "\(minute)=\(time24Text(for: minute))\(timeAlias(for: minute))"
        }

        return timeParts.isEmpty ? "none" : timeParts.joined(separator: " ")
    }

    private func validatedRanges(
        from generatedRanges: [GeneratedAvailabilityRange],
        boundaries: [AvailabilityRangeBoundary],
        timeZoneIdentifier: String
    ) throws -> [AvailabilityEditRange] {
        let boundaryByID = Dictionary(uniqueKeysWithValues: boundaries.map { ($0.id, $0) })
        let placements = boundaryPlacements(
            for: boundaries,
            timeZoneIdentifier: timeZoneIdentifier
        )
        let boundaryIndexByDayAndMinute = Dictionary(
            uniqueKeysWithValues: placements.values.map { placement in
                ("\(placement.dayKey)|\(placement.timeMinute)", placement.index)
            }
        )
        var seenRangeKeys: Set<String> = []
        var editRanges: [AvailabilityEditRange] = []

        for generatedRange in generatedRanges {
            guard (0...Self.minutesPerDay).contains(generatedRange.startMinute),
                  (0...Self.minutesPerDay).contains(generatedRange.endMinute),
                  generatedRange.startMinute < generatedRange.endMinute else {
                continue
            }

            for rawDayCode in generatedRange.dayCodes {
                let dayCode = rawDayCode.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !dayCode.isEmpty,
                      let startIndex = boundaryIndexByDayAndMinute["\(dayCode)|\(generatedRange.startMinute)"],
                      let endIndex = boundaryIndexByDayAndMinute["\(dayCode)|\(generatedRange.endMinute)"] else {
                    continue
                }

                let startBoundary = boundaries[startIndex]
                let endBoundary = boundaries[endIndex]
                guard startBoundary.sortValue < endBoundary.sortValue else {
                    continue
                }

                let rangeKey = "\(startIndex)|\(endIndex)"
                guard seenRangeKeys.insert(rangeKey).inserted else { continue }

                editRanges.append(AvailabilityEditRange(
                    startBoundaryID: startBoundary.id,
                    endBoundaryID: endBoundary.id
                ))
            }
        }

        guard !editRanges.isEmpty else {
            throw NaturalLanguageAvailabilityParserError.noMatchingRanges
        }

        return editRanges.sorted { firstRange, secondRange in
            guard let firstBoundary = boundaryByID[firstRange.startBoundaryID],
                  let secondBoundary = boundaryByID[secondRange.startBoundaryID] else {
                return false
            }

            return firstBoundary.sortValue < secondBoundary.sortValue
        }
    }

    private func boundaryPlacements(
        for boundaries: [AvailabilityRangeBoundary],
        timeZoneIdentifier: String
    ) -> [Int: BoundaryPlacement] {
        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? Self.utcTimeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        return Dictionary(uniqueKeysWithValues: boundaries.enumerated().compactMap { index, boundary in
            let components = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: boundary.date)
            guard let hour = components.hour,
                  let minute = components.minute else {
                return nil
            }

            let timeMinute = hour * 60 + minute

            if boundary.usesWeekdayLabel {
                guard let weekday = components.weekday else { return nil }
                let weekdayIndex = weekday - 1
                return (
                    index,
                    BoundaryPlacement(
                        index: index,
                        dayKey: "w\(weekdayIndex)",
                        daySortValue: TimeInterval(weekdayIndex),
                        timeMinute: timeMinute
                    )
                )
            }

            guard let year = components.year,
                  let month = components.month,
                  let day = components.day,
                  let dayStart = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
                return nil
            }

            return (
                index,
                BoundaryPlacement(
                    index: index,
                    dayKey: String(format: "d%04d%02d%02d", year, month, day),
                    daySortValue: dayStart.timeIntervalSinceReferenceDate,
                    timeMinute: timeMinute
                )
            )
        })
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

    private static func timeMinute(for date: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private static func time24Text(for minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private static func timeAlias(for minute: Int) -> String {
        switch minute {
        case 0:
            return "/midnight"
        case 720:
            return "/noon"
        default:
            let hour24 = minute / 60
            let minuteOfHour = minute % 60
            let period = hour24 < 12 ? "am" : "pm"
            let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12

            if minuteOfHour == 0 {
                return "/\(hour12)\(period)"
            }

            return String(format: "/%d:%02d%@", hour12, minuteOfHour, period)
        }
    }

    private static func dateFormatter(timeZone: TimeZone) -> DateFormatter {
        formatter(dateFormat: "yyyy-MM-dd", timeZone: timeZone)
    }

    private static func weekdayFormatter(timeZone: TimeZone) -> DateFormatter {
        formatter(dateFormat: "EEEE", timeZone: timeZone)
    }

    private static func time24Formatter(timeZone: TimeZone) -> DateFormatter {
        formatter(dateFormat: "HH:mm", timeZone: timeZone)
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

    private static let minutesPerDay = 1_440
}

private struct BoundaryPlacement {
    let index: Int
    let dayKey: String
    let daySortValue: TimeInterval
    let timeMinute: Int
}

private struct AvailabilityPromptContext: Equatable {
    let timeZoneIdentifier: String
    let boundaryMode: String
    let timeSummary: String
    let daySummary: String
}

private struct BoundaryPromptDaySummary {
    let dayKey: String
    let type: String
    let dateText: String?
    let weekdayText: String
    let weekdayIndex: Int
    let daySortValue: TimeInterval
    let firstMinute: Int
    let firstTime24: String
    var lastMinute: Int
    var lastTime24: String

    var line: String {
        var parts = [
            "code=\(dayKey)",
            "type=\(type)"
        ]

        if let dateText {
            parts.append("date=\(dateText)")
        }

        parts += [
            "wd=\(weekdayText)",
            "wi=\(weekdayIndex)",
            "first=\(firstMinute)(\(firstTime24))",
            "last=\(lastMinute)(\(lastTime24))"
        ]

        return parts.joined(separator: " ")
    }
}

@Generable
private struct GeneratedAvailabilityResponse {
    @Guide(description: "The matched availability ranges. Group days only when startMinute and endMinute are the same.")
    var ranges: [GeneratedAvailabilityRange]
}

@Generable
private struct GeneratedAvailabilityRange {
    @Guide(description: "Day codes from the prompt that match this range; use only listed codes.")
    var dayCodes: [String]

    @Guide(description: "Start minute code from the times list. Use first only for all day/no start.", .range(0...1440))
    var startMinute: Int

    @Guide(description: "End minute code from the times list, exclusive. Use last only for all day/no end.", .range(0...1440))
    var endMinute: Int
}
