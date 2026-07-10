import SwiftUI

struct AvailabilityEditorPreloadedAvailability: Equatable, Sendable {
    let profileName: String
    let profilePassword: String?
    let rawValues: [String]
    let ranges: [AvailabilityEditRange]
    let selectedRawValues: Set<String>

    init(
        profileName: String,
        profilePassword: String?,
        rawValues: [String],
        context: AvailabilityEditorContext
    ) {
        let selection = context.availabilitySelection(from: rawValues)

        self.profileName = profileName
        self.profilePassword = profilePassword
        self.rawValues = rawValues
        ranges = selection.ranges
        selectedRawValues = selection.selectedRawValues
    }
}

struct AvailabilityEditorSelection: Equatable, Sendable {
    let ranges: [AvailabilityEditRange]
    let selectedRawValues: Set<String>
}

enum AvailabilityEditorPreloadState: Equatable, Sendable {
    case loading
    case ready(AvailabilityEditorPreloadedAvailability)
    case missingProfile
    case failed(String)
}

struct EditAvailabilitySheet: View {
    @Environment(\.dismiss) private var dismiss

    let event: CrabFitEvent
    let slots: [AvailabilityGridSlot]
    let slotDurationMinutes: Int
    let displayTimeZoneIdentifier: String
    let onSaved: (CrabFitPerson) -> Void

    @State private var profileName = ""
    @State private var profilePassword: String?
    @State private var ranges: [AvailabilityEditRange] = []
    @State private var selectedRawValues: Set<String> = []
    @State private var selectionStyle = AvailabilitySelectionStyle.ranges
    @State private var loadState = LoadState.loading
    @State private var isSaving = false
    @State private var isGeneratingAvailability = false
    @State private var availabilityPromptClearTrigger = 0
    @State private var isShowingError = false
    @State private var errorMessage = ""
    @State private var naturalLanguageAvailabilityParser = NaturalLanguageAvailabilityParser()

    private let context: AvailabilityEditorContext
    private let api = CrabFitApi()

    private static let maximumInteractiveRangeRows = 6
    private static let selectionStyleAnimation = Animation.easeInOut(duration: 0.22)

    private enum LoadState: Equatable {
        case loading
        case ready
        case missingProfile
        case failed(String)
    }

    private enum AvailabilitySelectionStyle: CaseIterable, Identifiable {
        case ranges
        case grid

        var id: Self { self }

        var title: String {
            switch self {
            case .ranges:
                "Ranges"
            case .grid:
                "Grid"
            }
        }
    }

    private struct PreparedAvailabilityState {
        let profileName: String
        let profilePassword: String?
        let ranges: [AvailabilityEditRange]
        let selectedRawValues: Set<String>
        let selectionStyle: AvailabilitySelectionStyle
        let loadState: LoadState
    }

    init(
        event: CrabFitEvent,
        slots: [AvailabilityGridSlot],
        context: AvailabilityEditorContext,
        slotDurationMinutes: Int,
        displayTimeZoneIdentifier: String,
        preloadedAvailability: AvailabilityEditorPreloadState = .loading,
        onSaved: @escaping (CrabFitPerson) -> Void
    ) {
        self.event = event
        self.slots = slots
        self.slotDurationMinutes = slotDurationMinutes
        self.displayTimeZoneIdentifier = displayTimeZoneIdentifier
        self.onSaved = onSaved
        self.context = context

        let preparedState = Self.preparedState(from: preloadedAvailability)
        _profileName = State(initialValue: preparedState.profileName)
        _profilePassword = State(initialValue: preparedState.profilePassword)
        _ranges = State(initialValue: preparedState.ranges)
        _selectedRawValues = State(initialValue: preparedState.selectedRawValues)
        _selectionStyle = State(initialValue: preparedState.selectionStyle)
        _loadState = State(initialValue: preparedState.loadState)
    }

    private static func preparedState(from preloadState: AvailabilityEditorPreloadState) -> PreparedAvailabilityState {
        switch preloadState {
        case .loading:
            return PreparedAvailabilityState(
                profileName: "",
                profilePassword: nil,
                ranges: [],
                selectedRawValues: [],
                selectionStyle: .ranges,
                loadState: .loading
            )
        case .ready(let availability):
            return PreparedAvailabilityState(
                profileName: availability.profileName,
                profilePassword: availability.profilePassword,
                ranges: availability.ranges,
                selectedRawValues: availability.selectedRawValues,
                selectionStyle: availability.ranges.count > Self.maximumInteractiveRangeRows ? .grid : .ranges,
                loadState: .ready
            )
        case .missingProfile:
            return PreparedAvailabilityState(
                profileName: "",
                profilePassword: nil,
                ranges: [],
                selectedRawValues: [],
                selectionStyle: .ranges,
                loadState: .missingProfile
            )
        case .failed(let message):
            return PreparedAvailabilityState(
                profileName: "",
                profilePassword: nil,
                ranges: [],
                selectedRawValues: [],
                selectionStyle: .ranges,
                loadState: .failed(message)
            )
        }
    }

