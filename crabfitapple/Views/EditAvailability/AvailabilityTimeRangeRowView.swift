import SwiftUI

struct AvailabilityTimeRangeRowView: View {
    @Binding var range: AvailabilityEditRange

    let boundaries: [AvailabilityRangeBoundary]
    let timeZoneIdentifier: String

    @State private var selectionTarget: BoundarySelectionTarget?

    private enum BoundarySelectionTarget: String, Identifiable {
        case start
        case end

        var id: Self { self }

        var title: String {
            switch self {
            case .start:
                "From"
            case .end:
                "Until"
            }
        }
    }

    private var displayedStartBoundary: AvailabilityRangeBoundary? {
        boundary(id: range.startBoundaryID) ?? boundaries.first
    }

    private var displayedEndBoundary: AvailabilityRangeBoundary? {
        guard let startIndex else { return boundaries.dropFirst().first }

        if let endIndex = boundaries.firstIndex(where: { $0.id == range.endBoundaryID }),
           endIndex > startIndex {
            return boundaries[endIndex]
        }

        let fallbackIndex = boundaries.index(after: startIndex)
        guard boundaries.indices.contains(fallbackIndex) else { return nil }
        return boundaries[fallbackIndex]
    }

    private var startIndex: Int? {
        if let index = boundaries.firstIndex(where: { $0.id == range.startBoundaryID }) {
            return index
        }

        guard !boundaries.isEmpty else { return nil }
        return boundaries.startIndex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            boundaryButton(
                title: BoundarySelectionTarget.start.title,
                boundary: displayedStartBoundary,
                target: .start
            )
            .disabled(boundaries.count < 2)

            boundaryButton(
                title: BoundarySelectionTarget.end.title,
                boundary: displayedEndBoundary,
                target: .end
            )
            .disabled(displayedEndBoundary == nil)
        }
        .padding(.vertical, 4)
        .popover(item: $selectionTarget, arrowEdge: .trailing) { target in
            AvailabilityBoundaryPickerPopover(
                title: target.title,
                boundaries: selectableBoundaries(for: target),
                selectedBoundaryID: selectedBoundaryID(for: target),
                timeZoneIdentifier: timeZoneIdentifier
            ) { boundary in
                select(boundary, for: target)
                selectionTarget = nil
            }
        }
    }

    private func boundaryButton(
        title: String,
        boundary: AvailabilityRangeBoundary?,
        target: BoundarySelectionTarget
    ) -> some View {
        Button {
            selectionTarget = target
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .foregroundStyle(.primary)

                Spacer(minLength: 16)

                Text(boundary?.label ?? "Select")
                    .foregroundStyle(boundary == nil ? .secondary : .primary)
                    .multilineTextAlignment(.trailing)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func selectableBoundaries(for target: BoundarySelectionTarget) -> [AvailabilityRangeBoundary] {
        switch target {
        case .start:
            guard boundaries.count >= 2 else { return [] }
            return Array(boundaries.dropLast())
        case .end:
            guard let startIndex else { return Array(boundaries.dropFirst()) }
            let firstEndIndex = boundaries.index(after: startIndex)
            guard boundaries.indices.contains(firstEndIndex) else { return [] }
            return Array(boundaries[firstEndIndex...])
        }
    }

    private func selectedBoundaryID(for target: BoundarySelectionTarget) -> String {
        switch target {
        case .start:
            displayedStartBoundary?.id ?? range.startBoundaryID
        case .end:
            displayedEndBoundary?.id ?? range.endBoundaryID
        }
    }

    private func select(_ boundary: AvailabilityRangeBoundary, for target: BoundarySelectionTarget) {
        switch target {
        case .start:
            range.startBoundaryID = boundary.id
            ensureEndBoundaryIsAfterStartBoundary()
        case .end:
            range.endBoundaryID = boundary.id
        }
    }

    private func ensureEndBoundaryIsAfterStartBoundary() {
        guard let startIndex else { return }
        let firstEndIndex = boundaries.index(after: startIndex)
        guard boundaries.indices.contains(firstEndIndex) else { return }

        if let endIndex = boundaries.firstIndex(where: { $0.id == range.endBoundaryID }),
           endIndex > startIndex {
            return
        }

        range.endBoundaryID = boundaries[firstEndIndex].id
    }

    private func boundary(id: String) -> AvailabilityRangeBoundary? {
        boundaries.first { $0.id == id }
    }
}

private struct AvailabilityBoundaryPickerPopover: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let dayOptions: [AvailabilityBoundaryDayOption]
    let timeZoneIdentifier: String
    let onSelect: (AvailabilityRangeBoundary) -> Void

    @State private var selectedDayID: String
    @State private var selectedBoundaryID: String

    private var selectedDayBoundaries: [AvailabilityRangeBoundary] {
        dayOptions.first { $0.id == selectedDayID }?.boundaries ?? []
    }

    private var selectedBoundary: AvailabilityRangeBoundary? {
        selectedDayBoundaries.first { $0.id == selectedBoundaryID }
    }

    init(
        title: String,
        boundaries: [AvailabilityRangeBoundary],
        selectedBoundaryID: String,
        timeZoneIdentifier: String,
        onSelect: @escaping (AvailabilityRangeBoundary) -> Void
    ) {
        let dayOptions = Self.dayOptions(from: boundaries, timeZoneIdentifier: timeZoneIdentifier)
        let initialBoundary = boundaries.first { $0.id == selectedBoundaryID } ?? boundaries.first
        let initialDayID = initialBoundary.flatMap { boundary in
            dayOptions.first { dayOption in
                dayOption.boundaries.contains(where: { $0.id == boundary.id })
            }?.id
        } ?? dayOptions.first?.id ?? ""

        self.title = title
        self.dayOptions = dayOptions
        self.timeZoneIdentifier = timeZoneIdentifier
        self.onSelect = onSelect
        _selectedDayID = State(initialValue: initialDayID)
        _selectedBoundaryID = State(initialValue: initialBoundary?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Date", selection: $selectedDayID) {
                    ForEach(dayOptions) { option in
                        Text(option.label)
                            .tag(option.id)
                    }
                }

                Picker("Time", selection: $selectedBoundaryID) {
                    ForEach(selectedDayBoundaries) { boundary in
                        Text(timeLabel(for: boundary))
                            .tag(boundary.id)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 160)
                .clipped()

                Spacer(minLength: 0)
            }
            .padding()
            .frame(minWidth: 300, minHeight: 260)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        guard let selectedBoundary else { return }
                        onSelect(selectedBoundary)
                        dismiss()
                    }
                    .disabled(selectedBoundary == nil)
                }
            }
            .onChange(of: selectedDayID) {
                guard !selectedDayBoundaries.contains(where: { $0.id == selectedBoundaryID }) else { return }
                selectedBoundaryID = selectedDayBoundaries.first?.id ?? ""
            }
        }
        .presentationDetents([.medium])
    }

    private func timeLabel(for boundary: AvailabilityRangeBoundary) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(identifier: "UTC") ?? .current
        return formatter.string(from: boundary.date)
    }

    private static func dayOptions(
        from boundaries: [AvailabilityRangeBoundary],
        timeZoneIdentifier: String
    ) -> [AvailabilityBoundaryDayOption] {
        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(identifier: "UTC") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var options: [AvailabilityBoundaryDayOption] = []
        var optionIndexByID: [String: Int] = [:]

        for boundary in boundaries {
            let dayID = dayID(for: boundary, calendar: calendar)
            if let index = optionIndexByID[dayID] {
                options[index].boundaries.append(boundary)
            } else {
                optionIndexByID[dayID] = options.count
                options.append(AvailabilityBoundaryDayOption(
                    id: dayID,
                    label: dayLabel(for: boundary, timeZone: timeZone),
                    boundaries: [boundary]
                ))
            }
        }

        return options
    }

    private static func dayID(for boundary: AvailabilityRangeBoundary, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: boundary.date)

        if boundary.usesWeekdayLabel, let weekday = components.weekday {
            return "weekday-\(weekday)"
        }

        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func dayLabel(for boundary: AvailabilityRangeBoundary, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = boundary.usesWeekdayLabel ? "EEE" : "EEE, d MMM"
        formatter.timeZone = timeZone
        return formatter.string(from: boundary.date)
    }
}

private struct AvailabilityBoundaryDayOption: Identifiable {
    let id: String
    let label: String
    var boundaries: [AvailabilityRangeBoundary]
}
