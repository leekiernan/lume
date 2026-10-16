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

    /// The entry's namespaced TMDB identity — the part of an entry worth
    /// keeping or comparing; nil for an id no TMDB title can have.
    var reference: TMDBTitleReference? {
        TMDBTitleReference(kind: mediaType == .movie ? .movie : .series, rawValue: tmdbId)
    }

    /// An entry restored from a stored identity; its title isn't stored.
    init(_ reference: TMDBTitleReference) {
        self.init(tmdbId: reference.rawValue, mediaType: reference.kind == .movie ? .movie : .series, title: "")
    }

    init(tmdbId: Int, mediaType: MediaType, title: String) {
        self.tmdbId = tmdbId
        self.mediaType = mediaType
        self.title = title
    }
}

/// A source page, independent of playlist membership. Continuations belong to
/// the source, not the number of titles that matched the local catalogue.
nonisolated struct HomeListPage {
    let entries: [HomeListEntry]
    let nextPage: Int?
}
