//
//  TitleSources.swift
//  Lume
//
//  Every copy the catalogue holds of one title, matched by TMDB id: the same
//  film or show in different categories of a playlist (a 4K folder, another
//  language) or on other playlists. The detail page plays one copy and offers
//  the rest from its Source button; the player offers the same playable copies,
//  warning when known file durations make a transferred playhead unsuitable.
//
//  Each copy keeps its own progress, so the copy watched most recently is the
//  one to resume (`preferred`). That is the remembered choice: no separate
//  state, and it syncs with watch progress.
//

import Foundation
import SwiftData

/// One copy of a title: a film's or a show's, or one quality of a live
/// channel (`LiveChannelVariants`), which the player's Source menu offers the
/// same way.
enum TitleCopy: Hashable {
    case movie(Movie)
    case series(Series)
    case live(LiveStream)

    var id: String {
        switch self {
        case let .movie(movie): movie.id
        case let .series(series): series.id
        case let .live(stream): stream.id
        }
    }

    /// A copy is its catalogue entry: equal and hashed by id, which needn't
    /// rely on the models' own conformances (Series has none on every
    /// platform).
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var lastWatchedDate: Date? {
        switch self {
        case let .movie(movie): movie.lastWatchedDate
        case let .series(series): series.lastWatchedDate
        case let .live(stream): stream.lastWatchedDate
        }
    }

    var categoryID: String? {
        switch self {
        case let .movie(movie): movie.categoryId
        case let .series(series): series.categoryId
        case let .live(stream): stream.categoryId
        }
    }
}

/// A copy as the Source picker lists it.
struct TitleSource: Identifiable, Hashable {
    let copy: TitleCopy
    /// The copy's category ("4K Movies", "Films — French"); nil when the
    /// catalogue has no name for it.
    let categoryName: String?
    /// The owning playlist's name, for a copy on another playlist; nil for
    /// one in the same playlist as the page's.
    let playlistName: String?

    var id: String {
        copy.id
    }

    /// The film's runtime, for a movie copy whose provider reports it.
    var runtime: MediaRuntime? {
        guard case let .movie(movie) = copy else { return nil }
        return movie.runtime
    }
}

enum TitleSources {
    /// Every copy of `movie`'s title, `movie` included: its own playlist's
    /// first, then other playlists' by playlist name. Just `movie` when it has
    /// no TMDB id to match by.
    static func resolve(for movie: Movie, restriction: ContentRestriction, in context: ModelContext) -> [TitleSource] {
        guard let tmdbId = movie.tmdbId else { return sources([.movie(movie)], opened: movie.id, restriction: restriction, in: context) }
        let matches = (try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == tmdbId }))) ?? []
        return sources(matches.map(TitleCopy.movie), opened: movie.id, restriction: restriction, in: context)
    }

    /// Every copy of `series`'s title, `series` included — as for movies.
    static func resolve(for series: Series, restriction: ContentRestriction, in context: ModelContext) -> [TitleSource] {
        guard let tmdbId = series.tmdbId else { return sources([.series(series)], opened: series.id, restriction: restriction, in: context) }
        let matches = (try? context.fetch(FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId == tmdbId }))) ?? []
        return sources(matches.map(TitleCopy.series), opened: series.id, restriction: restriction, in: context)
    }

    /// The copy to show and resume: the one watched most recently, else the
    /// one opened.
    static func preferred(in sources: [TitleSource], opened: String) -> TitleSource? {
        let watched = sources.filter { $0.copy.lastWatchedDate != nil }
        return watched.max { ($0.copy.lastWatchedDate ?? .distantPast) < ($1.copy.lastWatchedDate ?? .distantPast) }
            ?? sources.first { $0.id == opened }
    }

    /// Same-playlist copies first, then other playlists' sorted by name. A copy
    /// on a playlist that can't be resolved is dropped: without its playlist
    /// there are no credentials to play it with.
    private static func sources(_ copies: [TitleCopy], opened: String, restriction: ContentRestriction, in context: ModelContext) -> [TitleSource] {
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        let ownPlaylist = playlists.owner(ofContentID: opened)
        let categoryIDs = Set(copies.compactMap(\.categoryID))
        let categories = (try? context.fetch(FetchDescriptor<Category>(predicate: #Predicate { categoryIDs.contains($0.id) }))) ?? []
        let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let resolved = copies.compactMap { copy -> (TitleSource, isOwn: Bool)? in
            guard !restriction.hides(categoryID: copy.categoryID) else { return nil }
            let owner = playlists.owner(ofContentID: copy.id)
            guard owner != nil || ownPlaylist == nil else { return nil }
            let isOwn = owner == nil || owner?.id == ownPlaylist?.id
            let source = TitleSource(
                copy: copy,
                categoryName: copy.categoryID.flatMap { names[$0] },
                playlistName: isOwn ? nil : owner?.name
            )
            return (source, isOwn)
        }
        let own = resolved.filter(\.isOwn).map(\.0)
        let foreign = resolved.filter { !$0.isOwn }.map(\.0)
            .sorted { ($0.playlistName ?? "").localizedStandardCompare($1.playlistName ?? "") == .orderedAscending }
        return own + foreign
    }
}

extension MediaRuntime {
    /// Whether two copies are the same cut, so a position in one is the same
    /// moment in the other: runtimes within a minute, or 2% of the longer for
    /// a long film. A different edition or a longer intro fails it.
    func isSameCut(as other: MediaRuntime) -> Bool {
        let tolerance = max(60, max(seconds, other.seconds) / 50)
        return abs(seconds - other.seconds) <= tolerance
    }
}
