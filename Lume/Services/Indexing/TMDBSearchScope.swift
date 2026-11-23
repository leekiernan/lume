//
//  TMDBSearchScope.swift
//  Lume
//
//  Which titles without a provider TMDB id are worth searching TMDB for.
//
//  On a provider that supplies ids for most of its catalogue, a category that
//  has almost none is telling us something: its entries aren't films or shows
//  TMDB lists. On one Xtream catalogue, 91% of the 2,658 movies without an id
//  were sports replays ("NCAAF 14 11 Virginia vs California 720p60fps -
//  2026") and most of the rest adult; Football Replays lacked ids for 612 of
//  618, Drama for 6 of 36,440. Searching those spent up to three requests a
//  title, every month as new replays arrived, and could never match.
//
//  Playlists that carry no ids at all (m3u, Stalker, WebDAV) are searched as
//  before: there the absence says nothing.
//

import Foundation

nonisolated enum TMDBSearchScope {
    struct Counts: Equatable {
        var total: Int
        var withID: Int

        var missingShare: Double {
            total == 0 ? 0 : Double(total - withID) / Double(total)
        }
    }

    /// The share of a playlist that must carry ids before a category's lack
    /// of them means anything.
    static let providerSuppliesIDs = 0.5
    /// A category this short is too small to judge.
    static let minimumCategorySize = 20
    /// A category missing ids for at least this share isn't searched.
    static let skipCategoryMissing = 0.9

    static func searches(category: Counts, playlist: Counts) -> Bool {
        guard playlist.total > 0, 1 - playlist.missingShare >= providerSuppliesIDs else { return true }
        guard category.total >= minimumCategorySize else { return true }
        return category.missingShare < skipCategoryMissing
    }
}
