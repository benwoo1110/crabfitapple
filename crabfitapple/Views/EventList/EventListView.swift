import SwiftData
import SwiftUI

struct EventListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var savedEvents: [SavedEvent]
    @State private var viewModel = EventListViewModel()

    private var sortedSavedEvents: [SavedEvent] {
        viewModel.sortedSavedEvents(savedEvents)
    }

    private var missingCachedEventDataEventIDs: [String] {
        viewModel.missingCachedEventDataEventIDs(from: savedEvents)
    }

    private var selectedEvent: SavedEvent? {
        viewModel.selectedEvent(in: savedEvents)
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
                        Button("Add Event", systemImage: "plus", action: viewModel.showAddEventSheet)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(selection: $viewModel.selectedEventID) {
                        ForEach(sortedSavedEvents) { event in
                            NavigationLink(value: event.eventID) {
                                EventRowView(event: event)
                            }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    viewModel.delete(event, modelContext: modelContext)
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
                    Button("Settings", systemImage: "gearshape", action: viewModel.showSettingsSheet)
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu("Sort", systemImage: "arrow.up.arrow.down") {
                        Picker("Sort By", selection: $viewModel.sortField) {
                            ForEach(EventListSortField.allCases) { field in
                                Label(field.title, systemImage: field.systemImage)
                                    .tag(field)
                            }
                        }

                        Picker("Order", selection: $viewModel.sortOrder) {
                            ForEach(EventListSortOrder.allCases) { order in
                                Label(order.title, systemImage: order.systemImage)
                                    .tag(order)
                            }
                        }
                    }
                    .accessibilityValue(Text(viewModel.sortAccessibilityValue))
                }

                ToolbarItem(placement: .bottomBar) {
                    Button(action: viewModel.showAddEventSheet) {
                        Label("Add Event", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .sheet(isPresented: $viewModel.isShowingAddEventSheet) {
                AddEventSheet()
            }
            .sheet(isPresented: $viewModel.isShowingSettingsSheet) {
                SettingsView()
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
            .alert("Could Not Delete Event", isPresented: $viewModel.isShowingError) {
            } message: {
                Text(viewModel.errorMessage)
            }
            .task(id: missingCachedEventDataEventIDs) {
                await viewModel.backfillMissingEventData(
                    for: missingCachedEventDataEventIDs,
                    savedEvents: savedEvents,
                    modelContext: modelContext
                )
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
}

#Preview {
    EventListView()
        .modelContainer(for: SavedEvent.self, inMemory: true)
}
