import Observation
import SwiftData
import SwiftUI

@Observable
final class EventListViewModel {
    var selectedEventID: String?
    var sortField = EventListSortField.date
    var sortOrder = EventListSortOrder.descending
    var isShowingSettingsSheet = false
    var isShowingAddEventSheet = false
    var isShowingError = false
    var errorMessage = ""

    private let api: CrabFitApi

    init(api: CrabFitApi = CrabFitApi()) {
        self.api = api
    }

    var sortAccessibilityValue: String {
        "\(sortField.title), \(sortOrder.title)"
    }

    func sortedSavedEvents(_ savedEvents: [SavedEvent]) -> [SavedEvent] {
        savedEvents.sorted { firstEvent, secondEvent in
            switch sortField {
            case .date:
                return isSortedByDate(firstEvent, before: secondEvent)
            case .name:
                return isSortedByName(firstEvent, before: secondEvent, order: sortOrder)
            }
        }
    }

    func missingCachedEventDataEventIDs(from savedEvents: [SavedEvent]) -> [String] {
        savedEvents
            .filter { !$0.hasCachedEventData }
            .map(\.eventID)
            .sorted()
    }

    func selectedEvent(in savedEvents: [SavedEvent]) -> SavedEvent? {
        guard let selectedEventID else { return nil }
        return savedEvents.first { $0.eventID == selectedEventID }
    }

    func showSettingsSheet() {
        isShowingSettingsSheet = true
    }

    func showAddEventSheet() {
        isShowingAddEventSheet = true
    }

    func backfillMissingEventData(
        for eventIDs: [String],
        savedEvents: [SavedEvent],
        modelContext: ModelContext
    ) async {
        guard !eventIDs.isEmpty else { return }

        for eventID in eventIDs {
            guard !Task.isCancelled else { return }
            guard savedEvents.contains(where: { $0.eventID == eventID && !$0.hasCachedEventData }) else {
                continue
            }

            do {
                let event = try await api.event(id: eventID)
                guard !Task.isCancelled else { return }
                saveCachedEventData(event, for: eventID, savedEvents: savedEvents, modelContext: modelContext)
            } catch {
                continue
            }
        }
    }

    func delete(_ event: SavedEvent, modelContext: ModelContext) {
        let deletedEventID = event.eventID
        modelContext.delete(event)

        do {
            try modelContext.save()

            if selectedEventID == deletedEventID {
                selectedEventID = nil
            }
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
            isShowingError = true
        }
    }

    private func isSortedByDate(_ firstEvent: SavedEvent, before secondEvent: SavedEvent) -> Bool {
        if let firstCreatedDate = firstEvent.createdDate,
           let secondCreatedDate = secondEvent.createdDate,
           firstCreatedDate != secondCreatedDate {
            switch sortOrder {
            case .ascending:
                return firstCreatedDate < secondCreatedDate
            case .descending:
                return firstCreatedDate > secondCreatedDate
            }
        }

        if firstEvent.createdDate != nil, secondEvent.createdDate == nil {
            return true
        }

        if firstEvent.createdDate == nil, secondEvent.createdDate != nil {
            return false
        }

        return isSortedByName(firstEvent, before: secondEvent, order: .ascending)
    }

    private func isSortedByName(
        _ firstEvent: SavedEvent,
        before secondEvent: SavedEvent,
        order: EventListSortOrder
    ) -> Bool {
        let nameComparison = firstEvent.name.localizedCaseInsensitiveCompare(secondEvent.name)
        if nameComparison != .orderedSame {
            switch order {
            case .ascending:
                return nameComparison == .orderedAscending
            case .descending:
                return nameComparison == .orderedDescending
            }
        }

        return firstEvent.eventID.localizedCaseInsensitiveCompare(secondEvent.eventID) == .orderedAscending
    }

    private func saveCachedEventData(
        _ event: CrabFitEvent,
        for eventID: String,
        savedEvents: [SavedEvent],
        modelContext: ModelContext
    ) {
        guard let savedEvent = savedEvents.first(where: { $0.eventID == eventID }),
              !savedEvent.hasCachedEventData else {
            return
        }

        savedEvent.updateCache(with: event)

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
        }
    }
}
