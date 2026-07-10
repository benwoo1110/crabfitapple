import Foundation
import Observation
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Observable
final class AddEventSheetViewModel {
    var eventEntryMode = EventEntryMode.existing
    var eventID = ""
    var newEventName = ""
    var newEventDateMode = NewEventDateMode.specificDates
    var selectedSpecificDateComponents: Set<DateComponents> = []
    var selectedWeekdays: Set<EventWeekday> = []
    var newEventStartHour = 9
    var newEventEndHour = 17
    var newEventTimeZoneID = AddEventSheetViewModel.defaultTimeZoneIdentifier
    var isSaving = false
    var isShowingError = false
    var errorMessage = ""

    private let api: CrabFitApi

    static let timeZoneIdentifiers = TimeZone.knownTimeZoneIdentifiers.sorted()
    private static let utcTimeZone = TimeZone(identifier: "UTC") ?? .current

    init(api: CrabFitApi = CrabFitApi()) {
        self.api = api
    }

    static var defaultTimeZoneIdentifier: String {
        let identifier = TimeZone.current.identifier
        return timeZoneIdentifiers.contains(identifier) ? identifier : "UTC"
    }

    var submittedEventID: String? {
        Self.eventID(from: eventID)
    }

    var hasSelectedCreateDates: Bool {
        switch newEventDateMode {
        case .specificDates:
            !selectedSpecificDateComponents.isEmpty
        case .weekdays:
            !selectedWeekdays.isEmpty
        }
    }

    var newEventInput: CrabFitEventInput? {
        let times = newEventTimes
        guard !times.isEmpty else { return nil }

        let trimmedName = newEventName.trimmingCharacters(in: .whitespacesAndNewlines)
        return CrabFitEventInput(name: trimmedName, times: times, timezone: newEventTimeZoneID)
    }

    var newEventTimes: [String] {
        guard hasSelectedCreateDates,
              newEventStartHour != newEventEndHour,
              let timeZone = TimeZone(identifier: newEventTimeZoneID) else {
            return []
        }

        let rawValues: [String]
        switch newEventDateMode {
        case .specificDates:
            rawValues = sortedSpecificDateComponents.flatMap { dateComponents in
                selectedEventHours.compactMap { hour in
                    Self.rawValue(forSpecificDate: dateComponents, hour: hour, timeZone: timeZone)
                }
            }
        case .weekdays:
            rawValues = sortedSelectedWeekdays.flatMap { weekday in
                selectedEventHours.compactMap { hour in
                    Self.rawValue(forWeekday: weekday, hour: hour, timeZone: timeZone)
                }
            }
        }

        return CrabFitTimeSlot.sortedRawValues(rawValues)
    }

    var sortedSpecificDateComponents: [DateComponents] {
        selectedSpecificDateComponents.sorted { firstComponents, secondComponents in
            Self.dateSortValue(firstComponents) < Self.dateSortValue(secondComponents)
        }
    }

    var sortedSelectedWeekdays: [EventWeekday] {
        selectedWeekdays.sorted { firstWeekday, secondWeekday in
            firstWeekday.sortOrder < secondWeekday.sortOrder
        }
    }

    var selectedEventHours: [Int] {
        Self.eventHours(startHour: newEventStartHour, endHour: newEventEndHour)
    }

    var canSubmit: Bool {
        guard !isSaving else { return false }

        switch eventEntryMode {
        case .existing:
            return submittedEventID != nil
        case .create:
            return newEventInput != nil
        }
    }

    var primaryButtonTitle: String {
        switch eventEntryMode {
        case .existing:
            "Add"
        case .create:
            "Create"
        }
    }

    var progressAccessibilityLabel: String {
        switch eventEntryMode {
        case .existing:
            "Adding Event"
        case .create:
            "Creating Event"
        }
    }

    var dateFooterText: String {
        switch newEventDateMode {
        case .specificDates:
            if selectedSpecificDateComponents.isEmpty {
                return "Choose at least one date."
            }

            let count = selectedSpecificDateComponents.count
            return count == 1 ? "1 date selected." : "\(count) dates selected."
        case .weekdays:
            if selectedWeekdays.isEmpty {
                return "Choose at least one day of the week."
            }

            let count = selectedWeekdays.count
            return count == 1 ? "1 day selected." : "\(count) days selected."
        }
    }

