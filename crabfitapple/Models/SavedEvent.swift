import Foundation
import SwiftData

@Model
final class SavedEvent {
    var eventID: String = ""
    var name: String = ""
    var createdDate: Date?

    init(eventID: String, name: String, createdDate: Date? = nil) {
        self.eventID = eventID
        self.name = name
        self.createdDate = createdDate
    }
}
