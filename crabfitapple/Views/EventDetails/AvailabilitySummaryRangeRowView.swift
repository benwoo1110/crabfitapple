import SwiftUI

struct AvailabilitySummaryRangeRowView: View {
    let range: AvailabilitySummaryRange
    let isSelected: Bool

    private let iconColumnWidth: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "clock")
                    .imageScale(.medium)
                    .foregroundStyle(isSelected ? .orange : .orange)
                    .frame(width: iconColumnWidth, alignment: .center)
                    .accessibilityHidden(true)

                Text(range.detailLabel)
                    .font(.body)
                    .fontWeight(isSelected ? .bold : .regular)
                    .foregroundStyle(isSelected ? .orange : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 6)

                availabilityBadge
            }

            if range.hasUnavailablePeople {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "person.slash")
                        .imageScale(.small)
                        .frame(width: iconColumnWidth, alignment: .center)
                        .accessibilityHidden(true)

                    Text(range.unavailableText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityLabel("Not available: \(range.unavailableText)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private var availabilityBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: range.hasUnavailablePeople ? "person.2.fill" : "checkmark.circle.fill")
                .imageScale(.small)
                .accessibilityHidden(true)

            Text(range.compactAvailabilityText)
                .monospacedDigit()
                .bold()
        }
        .font(.subheadline)
        .foregroundStyle(range.hasUnavailablePeople ? Color.primary : Color.green)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(badgeBackgroundStyle)
        }
        .fixedSize()
        .accessibilityLabel(range.availabilityText)
    }

    private var badgeBackgroundStyle: Color {
        range.hasUnavailablePeople ? Color.orange.opacity(0.14) : Color.green.opacity(0.14)
    }
}
