enum EventListSortField: String, CaseIterable, Identifiable {
    case date
    case name

    var id: Self { self }

    var title: String {
        switch self {
        case .date:
            return "Date"
        case .name:
            return "Name"
        }
    }

    var systemImage: String {
        switch self {
        case .date:
            return "calendar"
        case .name:
            return "textformat"
        }
    }
}