    private var boundaries: [AvailabilityRangeBoundary] {
        context.boundaries
    }

    private var rangeSlots: [AvailabilityRangeSlot] {
        context.rangeSlots
    }

    private var selectedRawValuesBinding: Binding<Set<String>> {
        Binding {
            selectedRawValues
        } set: { rawValues in
            setAvailability(rawValues: rawValues)
        }
    }

    private var selectionStyleBinding: Binding<AvailabilitySelectionStyle> {
        Binding {
            selectionStyle
        } set: { newStyle in
            guard selectionStyle != newStyle else { return }

            withAnimation(Self.selectionStyleAnimation) {
                selectionStyle = newStyle
            }
        }
    }

    private var isReady: Bool {
        loadState == .ready
    }

    private var canAddRange: Bool {
        isReady && boundaries.count >= 2 && !isSaving && !isGeneratingAvailability
    }

    private var canSave: Bool {
        isReady && !profileName.isEmpty && !rangeSlots.isEmpty && !isSaving && !isGeneratingAvailability
    }

    private var isAvailabilityPromptInputDisabled: Bool {
        !isReady || boundaries.count < 2 || isSaving || isGeneratingAvailability
    }

    private var isInteractiveDismissDisabled: Bool {
        selectionStyle == .grid || isSaving || isGeneratingAvailability
    }

    private var timeRangeSummary: String {
        guard !ranges.isEmpty else {
            return "No availability selected."
        }

        let selectedMinutes = selectedRawValues.count * slotDurationMinutes
        let rangeText = ranges.count == 1 ? "1 range" : "\(ranges.count) ranges"
        return "\(rangeText), \(formattedDuration(minutes: selectedMinutes)) selected."
    }

    private func gridViewportHeight(for availableHeight: CGFloat) -> CGFloat {
        max(availableHeight * 0.75, 240)
    }

