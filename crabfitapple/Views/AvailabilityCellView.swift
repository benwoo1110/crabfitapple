import SwiftUI

struct AvailabilityCellView: View {
    let availableCount: Int
    let totalPeople: Int
    let isHighlighted: Bool

    private static let styleAnimation = Animation.easeInOut(duration: 0.22)

    private var backgroundStyle: Color {
        if isHighlighted {
            return Color.red.opacity(0.72)
        }

        guard totalPeople > 0, availableCount > 0 else {
            return Color.secondary.opacity(0.06)
        }

        let availabilityRatio = Double(availableCount) / Double(totalPeople)
        return Color.orange.opacity(0.22 + (availabilityRatio * 0.68))
    }

    private var strokeStyle: Color {
        isHighlighted ? Color.red : Color.secondary.opacity(0.2)
    }

    private var strokeWidth: CGFloat {
        isHighlighted ? 3 : 0.5
    }

    var body: some View {
        Rectangle()
            .fill(backgroundStyle)
            .frame(width: 64, height: 12)
            .overlay {
                Rectangle()
                    .stroke(strokeStyle, lineWidth: strokeWidth)
            }
            .shadow(color: isHighlighted ? Color.red.opacity(0.35) : .clear, radius: 2, x: 0, y: 0)
            .animation(Self.styleAnimation, value: availableCount)
            .animation(Self.styleAnimation, value: totalPeople)
            .animation(Self.styleAnimation, value: isHighlighted)
            .accessibilityHidden(true)
    }
}