    var timeFooterText: String {
        if newEventStartHour == newEventEndHour {
            return "Choose different start and end times."
        }

        return "Creates one-hour event options across this time range."
    }

    func prepareTextInput() async {
        if eventID.isEmpty, let clipboardText = Self.prefillText(from: Self.clipboardString) {
            eventID = clipboardText
        }
    }

    func primaryButtonTapped(modelContext: ModelContext) async -> Bool {
        switch eventEntryMode {
        case .existing:
            return await addExistingEvent(modelContext: modelContext)
        case .create:
            return await createEvent(modelContext: modelContext)
        }
    }

    func isWeekdaySelected(_ weekday: EventWeekday) -> Bool {
        selectedWeekdays.contains(weekday)
    }

    func setWeekday(_ weekday: EventWeekday, isSelected: Bool) {
        if isSelected {
            selectedWeekdays.insert(weekday)
        } else {
            selectedWeekdays.remove(weekday)
        }
    }

    private func addExistingEvent(modelContext: ModelContext) async -> Bool {
        guard let requestedEventID = submittedEventID, !isSaving else { return false }

        isSaving = true
        defer { isSaving = false }

        do {
            guard try !savedEventExists(eventID: requestedEventID, modelContext: modelContext) else {
                showDuplicateEventError()
                return false
            }

            let event = try await api.event(id: requestedEventID)

            guard try !savedEventExists(eventID: event.id, modelContext: modelContext) else {
                showDuplicateEventError()
                return false
            }

            try insertSavedEvent(event, modelContext: modelContext)
            return true
        } catch {
            showError(error.localizedDescription)
            return false
        }
    }

    private func createEvent(modelContext: ModelContext) async -> Bool {
        guard let input = newEventInput, !isSaving else {
            showCreateEventValidationError()
            return false
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let event = try await api.createEvent(input)

            guard try !savedEventExists(eventID: event.id, modelContext: modelContext) else {
                showDuplicateEventError()
                return false
            }

            try insertSavedEvent(event, modelContext: modelContext)
            return true
        } catch {
            showError(error.localizedDescription)
            return false
        }
    }

    private func insertSavedEvent(_ event: CrabFitEvent, modelContext: ModelContext) throws {
        modelContext.insert(SavedEvent(event: event))
        try modelContext.save()
    }

    private func savedEventExists(eventID: String, modelContext: ModelContext) throws -> Bool {
        var descriptor = FetchDescriptor<SavedEvent>(
            predicate: #Predicate<SavedEvent> { savedEvent in
                savedEvent.eventID == eventID
            }
        )
        descriptor.includePendingChanges = true

