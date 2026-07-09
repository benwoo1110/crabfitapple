import Foundation
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct AddEventSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var eventEntryMode = EventEntryMode.existing
    @State private var eventID = ""
    @State private var newEventName = ""
    @State private var newEventDateMode = NewEventDateMode.specificDates
    @State private var selectedSpecificDateComponents: Set<DateComponents> = []
    @State private var selectedWeekdays: Set<EventWeekday> = []
    @State private var newEventStartHour = 9
    @State private var newEventEndHour = 17
    @State private var newEventTimeZoneID = Self.defaultTimeZoneIdentifier
    @State private var isSaving = false
    @State private var isShowingError = false
    @State private var errorMessage = ""
    @FocusState private var isEventIDFieldFocused: Bool

    private let api = CrabFitApi()

    private static let timeZoneIdentifiers = TimeZone.knownTimeZoneIdentifiers.sorted()
    private static let utcTimeZone = TimeZone(identifier: "UTC") ?? .current

    private static var eventEntryModeAnimation: Animation {
        .easeInOut(duration: 0.2)
    }

    private static var defaultTimeZoneIdentifier: String {
        let identifier = TimeZone.current.identifier
        return timeZoneIdentifiers.contains(identifier) ? identifier : "UTC"
    }

    private var submittedEventID: String? {
        Self.eventID(from: eventID)
    }

    private var hasSelectedCreateDates: Bool {
        switch newEventDateMode {
        case .specificDates:
            !selectedSpecificDateComponents.isEmpty
        case .weekdays:
            !selectedWeekdays.isEmpty
        }
    }

    private var newEventInput: CrabFitEventInput? {
        let times = newEventTimes
        guard !times.isEmpty else { return nil }

        let trimmedName = newEventName.trimmingCharacters(in: .whitespacesAndNewlines)
        return CrabFitEventInput(name: trimmedName, times: times, timezone: newEventTimeZoneID)
    }

    private var newEventTimes: [String] {
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

    private var sortedSpecificDateComponents: [DateComponents] {
        selectedSpecificDateComponents.sorted { firstComponents, secondComponents in
            Self.dateSortValue(firstComponents) < Self.dateSortValue(secondComponents)
        }
    }

    private var sortedSelectedWeekdays: [EventWeekday] {
        selectedWeekdays.sorted { firstWeekday, secondWeekday in
            firstWeekday.sortOrder < secondWeekday.sortOrder
        }
    }

    private var selectedEventHours: [Int] {
        Self.eventHours(startHour: newEventStartHour, endHour: newEventEndHour)
    }

    private var eventEntryModeBinding: Binding<EventEntryMode> {
        Binding {
            eventEntryMode
        } set: { newMode in
            withAnimation(Self.eventEntryModeAnimation) {
                eventEntryMode = newMode
            }
        }
    }

    private var canSubmit: Bool {
        guard !isSaving else { return false }

        switch eventEntryMode {
        case .existing:
            return submittedEventID != nil
        case .create:
            return newEventInput != nil
        }
    }

    private var primaryButtonTitle: String {
        switch eventEntryMode {
        case .existing:
            "Add"
        case .create:
            "Create"
        }
    }

    private var progressAccessibilityLabel: String {
        switch eventEntryMode {
        case .existing:
            "Adding Event"
        case .create:
            "Creating Event"
        }
    }

    private var dateFooterText: String {
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

    private var timeFooterText: String {
        if newEventStartHour == newEventEndHour {
            return "Choose different start and end times."
        }

        return "Creates one-hour event options across this time range."
    }

    var body: some View {
        NavigationStack {
            Form {
                switch eventEntryMode {
                case .existing:
                    existingEventSection
                case .create:
                    createEventSections
                }
            }
            .animation(Self.eventEntryModeAnimation, value: eventEntryMode)
            .navigationTitle(eventEntryMode.navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .disabled(isSaving)
                }

                ToolbarItem(placement: .principal) {
                    Picker("Event Action", selection: eventEntryModeBinding) {
                        ForEach(EventEntryMode.allCases) { mode in
                            Text(mode.title)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isSaving)
                    .frame(maxWidth: 220)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .accessibilityLabel(progressAccessibilityLabel)
                    } else {
                        Button(primaryButtonTitle, action: primaryButtonTapped)
                            .buttonStyle(.borderedProminent)
                            .disabled(!canSubmit)
                    }
                }
            }
            .alert("Could Not Save Event", isPresented: $isShowingError) {
            } message: {
                Text(errorMessage)
            }
            .task(prepareTextInput)
            .onChange(of: eventEntryMode) { _, newMode in
                isEventIDFieldFocused = newMode == .existing
            }
        }
    }

    private var existingEventSection: some View {
        Section {
            TextField("Event ID or URL", text: $eventID)
#if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
#endif
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isEventIDFieldFocused)
                .disabled(isSaving)
                .onSubmit(primaryButtonTapped)
        } header: {
            Text("Event")
        } footer: {
            Text("Use a Crab Fit event URL or event ID.")
        }
    }

    @ViewBuilder
    private var createEventSections: some View {
        Section {
            TextField("Name", text: $newEventName)
#if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.sentences)
#endif
                .disabled(isSaving)
        } header: {
            Text("Event Name")
        } footer: {
            Text("Leave blank to generate one.")
        }

        Section {
            Picker("Date Type", selection: $newEventDateMode) {
                ForEach(NewEventDateMode.allCases) { mode in
                    Text(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isSaving)

            switch newEventDateMode {
            case .specificDates:
                MultiDatePicker("Specific Dates", selection: $selectedSpecificDateComponents)
                    .disabled(isSaving)
            case .weekdays:
                ForEach(EventWeekday.allCases) { weekday in
                    Toggle(weekday.title, isOn: weekdaySelectionBinding(for: weekday))
                        .disabled(isSaving)
                }
            }
        } header: {
            Text("Dates")
        } footer: {
            Text(dateFooterText)
        }

        Section {
            Picker("Start", selection: $newEventStartHour) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(Self.formattedHour(hour))
                        .tag(hour)
                }
            }
            .disabled(isSaving)

            Picker("End", selection: $newEventEndHour) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(Self.formattedHour(hour))
                        .tag(hour)
                }
            }
            .disabled(isSaving)
        } header: {
            Text("Times")
        } footer: {
            Text(timeFooterText)
        }

        Section {
            Picker("Timezone", selection: $newEventTimeZoneID) {
                ForEach(Self.timeZoneIdentifiers, id: \.self) { identifier in
                    Text(identifier)
                        .tag(identifier)
                }
            }
            .disabled(isSaving)
        }
    }

    private func cancel() {
        dismiss()
    }

    private func prepareTextInput() async {
        if eventID.isEmpty, let clipboardText = Self.prefillText(from: Self.clipboardString) {
            eventID = clipboardText
        }

        await Task.yield()
        isEventIDFieldFocused = eventEntryMode == .existing
    }

    private func primaryButtonTapped() {
        Task {
            switch eventEntryMode {
            case .existing:
                await addExistingEvent()
            case .create:
                await createEvent()
            }
        }
    }

    private func addExistingEvent() async {
        guard let requestedEventID = submittedEventID, !isSaving else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            guard try !savedEventExists(eventID: requestedEventID) else {
                showDuplicateEventError()
                return
            }

            let event = try await api.event(id: requestedEventID)

            guard try !savedEventExists(eventID: event.id) else {
                showDuplicateEventError()
                return
            }

            try insertSavedEvent(event)
            dismiss()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func createEvent() async {
        guard let input = newEventInput, !isSaving else {
            showCreateEventValidationError()
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let event = try await api.createEvent(input)

            guard try !savedEventExists(eventID: event.id) else {
                showDuplicateEventError()
                return
            }

            try insertSavedEvent(event)
            dismiss()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func insertSavedEvent(_ event: CrabFitEvent) throws {
        modelContext.insert(SavedEvent(event: event))
        try modelContext.save()
    }

    private func savedEventExists(eventID: String) throws -> Bool {
        var descriptor = FetchDescriptor<SavedEvent>(
            predicate: #Predicate<SavedEvent> { savedEvent in
                savedEvent.eventID == eventID
            }
        )
        descriptor.includePendingChanges = true

        return try !modelContext.fetch(descriptor).isEmpty
    }

    private func weekdaySelectionBinding(for weekday: EventWeekday) -> Binding<Bool> {
        Binding {
            selectedWeekdays.contains(weekday)
        } set: { isSelected in
            if isSelected {
                selectedWeekdays.insert(weekday)
            } else {
                selectedWeekdays.remove(weekday)
            }
        }
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

    private static func formattedHour(_ hour: Int) -> String {
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

private enum EventEntryMode: CaseIterable, Identifiable {
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

private enum NewEventDateMode: CaseIterable, Identifiable {
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

private enum EventWeekday: CaseIterable, Identifiable {
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

#Preview {
    AddEventSheet()
        .modelContainer(for: SavedEvent.self, inMemory: true)
}
