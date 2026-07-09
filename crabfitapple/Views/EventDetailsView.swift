import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct EventDetailsView: View {
    let savedEvent: SavedEvent

    @Environment(\.modelContext) private var modelContext
    @State private var event: CrabFitEvent?
    @State private var people: [CrabFitPerson] = []
    @State private var isLoading = false
    @State private var loadingEventID: String?
    @State private var errorMessage: String?
    @State private var availabilityGridSlots: [AvailabilityGridSlot] = []
    @State private var availabilityByPerson: [String: Set<String>] = [:]
    @State private var availabilityCountByRawValue: [String: Int] = [:]
    @State private var availabilitySummaryRanges: [AvailabilitySummaryRange] = []
    @State private var selectedAvailabilityRangeID: String?
    @State private var highlightedAvailabilitySlotRawValues: Set<String> = []
    @State private var isShowingEditAvailabilitySheet = false
    @State private var copiedEventLinkID: String?
    @State private var availabilityEditorPreloadState = AvailabilityEditorPreloadState.loading
    @State private var availabilityEditorPreloadRequestID: UUID?
    @State private var availabilityEditorContext = AvailabilityEditorContext.empty

    private let api = CrabFitApi()
    private let eventDurationMinutes = 60
    private let slotDurationMinutes = 15

    private var localTimeZoneIdentifier: String {
        TimeZone.current.identifier
    }

    private static let eventContentAnimation = Animation.easeInOut(duration: 0.24)
    private static let availabilityUpdateAnimation = Animation.easeInOut(duration: 0.22)
    private static let eventContentTransition = AnyTransition.opacity.combined(with: .scale(scale: 0.98))

    private var eventContentPhaseID: String {
        if let event {
            return "event-\(event.id)"
        }

        if isLoading {
            return "loading-\(savedEvent.eventID)"
        }

        if errorMessage != nil {
            return "error-\(savedEvent.eventID)"
        }

        return "idle-\(savedEvent.eventID)"
    }

    var body: some View {
        ZStack {
            if let event {
                Form {
                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Availability Map") {
                        if people.isEmpty && !isLoading {
                            Text("No availability responses yet.")
                                .foregroundStyle(.secondary)
                        }

                        EventAvailabilityGridView(
                            slots: availabilityGridSlots,
                            people: people,
                            availabilityByPerson: availabilityByPerson,
                            availabilityCountByRawValue: availabilityCountByRawValue,
                            highlightedSlotRawValues: highlightedAvailabilitySlotRawValues
                        )

                        Button("Edit My Availability", systemImage: "pencil", action: editAvailabilityButtonTapped)
                            .disabled(availabilityGridSlots.isEmpty)
                    }

                    Section("Most Common Availability") {
                        if people.isEmpty && !isLoading {
                            Text("No availability responses yet.")
                                .foregroundStyle(.secondary)
                        } else if !people.isEmpty && availabilitySummaryRanges.isEmpty {
                            Text("No common availability yet.")
                                .foregroundStyle(.secondary)
                        } else if !people.isEmpty {
                            ForEach(availabilitySummaryRanges) { range in
                                availabilitySummaryRangeButton(for: range)
                            }
                        }
                    }

                    Section("Event") {
                        LabeledContent("Name", value: event.name)
                        LabeledContent("ID", value: event.id)
                        LabeledContent("Timezone", value: event.timezone)
                        LabeledContent("Created", value: formattedDate(event.createdDate, timeZoneIdentifier: event.timezone))
                        LabeledContent("Event Ranges", value: "\(event.times.count)")
                        LabeledContent("Availability Slots", value: "\(calendarSlotCount(for: event))")
                        LabeledContent("People", value: "\(people.count)")
                    }
                    .textSelection(.enabled)

                    Section {
                        Button(action: { copyEventLinkButtonTapped(for: event) }) {
                            Label(
                                copiedEventLinkID == event.id ? "Copied Event Link" : "Copy Event Link",
                                systemImage: copiedEventLinkID == event.id ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .accessibilityHint("Copies the Crab Fit event link to the clipboard")
                    }
                }
                .refreshable {
                    await loadEvent()
                }
                .id(event.id)
                .transition(Self.eventContentTransition)
            } else if isLoading {
                ProgressView("Loading Event")
                    .transition(Self.eventContentTransition)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Could Not Load Event",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .transition(Self.eventContentTransition)
            } else {
                ProgressView("Loading Event")
                    .transition(Self.eventContentTransition)
            }
        }
        .animation(Self.eventContentAnimation, value: eventContentPhaseID)
        .navigationTitle(event?.name ?? savedEvent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isLoading {
                    ProgressView()
                        .accessibilityLabel("Refreshing Event")
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise", action: refreshButtonTapped)
                }
            }
        }
        .sheet(isPresented: $isShowingEditAvailabilitySheet) {
            if let event {
                EditAvailabilitySheet(
                    event: event,
                    slots: availabilityGridSlots,
                    context: availabilityEditorContext,
                    slotDurationMinutes: slotDurationMinutes,
                    displayTimeZoneIdentifier: localTimeZoneIdentifier,
                    preloadedAvailability: availabilityEditorPreloadState,
                    onSaved: availabilityEditorSaved
                )
            }
        }
        .task(id: savedEvent.eventID) {
            await loadEvent()
        }
        .task(id: copiedEventLinkID) {
            guard copiedEventLinkID != nil else { return }
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            copiedEventLinkID = nil
        }
    }

    private func refreshButtonTapped() {
        Task {
            await loadEvent()
        }
    }

    private func editAvailabilityButtonTapped() {
        isShowingEditAvailabilitySheet = true
    }

    private func copyEventLinkButtonTapped(for event: CrabFitEvent) {
        Self.copyToClipboard(Self.eventLink(for: event.id))
        copiedEventLinkID = event.id
    }

    private func availabilityEditorSaved(_ updatedPerson: CrabFitPerson) {
        guard event != nil else { return }

        let updatedPeople = sortedPeople(peopleByUpdating(updatedPerson, in: people))
        let updatedAvailabilityByPerson = availabilityByPerson(for: updatedPeople)
        let updatedAvailabilityCountByRawValue = availabilityCountByRawValue(for: updatedPeople)
        let updatedSummaryRanges = mostAvailableRanges(
            from: availabilityGridSlots,
            people: updatedPeople,
            availabilityByPerson: updatedAvailabilityByPerson,
            timeZoneIdentifier: localTimeZoneIdentifier
        )

        withAnimation(Self.availabilityUpdateAnimation) {
            people = updatedPeople
            availabilityByPerson = updatedAvailabilityByPerson
            availabilityCountByRawValue = updatedAvailabilityCountByRawValue
            availabilitySummaryRanges = updatedSummaryRanges
            updateHighlightedAvailabilityRange(using: updatedSummaryRanges)
        }

        updateAvailabilityEditorPreload(with: updatedPerson)
    }

    private func peopleByUpdating(_ updatedPerson: CrabFitPerson, in people: [CrabFitPerson]) -> [CrabFitPerson] {
        var updatedPeople = people

        if let index = updatedPeople.firstIndex(where: { $0.id == updatedPerson.id }) {
            updatedPeople[index] = updatedPerson
        } else {
            updatedPeople.append(updatedPerson)
        }

        return updatedPeople
    }

    private func toggleAvailabilityRangeSelection(_ range: AvailabilitySummaryRange) {
        withAnimation(Self.availabilityUpdateAnimation) {
            if selectedAvailabilityRangeID == range.id {
                selectedAvailabilityRangeID = nil
                highlightedAvailabilitySlotRawValues = []
            } else {
                selectedAvailabilityRangeID = range.id
                highlightedAvailabilitySlotRawValues = Set(range.rawValues)
            }
        }
    }

    private func availabilitySummaryRangeButton(for range: AvailabilitySummaryRange) -> some View {
        let isSelected = selectedAvailabilityRangeID == range.id
        let rowBackground: Color? = isSelected ? Color.orange.opacity(0.22) : nil

        return Button {
            toggleAvailabilityRangeSelection(range)
        } label: {
            AvailabilitySummaryRangeRowView(
                range: range,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(rowBackground)
        .accessibilityHint("Highlights this range in the availability map")
    }

    private func loadEvent() async {
        let eventID = savedEvent.eventID
        let isChangingEvent = event?.id != eventID
        loadingEventID = eventID

        isLoading = true

        if isChangingEvent {
            event = nil
            people = []
            availabilityGridSlots = []
            availabilityByPerson = [:]
            availabilityCountByRawValue = [:]
            availabilitySummaryRanges = []
            selectedAvailabilityRangeID = nil
            highlightedAvailabilitySlotRawValues = []
            availabilityEditorPreloadState = .loading
            availabilityEditorPreloadRequestID = nil
            availabilityEditorContext = .empty
            errorMessage = nil
        }

        defer {
            if loadingEventID == eventID {
                isLoading = false
                loadingEventID = nil
            }
        }

        do {
            let loadedEvent: CrabFitEvent

            if let cachedEvent = savedEvent.cachedEvent {
                loadedEvent = cachedEvent
            } else {
                loadedEvent = try await api.event(id: eventID)
                guard !Task.isCancelled, loadingEventID == eventID else { return }
                saveCachedEventDataIfNeeded(loadedEvent)
            }

            let displayTimeZoneIdentifier = localTimeZoneIdentifier
            let loadedGridSlots = availabilitySlots(for: loadedEvent)
            let loadedAvailabilityEditorContext = AvailabilityEditorContext(
                slots: loadedGridSlots,
                durationMinutes: slotDurationMinutes,
                timeZoneIdentifier: displayTimeZoneIdentifier
            )

            guard !Task.isCancelled, loadingEventID == eventID else { return }

            event = loadedEvent
            availabilityGridSlots = loadedGridSlots
            availabilityEditorContext = loadedAvailabilityEditorContext

            let fetchedPeople: [CrabFitPerson]
            let fetchedErrorMessage: String?

            do {
                fetchedPeople = try await api.people(eventID: eventID)
                fetchedErrorMessage = nil
            } catch {
                fetchedPeople = []
                fetchedErrorMessage = "Event loaded, but people could not be loaded: \(error.localizedDescription)"
            }

            let sortedFetchedPeople = sortedPeople(fetchedPeople)
            let fetchedAvailabilityByPerson = availabilityByPerson(for: sortedFetchedPeople)
            let fetchedAvailabilityCountByRawValue = availabilityCountByRawValue(for: sortedFetchedPeople)
            let fetchedSummaryRanges = mostAvailableRanges(
                from: loadedGridSlots,
                people: sortedFetchedPeople,
                availabilityByPerson: fetchedAvailabilityByPerson,
                timeZoneIdentifier: displayTimeZoneIdentifier
            )

            guard !Task.isCancelled, loadingEventID == eventID else { return }

            people = sortedFetchedPeople
            availabilityByPerson = fetchedAvailabilityByPerson
            availabilityCountByRawValue = fetchedAvailabilityCountByRawValue
            availabilitySummaryRanges = fetchedSummaryRanges
            updateHighlightedAvailabilityRange(using: fetchedSummaryRanges)
            errorMessage = fetchedErrorMessage

            preloadAvailabilityEditor(
                for: loadedEvent,
                people: sortedFetchedPeople,
                context: loadedAvailabilityEditorContext
            )
        } catch {
            guard !Task.isCancelled, loadingEventID == eventID else { return }

            errorMessage = error.localizedDescription
        }
    }

    private func saveCachedEventDataIfNeeded(_ event: CrabFitEvent) {
        guard savedEvent.cachedEvent != event else { return }

        savedEvent.updateCache(with: event)

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
        }
    }

    private func preloadAvailabilityEditor(
        for event: CrabFitEvent,
        people: [CrabFitPerson],
        context: AvailabilityEditorContext
    ) {
        let requestID = UUID()
        availabilityEditorPreloadRequestID = requestID

        do {
            guard let credentials = try AvailabilityCredentialsStore.credentialsForRequest() else {
                availabilityEditorPreloadState = .missingProfile
                return
            }

            if let person = people.first(where: { $0.id == credentials.name }) {
                availabilityEditorPreloadState = .ready(AvailabilityEditorPreloadedAvailability(
                    profileName: credentials.name,
                    profilePassword: credentials.password,
                    rawValues: person.availability,
                    context: context
                ))
                return
            }

            availabilityEditorPreloadState = .loading
            Task {
                await fetchAvailabilityEditorPreload(
                    eventID: event.id,
                    credentials: credentials,
                    requestID: requestID,
                    context: context
                )
            }
        } catch {
            availabilityEditorPreloadState = .failed(error.localizedDescription)
        }
    }

    private func fetchAvailabilityEditorPreload(
        eventID: String,
        credentials: (name: String, password: String?),
        requestID: UUID,
        context: AvailabilityEditorContext
    ) async {
        do {
            let person = try await api.person(
                eventID: eventID,
                name: credentials.name,
                password: credentials.password
            )

            guard !Task.isCancelled, availabilityEditorPreloadRequestID == requestID else { return }
            availabilityEditorPreloadState = .ready(AvailabilityEditorPreloadedAvailability(
                profileName: credentials.name,
                profilePassword: credentials.password,
                rawValues: person.availability,
                context: context
            ))
        } catch {
            guard !Task.isCancelled, availabilityEditorPreloadRequestID == requestID else { return }

            if isPersonNotFound(error) {
                availabilityEditorPreloadState = .ready(AvailabilityEditorPreloadedAvailability(
                    profileName: credentials.name,
                    profilePassword: credentials.password,
                    rawValues: [],
                    context: context
                ))
            } else {
                availabilityEditorPreloadState = .failed(error.localizedDescription)
            }
        }
    }

    private func updateAvailabilityEditorPreload(with updatedPerson: CrabFitPerson) {
        let profilePassword: String?
        if case .ready(let availability) = availabilityEditorPreloadState,
           availability.profileName == updatedPerson.name {
            profilePassword = availability.profilePassword
        } else {
            profilePassword = nil
        }

        availabilityEditorPreloadRequestID = nil
        availabilityEditorPreloadState = .ready(AvailabilityEditorPreloadedAvailability(
            profileName: updatedPerson.name,
            profilePassword: profilePassword,
            rawValues: updatedPerson.availability,
            context: availabilityEditorContext
        ))
    }

    private func sortedPeople(_ people: [CrabFitPerson]) -> [CrabFitPerson] {
        people.sorted { firstPerson, secondPerson in
            firstPerson.name.localizedCaseInsensitiveCompare(secondPerson.name) == .orderedAscending
        }
    }

    private func availabilityByPerson(for people: [CrabFitPerson]) -> [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: people.map { person in
            (person.id, Set(person.availability))
        })
    }

    private func availabilityCountByRawValue(for people: [CrabFitPerson]) -> [String: Int] {
        people.reduce(into: [:]) { counts, person in
            for rawValue in Set(person.availability) {
                counts[rawValue, default: 0] += 1
            }
        }
    }

    private func updateHighlightedAvailabilityRange(using ranges: [AvailabilitySummaryRange]) {
        guard let selectedAvailabilityRangeID,
              let selectedRange = ranges.first(where: { $0.id == selectedAvailabilityRangeID }) else {
            selectedAvailabilityRangeID = nil
            highlightedAvailabilitySlotRawValues = []
            return
        }

        highlightedAvailabilitySlotRawValues = Set(selectedRange.rawValues)
    }

    private func calendarSlotCount(for event: CrabFitEvent) -> Int {
        CrabFitTimeSlot.expandedRawValues(
            for: event.times,
            slotDurationMinutes: slotDurationMinutes,
            eventDurationMinutes: eventDurationMinutes
        ).count
    }

    private func mostAvailableRanges(
        from slots: [AvailabilityGridSlot],
        people: [CrabFitPerson],
        availabilityByPerson: [String: Set<String>],
        timeZoneIdentifier: String
    ) -> [AvailabilitySummaryRange] {
        let slotSummaries = slots.map { slot in
            (slot: slot, unavailableNames: unavailableNames(
                for: slot,
                people: people,
                availabilityByPerson: availabilityByPerson
            ))
        }
        let maximumAvailableCount = slotSummaries
            .map { people.count - $0.unavailableNames.count }
            .max() ?? 0

        guard maximumAvailableCount > 0 else { return [] }

        let bestSlotSummaries = slotSummaries.filter { summary in
            people.count - summary.unavailableNames.count == maximumAvailableCount
        }

        return groupedAvailabilityRanges(
            from: bestSlotSummaries,
            totalPeople: people.count,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    private func groupedAvailabilityRanges(
        from slotSummaries: [(slot: AvailabilityGridSlot, unavailableNames: [String])],
        totalPeople: Int,
        timeZoneIdentifier: String
    ) -> [AvailabilitySummaryRange] {
        var ranges: [AvailabilitySummaryRange] = []
        var currentRawValues: [String] = []
        var currentUnavailableNames: [String] = []
        var previousSlot: AvailabilityGridSlot?

        for summary in slotSummaries {
            if let previousSlot,
               currentUnavailableNames == summary.unavailableNames,
               areSlotsContinuous(previousSlot, summary.slot) {
                currentRawValues.append(summary.slot.rawValue)
            } else {
                appendAvailabilityRange(
                    rawValues: currentRawValues,
                    unavailableNames: currentUnavailableNames,
                    totalPeople: totalPeople,
                    timeZoneIdentifier: timeZoneIdentifier,
                    to: &ranges
                )

                currentRawValues = [summary.slot.rawValue]
                currentUnavailableNames = summary.unavailableNames
            }

            previousSlot = summary.slot
        }

        appendAvailabilityRange(
            rawValues: currentRawValues,
            unavailableNames: currentUnavailableNames,
            totalPeople: totalPeople,
            timeZoneIdentifier: timeZoneIdentifier,
            to: &ranges
        )

        return ranges
    }

    private func appendAvailabilityRange(
        rawValues: [String],
        unavailableNames: [String],
        totalPeople: Int,
        timeZoneIdentifier: String,
        to ranges: inout [AvailabilitySummaryRange]
    ) {
        guard !rawValues.isEmpty else { return }

        let detailLabel = CrabFitTimeSlot.formattedRanges(
            for: rawValues,
            durationMinutes: slotDurationMinutes,
            timeZoneIdentifier: timeZoneIdentifier
        ).first ?? rawValues.joined(separator: ", ")

        ranges.append(AvailabilitySummaryRange(
            rawValues: rawValues,
            detailLabel: detailLabel,
            availableCount: totalPeople - unavailableNames.count,
            totalPeople: totalPeople,
            unavailableNames: unavailableNames
        ))
    }

    private func areSlotsContinuous(_ firstSlot: AvailabilityGridSlot, _ secondSlot: AvailabilityGridSlot) -> Bool {
        guard let firstStartDate = CrabFitTimeSlot(rawValue: firstSlot.rawValue)?.startDate,
              let secondStartDate = CrabFitTimeSlot(rawValue: secondSlot.rawValue)?.startDate else {
            return false
        }

        let expectedInterval = TimeInterval(slotDurationMinutes * 60)
        let actualInterval = secondStartDate.timeIntervalSince(firstStartDate)
        return abs(actualInterval - expectedInterval) < 0.5
    }

    private func availabilitySlots(for event: CrabFitEvent) -> [AvailabilityGridSlot] {
        CrabFitTimeSlot.expandedRawValues(
            for: event.times,
            slotDurationMinutes: slotDurationMinutes,
            eventDurationMinutes: eventDurationMinutes
        )
        .compactMap { rawValue in
            AvailabilityGridSlot(
                rawValue: rawValue,
                timeZoneIdentifier: localTimeZoneIdentifier,
                durationMinutes: slotDurationMinutes
            )
        }
        .sorted { firstSlot, secondSlot in
            if firstSlot.daySortValue != secondSlot.daySortValue {
                return firstSlot.daySortValue < secondSlot.daySortValue
            }

            return firstSlot.timeID < secondSlot.timeID
        }
    }

    private func unavailableNames(
        for slot: AvailabilityGridSlot,
        people: [CrabFitPerson],
        availabilityByPerson: [String: Set<String>]
    ) -> [String] {
        people.compactMap { person in
            availabilityByPerson[person.id, default: []].contains(slot.rawValue) ? nil : person.name
        }
    }

    private func isPersonNotFound(_ error: Error) -> Bool {
        guard case CrabFitApiError.unexpectedStatusCode(404) = error else {
            return false
        }

        return true
    }

    private static func eventLink(for eventID: String) -> String {
        "https://crab.fit/\(eventID)"
    }

    private static func copyToClipboard(_ string: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = string
#elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        _ = NSPasteboard.general.setString(string, forType: .string)
#endif
    }

    private func formattedDate(_ date: Date, timeZoneIdentifier: String) -> String {
        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(identifier: "UTC") ?? .current
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, h:mm a"
        formatter.timeZone = timeZone

        return formatter.string(from: date)
    }
}
