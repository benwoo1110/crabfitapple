import Foundation
import SwiftData
import SwiftUI

struct AddEventSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = AddEventSheetViewModel()
    @FocusState private var isEventIDFieldFocused: Bool

    private static let eventEntryModeAnimation = Animation.easeInOut(duration: 0.2)

    private var eventEntryModeBinding: Binding<EventEntryMode> {
        Binding {
            viewModel.eventEntryMode
        } set: { newMode in
            withAnimation(Self.eventEntryModeAnimation) {
                viewModel.eventEntryMode = newMode
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch viewModel.eventEntryMode {
                case .existing:
                    existingEventSection
                case .create:
                    createEventSections
                }
            }
            .animation(Self.eventEntryModeAnimation, value: viewModel.eventEntryMode)
            .navigationTitle(viewModel.eventEntryMode.navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .disabled(viewModel.isSaving)
                }

                ToolbarItem(placement: .principal) {
                    Picker("Event Action", selection: eventEntryModeBinding) {
                        ForEach(EventEntryMode.allCases) { mode in
                            Text(mode.title)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(viewModel.isSaving)
                    .frame(maxWidth: 220)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSaving {
                        ProgressView()
                            .accessibilityLabel(viewModel.progressAccessibilityLabel)
                    } else {
                        Button(viewModel.primaryButtonTitle, action: primaryButtonTapped)
                            .buttonStyle(.borderedProminent)
                            .disabled(!viewModel.canSubmit)
                    }
                }
            }
            .alert("Could Not Save Event", isPresented: $viewModel.isShowingError) {
            } message: {
                Text(viewModel.errorMessage)
            }
            .task(prepareTextInput)
            .onChange(of: viewModel.eventEntryMode) { _, newMode in
                isEventIDFieldFocused = newMode == .existing
            }
        }
    }

    private var existingEventSection: some View {
        Section {
            TextField("Event ID or URL", text: $viewModel.eventID)
#if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
#endif
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isEventIDFieldFocused)
                .disabled(viewModel.isSaving)
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
            TextField("Name", text: $viewModel.newEventName)
#if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.sentences)
#endif
                .disabled(viewModel.isSaving)
        } header: {
            Text("Event Name")
        } footer: {
            Text("Leave blank to generate one.")
        }

        Section {
            Picker("Date Type", selection: $viewModel.newEventDateMode) {
                ForEach(NewEventDateMode.allCases) { mode in
                    Text(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isSaving)

            switch viewModel.newEventDateMode {
            case .specificDates:
                MultiDatePicker("Specific Dates", selection: $viewModel.selectedSpecificDateComponents)
                    .disabled(viewModel.isSaving)
            case .weekdays:
                ForEach(EventWeekday.allCases) { weekday in
                    Toggle(weekday.title, isOn: weekdaySelectionBinding(for: weekday))
                        .disabled(viewModel.isSaving)
                }
            }
        } header: {
            Text("Dates")
        } footer: {
            Text(viewModel.dateFooterText)
        }

        Section {
            Picker("Start", selection: $viewModel.newEventStartHour) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(AddEventSheetViewModel.formattedHour(hour))
                        .tag(hour)
                }
            }
            .disabled(viewModel.isSaving)

            Picker("End", selection: $viewModel.newEventEndHour) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(AddEventSheetViewModel.formattedHour(hour))
                        .tag(hour)
                }
            }
            .disabled(viewModel.isSaving)
        } header: {
            Text("Times")
        } footer: {
            Text(viewModel.timeFooterText)
        }

        Section {
            Picker("Timezone", selection: $viewModel.newEventTimeZoneID) {
                ForEach(AddEventSheetViewModel.timeZoneIdentifiers, id: \.self) { identifier in
                    Text(identifier)
                        .tag(identifier)
                }
            }
            .disabled(viewModel.isSaving)
        }
    }

    private func cancel() {
        dismiss()
    }

    private func prepareTextInput() async {
        await viewModel.prepareTextInput()
        await Task.yield()
        isEventIDFieldFocused = viewModel.eventEntryMode == .existing
    }

    private func primaryButtonTapped() {
        Task {
            if await viewModel.primaryButtonTapped(modelContext: modelContext) {
                dismiss()
            }
        }
    }

    private func weekdaySelectionBinding(for weekday: EventWeekday) -> Binding<Bool> {
        Binding {
            viewModel.isWeekdaySelected(weekday)
        } set: { isSelected in
            viewModel.setWeekday(weekday, isSelected: isSelected)
        }
    }
}

#Preview {
    AddEventSheet()
        .modelContainer(for: SavedEvent.self, inMemory: true)
}
