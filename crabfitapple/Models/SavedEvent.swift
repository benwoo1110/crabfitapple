import Foundation
import SwiftData

@Model
final class SavedEvent {
    var eventID: String = ""
    var name: String = ""
    var createdDate: Date?
    var times: [String] = []
    var timeZoneIdentifier: String?

    var cachedEvent: CrabFitEvent? {
        guard !times.isEmpty,
              let timeZoneIdentifier,
              let createdDate else {
            return nil
        }

        return CrabFitEvent(
            id: eventID,
            name: name,
            times: times,
            timezone: timeZoneIdentifier,
            createdAt: createdDate.timeIntervalSince1970
        )
    }

    var hasCachedEventData: Bool {
        cachedEvent != nil
    }

    init(
        eventID: String,
        name: String,
        createdDate: Date? = nil,
        times: [String] = [],
        timeZoneIdentifier: String? = nil
    ) {
        self.eventID = eventID
        self.name = name
        self.createdDate = createdDate
        self.times = times
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    convenience init(event: CrabFitEvent) {
        self.init(
            eventID: event.id,
            name: event.name,
            createdDate: event.createdDate,
            times: event.times,
            timeZoneIdentifier: event.timezone
        )
    }

    func updateCache(with event: CrabFitEvent) {
        eventID = event.id
        name = event.name
        createdDate = event.createdDate
        times = event.times
        timeZoneIdentifier = event.timezone
    }
}
