import Foundation

/// A list title keyed by TMDB ID; ordered by the source list, not the catalog.
nonisolated struct HomeListEntry: Hashable {
    enum MediaType: String, Codable, Hashable {
        case movie
        case series
    }

    let tmdbId: Int
    let mediaType: MediaType
    /// Used for diagnostics/editor previews; VOD rows display the catalog title.
    let title: String
}

/// A source page, independent of playlist membership. Continuations belong to
/// the source, not the number of titles that matched the local catalogue.
nonisolated struct HomeListPage {
    let entries: [HomeListEntry]
    let nextPage: Int?
}
