import SwiftUI

struct AvailabilityCellView: View {
    let availableCount: Int
    let totalPeople: Int
    let isHighlighted: Bool

    private static let styleAnimation = Animation.easeInOut(duration: 0.22)
    private static let heatColorStops = [
        HeatColorStop(location: 0.00, red: 1.00, green: 0.91, blue: 0.62),
        HeatColorStop(location: 0.40, red: 0.96, green: 0.68, blue: 0.32),
        HeatColorStop(location: 0.75, red: 0.84, green: 0.38, blue: 0.20),
        HeatColorStop(location: 1.00, red: 0.62, green: 0.12, blue: 0.16)
    ]

    private struct HeatColorStop {
        let location: Double
        let red: Double
        let green: Double
        let blue: Double

        var color: Color {
            Color(red: red, green: green, blue: blue)
        }
    }

    private var availabilityRatio: Double {
        guard totalPeople > 0 else { return 0 }
        return min(max(Double(availableCount) / Double(totalPeople), 0), 1)
    }

    private var heatIntensity: Double {
        guard availableCount > 0 else { return 0 }
        return max(0.10, pow(availabilityRatio, 0.90))
    }

    private var backgroundOpacity: Double {
        guard availableCount > 0 else { return 1 }
        return 0.30 + (heatIntensity * 0.42)
    }

    private var backgroundStyle: Color {
        if isHighlighted {
            return .red.opacity(0.72)
        }

        guard availableCount > 0 else {
            return .secondary.opacity(0.08)
        }

        return Self.heatColor(for: heatIntensity).opacity(backgroundOpacity)
    }

    private var strokeStyle: Color {
        if isHighlighted {
            return .red
        }

        guard availableCount > 0 else {
            return .secondary.opacity(0.28)
        }

        return .secondary.opacity(0.46)
    }

    private var strokeWidth: CGFloat {
        if isHighlighted {
            return 3
        }

        return 0.5
    }

    private static func heatColor(for intensity: Double) -> Color {
        let clampedIntensity = min(max(intensity, 0), 1)

        guard let upperStop = heatColorStops.first(where: { $0.location >= clampedIntensity }) else {
            return heatColorStops[heatColorStops.count - 1].color
        }

        guard let lowerStop = heatColorStops.last(where: { $0.location <= clampedIntensity }),
              lowerStop.location != upperStop.location else {
            return upperStop.color
        }

        let progress = (clampedIntensity - lowerStop.location) / (upperStop.location - lowerStop.location)
        return Color(
            red: lowerStop.red + ((upperStop.red - lowerStop.red) * progress),
            green: lowerStop.green + ((upperStop.green - lowerStop.green) * progress),
            blue: lowerStop.blue + ((upperStop.blue - lowerStop.blue) * progress)
        )
    }

    var body: some View {
        Rectangle()
            .fill(backgroundStyle)
            .frame(width: 64, height: 12)
            .overlay {
                Rectangle()
                    .stroke(strokeStyle, lineWidth: strokeWidth)
            }
            .shadow(
                color: isHighlighted ? Color.red.opacity(0.28) : .clear,
                radius: isHighlighted ? 2 : 0,
                x: 0,
                y: 0
            )
            .animation(Self.styleAnimation, value: availableCount)
            .animation(Self.styleAnimation, value: totalPeople)
            .animation(Self.styleAnimation, value: isHighlighted)
            .accessibilityHidden(true)
    }
}
