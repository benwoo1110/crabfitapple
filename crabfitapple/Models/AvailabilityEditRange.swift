import Foundation

struct AvailabilityEditRange: Equatable, Identifiable, Sendable {
    let id: UUID
    var startBoundaryID: String
    var endBoundaryID: String

    nonisolated init(id: UUID = UUID(), startBoundaryID: String, endBoundaryID: String) {
        self.id = id
        self.startBoundaryID = startBoundaryID
        self.endBoundaryID = endBoundaryID
    }
}