        return try !modelContext.fetch(descriptor).isEmpty
    }

    private func showDuplicateEventError() {
        showError("This event is already in your list.")
    }

    private func showCreateEventValidationError() {
        if !hasSelectedCreateDates {
            showError("Choose at least one date or day of the week.")
        } else if newEventStartHour == newEventEndHour {
            showError("Choose different start and end times.")
        } else {
            showError("Could not create any valid event times.")
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        isShowingError = true
    }

    private static func prefillText(from text: String?) -> String? {
        guard let text else { return nil }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard eventID(fromEventURLText: trimmedText) != nil else { return nil }

        return trimmedText
    }

    private static func eventID(from text: String) -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        if let eventID = eventID(fromEventURLText: trimmedText) {
            return eventID
        }

        guard isValidEventID(trimmedText) else { return nil }
        return trimmedText
    }

    private static func eventID(fromEventURLText text: String) -> String? {
        guard let url = URL(string: text), isCrabFitURL(url) else {
            return nil
        }

        let pathComponents = url.path(percentEncoded: false)
            .split(separator: "/")
            .map(String.init)

        guard pathComponents.count == 1,
              let eventID = pathComponents.first,
              isValidEventID(eventID) else {
            return nil
        }

        return eventID
    }

    private static func isCrabFitURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return false
        }

        guard let host = url.host(percentEncoded: false)?.lowercased() else {
            return false
        }

        return host == "crab.fit" || host == "www.crab.fit"
    }

    private static func isValidEventID(_ eventID: String) -> Bool {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return !eventID.isEmpty && eventID.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    private static func eventHours(startHour: Int, endHour: Int) -> [Int] {
        guard startHour != endHour else { return [] }

        if startHour < endHour {
            return Array(startHour..<endHour)
        }

        return Array(0..<endHour) + Array(startHour..<24)
    }

    private static func rawValue(forSpecificDate dateComponents: DateComponents, hour: Int, timeZone: TimeZone) -> String? {
        var localComponents = DateComponents()
        localComponents.calendar = gregorianCalendar(timeZone: timeZone)
        localComponents.timeZone = timeZone
        localComponents.year = dateComponents.year
        localComponents.month = dateComponents.month
        localComponents.day = dateComponents.day
        localComponents.hour = hour
        localComponents.minute = 0

        guard let date = localComponents.date else { return nil }
        return rawSpecificDateFormatter().string(from: date)
    }

    private static func rawValue(forWeekday weekday: EventWeekday, hour: Int, timeZone: TimeZone) -> String? {
        var localComponents = DateComponents()
        localComponents.calendar = gregorianCalendar(timeZone: timeZone)
        localComponents.timeZone = timeZone
        localComponents.year = 2024
        localComponents.month = 1
        localComponents.day = 7 + weekday.sortOrder
        localComponents.hour = hour
        localComponents.minute = 0

        guard let date = localComponents.date else { return nil }

        let utcCalendar = gregorianCalendar(timeZone: utcTimeZone)
        let utcComponents = utcCalendar.dateComponents([.hour, .minute, .weekday], from: date)
        guard let utcHour = utcComponents.hour,
              let utcMinute = utcComponents.minute,
              let utcWeekday = utcComponents.weekday else {
            return nil
        }

        return String(format: "%02d%02d-%d", utcHour, utcMinute, utcWeekday - 1)
    }

    private static func dateSortValue(_ dateComponents: DateComponents) -> Int {
        let year = dateComponents.year ?? 0
        let month = dateComponents.month ?? 0
        let day = dateComponents.day ?? 0
        return year * 10_000 + month * 100 + day
    }

    static func formattedHour(_ hour: Int) -> String {
        let period = hour < 12 ? "AM" : "PM"
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        return "\(hour12) \(period)"
    }

    private static func gregorianCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func rawSpecificDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmm-ddMMyyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utcTimeZone
        return formatter
    }

    private static var clipboardString: String? {
#if canImport(UIKit)
        UIPasteboard.general.string
#elseif canImport(AppKit)
        NSPasteboard.general.string(forType: .string)
#else
        nil
#endif
    }
}

enum EventEntryMode: CaseIterable, Identifiable, Sendable {
    case existing
    case create

    var id: Self { self }

    var title: String {
        switch self {
        case .existing:
            "Existing"
        case .create:
            "New"
        }
    }

    var navigationTitle: String {
        switch self {
        case .existing:
            "Add Event"
        case .create:
            "Create Event"
        }
    }
}

enum NewEventDateMode: CaseIterable, Identifiable, Sendable {
    case specificDates
    case weekdays

    var id: Self { self }

    var title: String {
        switch self {
        case .specificDates:
            "Specific Dates"
        case .weekdays:
            "Days of the Week"
        }
    }
}

enum EventWeekday: CaseIterable, Identifiable, Sendable {
    case sunday
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    var id: Self { self }

    var title: String {
        switch self {
        case .sunday:
            "Sunday"
        case .monday:
            "Monday"
        case .tuesday:
            "Tuesday"
        case .wednesday:
            "Wednesday"
        case .thursday:
            "Thursday"
        case .friday:
            "Friday"
        case .saturday:
            "Saturday"
        }
    }

    var sortOrder: Int {
        switch self {
        case .sunday:
            0
        case .monday:
            1
        case .tuesday:
            2
        case .wednesday:
            3
        case .thursday:
            4
        case .friday:
            5
        case .saturday:
            6
        }
    }
}
