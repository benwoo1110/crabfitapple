import SwiftData
import SwiftUI

struct EventDetailsView: View {
    let savedEvent: SavedEvent

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = EventDetailsViewModel()

    private static let eventContentAnimation = Animation.easeInOut(duration: 0.24)
    private static let availabilityUpdateAnimation = Animation.easeInOut(duration: 0.22)
    private static let eventContentTransition = AnyTransition.opacity.combined(with: .scale(scale: 0.98))

    var body: some View {
        ZStack {
            if let event = viewModel.event {
                Form {
                    if let errorMessage = viewModel.errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Availability Map") {
                        if viewModel.people.isEmpty && !viewModel.isLoading {
                            Text("No availability responses yet.")
                                .foregroundStyle(.secondary)
                        }

                        EventAvailabilityGridView(
                            slots: viewModel.availabilityGridSlots,
                            people: viewModel.people,
                            availabilityByPerson: viewModel.availabilityByPerson,
                            availabilityCountByRawValue: viewModel.availabilityCountByRawValue,
                            highlightedSlotRawValues: viewModel.highlightedAvailabilitySlotRawValues
                        )

                        Button("Edit My Availability", systemImage: "pencil", action: viewModel.editAvailabilityButtonTapped)
                            .disabled(viewModel.availabilityGridSlots.isEmpty)
                    }

                    Section("Most Common Availability") {
                        if viewModel.people.isEmpty && !viewModel.isLoading {
                            Text("No availability responses yet.")
                                .foregroundStyle(.secondary)
                        } else if !viewModel.people.isEmpty && viewModel.availabilitySummaryRanges.isEmpty {
                            Text("No common availability yet.")
                                .foregroundStyle(.secondary)
                        } else if !viewModel.people.isEmpty {
                            ForEach(viewModel.availabilitySummaryRanges) { range in
                                availabilitySummaryRangeButton(for: range)
                            }
                        }
                    }

                    Section("Event") {
                        LabeledContent("Name", value: event.name)
                        LabeledContent("ID", value: event.id)
                        LabeledContent("Timezone", value: event.timezone)
                        LabeledContent("Created", value: viewModel.formattedDate(event.createdDate, timeZoneIdentifier: event.timezone))
                        LabeledContent("Event Ranges", value: "\(event.times.count)")
                        LabeledContent("Availability Slots", value: "\(viewModel.calendarSlotCount(for: event))")
                        LabeledContent("People", value: "\(viewModel.people.count)")
                    }
                    .textSelection(.enabled)

                    Section {
                        Button(action: { viewModel.copyEventLinkButtonTapped(for: event) }) {
                            Label(
                                viewModel.copiedEventLinkID == event.id ? "Copied Event Link" : "Copy Event Link",
                                systemImage: viewModel.copiedEventLinkID == event.id ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .accessibilityHint("Copies the Crab Fit event link to the clipboard")
                    }
                }
                .refreshable {
                    await viewModel.loadEvent(savedEvent: savedEvent, modelContext: modelContext)
                }
                .id(event.id)
                .transition(Self.eventContentTransition)
            } else if viewModel.isLoading {
                ProgressView("Loading Event")
                    .transition(Self.eventContentTransition)
            } else if let errorMessage = viewModel.errorMessage {
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
        .animation(Self.eventContentAnimation, value: viewModel.eventContentPhaseID(for: savedEvent))
        .navigationTitle(viewModel.event?.name ?? savedEvent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if viewModel.isLoading {
                    ProgressView()
                        .accessibilityLabel("Refreshing Event")
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise", action: refreshButtonTapped)
                }
            }
        }
        .sheet(isPresented: $viewModel.isShowingEditAvailabilitySheet) {
            if let event = viewModel.event {
                EditAvailabilitySheet(
                    event: event,
                    slots: viewModel.availabilityGridSlots,
                    context: viewModel.availabilityEditorContext,
                    slotDurationMinutes: viewModel.slotDurationMinutes,
                    displayTimeZoneIdentifier: viewModel.localTimeZoneIdentifier,
                    preloadedAvailability: viewModel.availabilityEditorPreloadState,
                    onSaved: availabilityEditorSaved
                )
            }
        }
        .task(id: savedEvent.eventID) {
            await viewModel.loadEvent(savedEvent: savedEvent, modelContext: modelContext)
        }
        .task(id: viewModel.copiedEventLinkID) {
            await viewModel.clearCopiedEventLinkAfterDelayIfNeeded()
        }
    }

    private func refreshButtonTapped() {
        Task {
            await viewModel.refresh(savedEvent: savedEvent, modelContext: modelContext)
        }
    }

    private func availabilityEditorSaved(_ updatedPerson: CrabFitPerson) {
        withAnimation(Self.availabilityUpdateAnimation) {
            viewModel.availabilityEditorSaved(updatedPerson)
        }
    }

    private func availabilitySummaryRangeButton(for range: AvailabilitySummaryRange) -> some View {
        let isSelected = viewModel.isAvailabilitySummaryRangeSelected(range)
        let rowBackground: Color? = isSelected ? Color.orange.opacity(0.22) : nil

        return Button {
            withAnimation(Self.availabilityUpdateAnimation) {
                viewModel.toggleAvailabilityRangeSelection(range)
            }
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
}