    var body: some View {
        GeometryReader { geometry in
            NavigationStack {
                Form {
                switch loadState {
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
                    switch selectionStyle {
                    case .ranges:
                        Section {
                            if ranges.isEmpty {
                                Label("No time ranges selected", systemImage: "clock.badge.exclamationmark")
                                    .foregroundStyle(.secondary)
                            }

                            ForEach($ranges) { rangeBinding in
                                AvailabilityTimeRangeRowView(
                                    range: rangeBinding,
                                    boundaries: boundaries,
                                    timeZoneIdentifier: displayTimeZoneIdentifier
                                )
                                .disabled(isSaving || isGeneratingAvailability)
                            }
                            .onDelete(perform: deleteRanges)

                            Button("Add Time Range", systemImage: "plus", action: addRange)
                                .disabled(!canAddRange)
                        } header: {
                            Text("Time Ranges")
                        } footer: {
                            Text(timeRangeSummary)
                        }
                    case .grid:
                        Section {
                            AvailabilitySelectionGridView(
                                selectedRawValues: selectedRawValuesBinding,
                                slots: slots,
                                isDisabled: isSaving || isGeneratingAvailability,
                                preferredViewportHeight: gridViewportHeight(for: geometry.size.height)
                            )
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        } header: {
                            Text("Grid")
                        } footer: {
                            Text(timeRangeSummary)
                        }
                    }

                    if !ranges.isEmpty {
                        Section {
                            Button("Clear All", systemImage: "xmark.circle", role: .destructive, action: clearRanges)
                                .foregroundStyle(.red)
                                .disabled(isSaving || isGeneratingAvailability)
                        }
                    }
                }
            }
            .animation(Self.selectionStyleAnimation, value: selectionStyle)
            .scrollDismissesKeyboard(.interactively)
            .availabilityPromptBar {
                if isReady {
                    AvailabilityPromptBarView(
                        isInputDisabled: isAvailabilityPromptInputDisabled,
                        isGenerating: isGeneratingAvailability,
                        clearTrigger: availabilityPromptClearTrigger,
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
                        .disabled(isSaving || isGeneratingAvailability)
                }

                if isReady {
                    ToolbarItem(placement: .principal) {
                        Picker("Selection Style", selection: selectionStyleBinding) {
                            ForEach(AvailabilitySelectionStyle.allCases) { style in
                                Text(style.title)
                                    .tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isSaving || isGeneratingAvailability)
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .accessibilityLabel("Saving Availability")
                    } else {
                        Button("Save", systemImage: "checkmark", action: saveButtonTapped)
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("Save")
                            .disabled(!canSave)
                    }
                }
            }
            .alert("Could Not Update Availability", isPresented: $isShowingError) {
            } message: {
                Text(errorMessage)
            }
            .onChange(of: ranges) {
                syncSelectedRawValuesFromRanges()
            }
            .task {
                let shouldPrewarmAfterTask = loadState != .loading
                await loadAvailabilityIfNeeded()
                if shouldPrewarmAfterTask {
                    prewarmAvailabilityParserIfReady()
                }
            }
        }
        .interactiveDismissDisabled(isInteractiveDismissDisabled)
        .presentationContentInteraction(.scrolls)
        }
    }

    private func cancel() {
        dismiss()
    }

    private func retryLoadingAvailability() {
        Task {
            await loadAvailability()
        }
    }

    private func loadAvailabilityIfNeeded() async {
        guard loadState == .loading else { return }

        await loadAvailability()
    }

    private func availabilityPromptSubmitted(_ prompt: String) {
        guard isReady && boundaries.count >= 2 && !isSaving && !isGeneratingAvailability else { return }

        Task {
            await applyAvailabilityPrompt(prompt)
        }
    }

    private func applyAvailabilityPrompt(_ prompt: String) async {
        isGeneratingAvailability = true
        defer { isGeneratingAvailability = false }

        let currentBoundaries = boundaries

        do {
            let generatedRanges = try await naturalLanguageAvailabilityParser.ranges(
                from: prompt,
                boundaries: currentBoundaries,
                rangeSlots: context.rangeSlots,
                timeZoneIdentifier: displayTimeZoneIdentifier
            )

            guard !Task.isCancelled else { return }
            applyRanges(generatedRanges)
            availabilityPromptClearTrigger += 1
        } catch {
            show(error)
        }
    }

    private func loadAvailability() async {
        loadState = .loading
        clearAvailabilitySelection()

        do {
            guard let credentials = try AvailabilityCredentialsStore.credentialsForRequest() else {
                profileName = ""
                profilePassword = nil
                loadState = .missingProfile
                return
            }

            profileName = credentials.name
            profilePassword = credentials.password

            do {
                let person = try await api.person(
                    eventID: event.id,
                    name: credentials.name,
                    password: credentials.password
                )

                let selection = await detachedAvailabilitySelection(from: person.availability, context: context)

                guard !Task.isCancelled else { return }
                applyLoadedAvailability(
                    profileName: credentials.name,
                    profilePassword: credentials.password,
                    selection: selection
                )
            } catch {
                guard !Task.isCancelled else { return }

                if isPersonNotFound(error) {
                    applyLoadedAvailability(
                        profileName: credentials.name,
                        profilePassword: credentials.password,
                        selection: AvailabilityEditorSelection(ranges: [], selectedRawValues: [])
                    )
                } else {
                    loadState = .failed(error.localizedDescription)
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            profileName = ""
            profilePassword = nil
            loadState = .failed(error.localizedDescription)
        }
    }

    private func applyLoadedAvailability(
        profileName: String,
        profilePassword: String?,
        selection: AvailabilityEditorSelection
    ) {
        self.profileName = profileName
        self.profilePassword = profilePassword
        applySelection(selection)
        loadState = .ready
        prewarmAvailabilityParserIfReady()
    }

    private func prewarmAvailabilityParserIfReady() {
        guard boundaries.count >= 2, !context.rangeSlots.isEmpty else { return }

        naturalLanguageAvailabilityParser.prewarm(
            boundaries: boundaries,
            timeZoneIdentifier: displayTimeZoneIdentifier
        )
    }

    private func saveButtonTapped() {
        guard canSave else { return }

        Task {
            await saveAvailability()
        }
    }

    private func saveAvailability() async {
        guard canSave else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            let updatedPerson = try await api.updatePerson(
                eventID: event.id,
                name: profileName,
                availability: CrabFitTimeSlot.sortedRawValues(Array(selectedRawValues)),
                password: profilePassword
            )

            onSaved(updatedPerson)
            dismiss()
        } catch {
            show(error)
        }
    }

    private func availabilityRanges(from rawValues: [String]) -> [AvailabilityEditRange] {
        context.availabilityRanges(from: rawValues)
    }

    private func rawValues(from ranges: [AvailabilityEditRange]) -> [String] {
        context.rawValues(from: ranges)
    }

    private func addRange() {
        guard boundaries.count >= 2 else { return }

        let startIndex: Int
        if let lastRange = ranges.last,
           let lastEndIndex = boundaries.firstIndex(where: { $0.id == lastRange.endBoundaryID }),
           lastEndIndex < boundaries.index(before: boundaries.endIndex) {
            startIndex = lastEndIndex
        } else {
            startIndex = boundaries.startIndex
        }

        let endIndex = boundaries.index(after: startIndex)
        ranges.append(AvailabilityEditRange(
            startBoundaryID: boundaries[startIndex].id,
            endBoundaryID: boundaries[endIndex].id
        ))
        syncSelectedRawValuesFromRanges()
    }

    private func deleteRanges(at offsets: IndexSet) {
        ranges.remove(atOffsets: offsets)
        syncSelectedRawValuesFromRanges()
    }

    private func clearRanges() {
        clearAvailabilitySelection()
    }

    private func clearAvailabilitySelection() {
        ranges = []
        selectedRawValues = []
    }

    private func setAvailability(rawValues: Set<String>) {
        applySelection(context.availabilitySelection(from: Array(rawValues)))
    }

    private func applyRanges(_ newRanges: [AvailabilityEditRange]) {
        if ranges != newRanges {
            ranges = newRanges
        }

        syncSelectedRawValuesFromRanges()
    }

    private func applySelection(_ selection: AvailabilityEditorSelection) {
        if ranges != selection.ranges {
            ranges = selection.ranges
        }

        if selectedRawValues != selection.selectedRawValues {
            selectedRawValues = selection.selectedRawValues
        }
    }

    private func syncSelectedRawValuesFromRanges() {
        let rawValues = context.rawValueSet(from: ranges)
        guard selectedRawValues != rawValues else { return }
        selectedRawValues = rawValues
    }

    private func formattedDuration(minutes: Int) -> String {
        let hours = minutes / 60
        let remainingMinutes = minutes % 60

        if hours == 0 {
            return "\(remainingMinutes) min"
        }

        if remainingMinutes == 0 {
            return hours == 1 ? "1 hr" : "\(hours) hr"
        }

        return "\(hours) hr \(remainingMinutes) min"
    }

    private func isPersonNotFound(_ error: Error) -> Bool {
        guard case CrabFitApiError.unexpectedStatusCode(404) = error else {
            return false
        }

        return true
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}

private func detachedAvailabilitySelection(
    from rawValues: [String],
    context: AvailabilityEditorContext
) async -> AvailabilityEditorSelection {
    await Task.detached(priority: .userInitiated) {
        context.availabilitySelection(from: rawValues)
    }.value
}

struct AvailabilityEditorContext: Equatable, Sendable {
    let boundaries: [AvailabilityRangeBoundary]
    let rangeSlots: [AvailabilityRangeSlot]

    private let boundaryByID: [String: AvailabilityRangeBoundary]
    private let rangeSlotByRawValue: [String: AvailabilityRangeSlot]
    private let rangeSlotStartSortValues: [TimeInterval]

    static let empty = AvailabilityEditorContext(boundaries: [], rangeSlots: [])

    private init(boundaries: [AvailabilityRangeBoundary], rangeSlots: [AvailabilityRangeSlot]) {
        self.boundaries = boundaries
        self.rangeSlots = rangeSlots
        boundaryByID = Dictionary(uniqueKeysWithValues: boundaries.map { ($0.id, $0) })
        rangeSlotByRawValue = Dictionary(uniqueKeysWithValues: rangeSlots.map { ($0.rawValue, $0) })
        rangeSlotStartSortValues = rangeSlots.map(\.startSortValue)
    }

    init(slots: [AvailabilityGridSlot], durationMinutes: Int, timeZoneIdentifier: String) {
        let rangeSlots = AvailabilityRangeSlot.slots(from: slots, durationMinutes: durationMinutes)
        self.rangeSlots = rangeSlots
        rangeSlotByRawValue = Dictionary(uniqueKeysWithValues: rangeSlots.map { ($0.rawValue, $0) })
        rangeSlotStartSortValues = rangeSlots.map(\.startSortValue)

        var boundaryByID: [String: AvailabilityRangeBoundary] = [:]
        for slot in rangeSlots {
            let startBoundary = AvailabilityRangeBoundary(
                date: slot.startDate,
                sortValue: slot.startSortValue,
                timeZoneIdentifier: timeZoneIdentifier,
                usesWeekdayLabel: slot.usesWeekdayLabel
            )
            let endBoundary = AvailabilityRangeBoundary(
                date: slot.endDate,
                sortValue: slot.endSortValue,
                timeZoneIdentifier: timeZoneIdentifier,
                usesWeekdayLabel: slot.usesWeekdayLabel
            )

            boundaryByID[startBoundary.id] = startBoundary
            boundaryByID[endBoundary.id] = endBoundary
        }

        let boundaries = boundaryByID.values.sorted { firstBoundary, secondBoundary in
            firstBoundary.sortValue < secondBoundary.sortValue
        }
        self.boundaries = boundaries
        self.boundaryByID = Dictionary(uniqueKeysWithValues: boundaries.map { ($0.id, $0) })
    }

    nonisolated func availabilityRanges(from rawValues: [String]) -> [AvailabilityEditRange] {
        availabilitySelection(from: rawValues).ranges
    }

    nonisolated func availabilitySelection(from rawValues: [String]) -> AvailabilityEditorSelection {
        var selectedRawValues = Set<String>()
        selectedRawValues.reserveCapacity(rawValues.count)

        var availableSlots: [AvailabilityRangeSlot] = []
        availableSlots.reserveCapacity(rawValues.count)

        for rawValue in rawValues {
            guard let slot = rangeSlotByRawValue[rawValue],
                  selectedRawValues.insert(rawValue).inserted else {
                continue
            }

            availableSlots.append(slot)
        }

        availableSlots.sort { firstSlot, secondSlot in
            firstSlot.startSortValue < secondSlot.startSortValue
        }

        guard let firstSlot = availableSlots.first else {
            return AvailabilityEditorSelection(ranges: [], selectedRawValues: [])
        }

        var ranges: [AvailabilityEditRange] = []
        var rangeStartSlot = firstSlot
        var previousSlot = firstSlot

        for slot in availableSlots.dropFirst() {
            if areSlotsContinuous(previousSlot, slot) {
                previousSlot = slot
            } else {
                ranges.append(editRange(from: rangeStartSlot, through: previousSlot))
                rangeStartSlot = slot
                previousSlot = slot
            }
        }

        ranges.append(editRange(from: rangeStartSlot, through: previousSlot))
        return AvailabilityEditorSelection(ranges: ranges, selectedRawValues: selectedRawValues)
    }

    nonisolated func rawValues(from ranges: [AvailabilityEditRange]) -> [String] {
        let selectedRawValues = rawValueSet(from: ranges)
        return rangeSlots.compactMap { slot in
            selectedRawValues.contains(slot.rawValue) ? slot.rawValue : nil
        }
    }

    nonisolated func rawValueSet(from ranges: [AvailabilityEditRange]) -> Set<String> {
        var rawValues = Set<String>()

        for range in ranges {
            guard let startBoundary = boundaryByID[range.startBoundaryID],
                  let endBoundary = boundaryByID[range.endBoundaryID],
                  startBoundary.sortValue < endBoundary.sortValue else {
                continue
            }

            let startIndex = lowerBound(for: startBoundary.sortValue)
            let endIndex = lowerBound(for: endBoundary.sortValue)
            guard startIndex < endIndex else { continue }

            for slot in rangeSlots[startIndex..<endIndex] {
                rawValues.insert(slot.rawValue)
            }
        }

        return rawValues
    }

    private nonisolated func editRange(from startSlot: AvailabilityRangeSlot, through endSlot: AvailabilityRangeSlot) -> AvailabilityEditRange {
        AvailabilityEditRange(
            startBoundaryID: startSlot.startBoundaryID,
            endBoundaryID: endSlot.endBoundaryID
        )
    }

    private nonisolated func areSlotsContinuous(_ firstSlot: AvailabilityRangeSlot, _ secondSlot: AvailabilityRangeSlot) -> Bool {
        abs(secondSlot.startSortValue - firstSlot.endSortValue) < 0.5
    }

    private nonisolated func lowerBound(for sortValue: TimeInterval) -> Int {
        var lowerIndex = rangeSlotStartSortValues.startIndex
        var upperIndex = rangeSlotStartSortValues.endIndex

        while lowerIndex < upperIndex {
            let middleIndex = lowerIndex + (upperIndex - lowerIndex) / 2
            if rangeSlotStartSortValues[middleIndex] < sortValue {
                lowerIndex = middleIndex + 1
            } else {
                upperIndex = middleIndex
            }
        }

        return lowerIndex
    }
}

private extension View {
    func availabilityPromptBar<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        safeAreaBar(edge: .bottom, spacing: 0, content: content)
    }
}
