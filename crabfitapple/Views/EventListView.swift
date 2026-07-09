import SwiftData
import SwiftUI

struct EventListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var savedEvents: [SavedEvent]
    @State private var selectedEventID: String?
    @State private var sortField = EventListSortField.date
    @State private var sortOrder = EventListSortOrder.descending
    @State private var isShowingSettingsSheet = false
    @State private var isShowingAddEventSheet = false
    @State private var isShowingError = false
    @State private var errorMessage = ""

    private let api = CrabFitApi()

    private var sortedSavedEvents: [SavedEvent] {
        savedEvents.sorted { firstEvent, secondEvent in
            switch sortField {
            case .date:
                return isSortedByDate(firstEvent, before: secondEvent)
            case .name:
                return isSortedByName(firstEvent, before: secondEvent, order: sortOrder)
            }
        }
    }

    private var sortAccessibilityValue: String {
        "\(sortField.title), \(sortOrder.title)"
    }

    private var missingCachedEventDataEventIDs: [String] {
        savedEvents
            .filter { !$0.hasCachedEventData }
            .map(\.eventID)
            .sorted()
    }

    private var selectedEvent: SavedEvent? {
        guard let selectedEventID else { return nil }
        return savedEvents.first { $0.eventID == selectedEventID }
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if sortedSavedEvents.isEmpty {
                    ContentUnavailableView {
                        Label("No Events", systemImage: "calendar.badge.plus")
                    } description: {
                        Text("Saved Crab Fit events appear here.")
                    } actions: {
                        Button("Add Event", systemImage: "plus", action: showAddEventSheet)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(selection: $selectedEventID) {
                        ForEach(sortedSavedEvents) { event in
                            NavigationLink(value: event.eventID) {
                                EventRowView(event: event)
                            }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    delete(event)
                                }
                                .tint(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Events")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape", action: showSettingsSheet)
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu("Sort", systemImage: "arrow.up.arrow.down") {
                        Picker("Sort By", selection: $sortField) {
                            ForEach(EventListSortField.allCases) { field in
                                Label(field.title, systemImage: field.systemImage)
                                    .tag(field)
                            }
                        }

                        Picker("Order", selection: $sortOrder) {
                            ForEach(EventListSortOrder.allCases) { order in
                                Label(order.title, systemImage: order.systemImage)
                                    .tag(order)
                            }
                        }
                    }
                    .accessibilityValue(Text(sortAccessibilityValue))
                }

                ToolbarItem(placement: .bottomBar) {
                    Button(action: showAddEventSheet) {
                        Label("Add Event", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .sheet(isPresented: $isShowingAddEventSheet) {
                AddEventSheet()
            }
            .sheet(isPresented: $isShowingSettingsSheet) {
                SettingsView()
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
            .alert("Could Not Delete Event", isPresented: $isShowingError) {
            } message: {
                Text(errorMessage)
            }
            .task(id: missingCachedEventDataEventIDs) {
                await backfillMissingEventData(for: missingCachedEventDataEventIDs)
            }
        } detail: {
            if let selectedEvent {
                EventDetailsView(savedEvent: selectedEvent)
            } else {
                ContentUnavailableView(
                    "Select an Event",
                    systemImage: "calendar",
                    description: Text("Choose an event from the list to view availability.")
                )
            }
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

    private func showSettingsSheet() {
        isShowingSettingsSheet = true
    }

    private func showAddEventSheet() {
        isShowingAddEventSheet = true
    }

    private func backfillMissingEventData(for eventIDs: [String]) async {
        guard !eventIDs.isEmpty else { return }

        for eventID in eventIDs {
            guard !Task.isCancelled else { return }
            guard savedEvents.contains(where: { $0.eventID == eventID && !$0.hasCachedEventData }) else {
                continue
            }

            do {
                let event = try await api.event(id: eventID)
                guard !Task.isCancelled else { return }
                saveCachedEventData(event, for: eventID)
            } catch {
                continue
            }
        }
    }

    private func saveCachedEventData(_ event: CrabFitEvent, for eventID: String) {
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

    private func delete(_ event: SavedEvent) {
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
}

#Preview {
    EventListView()
        .modelContainer(for: SavedEvent.self, inMemory: true)
}
