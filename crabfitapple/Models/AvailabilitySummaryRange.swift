import Foundation

struct AvailabilitySummaryRange: Equatable, Identifiable, Sendable {
    let rawValues: [String]
    let detailLabel: String
    let availableCount: Int
    let totalPeople: Int
    let unavailableNames: [String]

    var id: String {
        rawValues.joined(separator: "|")
    }

    var availabilityText: String {
        "\(availableCount) of \(totalPeople) available"
    }

    var compactAvailabilityText: String {
        "\(availableCount)/\(totalPeople)"
    }

    var unavailableText: String {
        unavailableNames.joined(separator: ", ")
    }

    var hasUnavailablePeople: Bool {
        !unavailableNames.isEmpty
    }
}
