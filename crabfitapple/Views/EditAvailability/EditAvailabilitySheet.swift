import SwiftUI

struct EditAvailabilitySheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSaved: (CrabFitPerson) -> Void

    @State private var viewModel: EditAvailabilitySheetViewModel

    private static let selectionStyleAnimation = Animation.easeInOut(duration: 0.22)

    init(
        event: CrabFitEvent,
        slots: [AvailabilityGridSlot],
        context: AvailabilityEditorContext,
        slotDurationMinutes: Int,
        displayTimeZoneIdentifier: String,
        preloadedAvailability: AvailabilityEditorPreloadState = .loading,
        onSaved: @escaping (CrabFitPerson) -> Void
    ) {
        self.onSaved = onSaved
        _viewModel = State(initialValue: EditAvailabilitySheetViewModel(
            event: event,
            slots: slots,
            context: context,
            slotDurationMinutes: slotDurationMinutes,
            displayTimeZoneIdentifier: displayTimeZoneIdentifier,
            preloadedAvailability: preloadedAvailability
        ))
    }

    private var selectedRawValuesBinding: Binding<Set<String>> {
        Binding {
            viewModel.selectedRawValues
        } set: { rawValues in
            viewModel.setAvailability(rawValues: rawValues)
        }
    }

    private var selectionStyleBinding: Binding<AvailabilitySelectionStyle> {
        Binding {
            viewModel.selectionStyle
        } set: { newStyle in
            withAnimation(Self.selectionStyleAnimation) {
                viewModel.setSelectionStyle(newStyle)
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            NavigationStack {
                Form {
                    switch viewModel.loadState {
                    case .loading:
                        Section {
                            HStack(spacing: 12) {
                                ProgressView()

                                Text("Loading your availability")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                    case .missingProfile:
                        Section {
                            Label("Set your name in Settings before editing availability.", systemImage: "person.crop.circle.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                        }
                    case .failed(let message):
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)

                            Button("Retry", systemImage: "arrow.clockwise", action: retryLoadingAvailability)
                        }
                    case .ready:
                        switch viewModel.selectionStyle {
                        case .ranges:
                            Section {
                                if viewModel.ranges.isEmpty {
                                    Label("No time ranges selected", systemImage: "clock.badge.exclamationmark")
                                        .foregroundStyle(.secondary)
                                }

                                ForEach($viewModel.ranges) { rangeBinding in
                                    AvailabilityTimeRangeRowView(
                                        range: rangeBinding,
                                        boundaries: viewModel.boundaries,
                                        timeZoneIdentifier: viewModel.displayTimeZoneIdentifier
                                    )
                                    .disabled(viewModel.isSaving || viewModel.isGeneratingAvailability)
                                }
                                .onDelete(perform: viewModel.deleteRanges)

                                Button("Add Time Range", systemImage: "plus", action: viewModel.addRange)
                                    .disabled(!viewModel.canAddRange)
                            } header: {
                                Text("Time Ranges")
                            } footer: {
                                Text(viewModel.timeRangeSummary)
                            }
                        case .grid:
                            Section {
                                AvailabilitySelectionGridView(
                                    selectedRawValues: selectedRawValuesBinding,
                                    slots: viewModel.slots,
                                    isDisabled: viewModel.isSaving || viewModel.isGeneratingAvailability,
                                    preferredViewportHeight: viewModel.gridViewportHeight(for: geometry.size.height)
                                )
                                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                            } header: {
                                Text("Grid")
                            } footer: {
                                Text(viewModel.timeRangeSummary)
                            }
                        }

                        if !viewModel.ranges.isEmpty {
                            Section {
                                Button("Clear All", systemImage: "xmark.circle", role: .destructive, action: viewModel.clearRanges)
                                    .foregroundStyle(.red)
                                    .disabled(viewModel.isSaving || viewModel.isGeneratingAvailability)
                            }
                        }
                    }
                }
                .animation(Self.selectionStyleAnimation, value: viewModel.selectionStyle)
                .scrollDismissesKeyboard(.immediately)
                .safeAreaBar(edge: .bottom) {
                    if viewModel.isReady {
                        AvailabilityPromptBarView(
                            isInputDisabled: viewModel.isAvailabilityPromptInputDisabled,
                            isGenerating: viewModel.isGeneratingAvailability,
                            clearTrigger: viewModel.availabilityPromptClearTrigger,
                            submitAction: availabilityPromptSubmitted
                        )
                    }
                }
                .navigationTitle("My Availability")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark", action: cancel)
                            .accessibilityLabel("Cancel")
                            .disabled(viewModel.isSaving || viewModel.isGeneratingAvailability)
                    }

                    if viewModel.isReady {
                        ToolbarItem(placement: .principal) {
                            Picker("Selection Style", selection: selectionStyleBinding) {
                                ForEach(AvailabilitySelectionStyle.allCases) { style in
                                    Text(style.title)
                                        .tag(style)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(viewModel.isSaving || viewModel.isGeneratingAvailability)
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        if viewModel.isSaving {
                            ProgressView()
                                .accessibilityLabel("Saving Availability")
                        } else {
                            Button("Save", systemImage: "checkmark", action: saveButtonTapped)
                                .buttonStyle(.borderedProminent)
                                .accessibilityLabel("Save")
                                .disabled(!viewModel.canSave)
                        }
                    }
                }
                .alert("Could Not Update Availability", isPresented: $viewModel.isShowingError) {
                } message: {
                    Text(viewModel.errorMessage)
                }
                .onChange(of: viewModel.ranges) {
                    viewModel.syncSelectedRawValuesFromRanges()
                }
                .task {
                    let shouldPrewarmAfterTask = viewModel.loadState != .loading
                    await viewModel.loadAvailabilityIfNeeded()
                    if shouldPrewarmAfterTask {
                        viewModel.prewarmAvailabilityParserIfReady()
                    }
                }
            }
            .interactiveDismissDisabled(viewModel.isInteractiveDismissDisabled)
            .presentationContentInteraction(.scrolls)
        }
    }

    private func cancel() {
        dismiss()
    }

    private func retryLoadingAvailability() {
        Task {
            await viewModel.retryLoadingAvailability()
        }
    }

    private func availabilityPromptSubmitted(_ prompt: String) {
        Task {
            await viewModel.applyAvailabilityPrompt(prompt)
        }
    }

    private func saveButtonTapped() {
        Task {
            guard let updatedPerson = await viewModel.saveAvailability() else { return }
            onSaved(updatedPerson)
            dismiss()
        }
    }
}
