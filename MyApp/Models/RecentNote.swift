import Foundation

/// One entry of the lightweight "Récents" history: a Markdown file the user
/// opened or saved, with the few fields the list needs to render.
nonisolated struct RecentNote: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let folder: String
    let modificationDate: Date?

    var id: URL { url }

    /// "Aujourd'hui", "Hier", then a short localized date.
    var relativeDayLabel: String {
        guard let modificationDate else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(modificationDate) { return "Aujourd'hui" }
        if calendar.isDateInYesterday(modificationDate) { return "Hier" }
        return modificationDate.formatted(
            .dateTime.locale(Locale.current).day().month(.abbreviated)
        )
    }
}
