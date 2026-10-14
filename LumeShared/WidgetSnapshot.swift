//
//  WidgetSnapshot.swift
//  LumeShared
//
//  The value-type snapshot the app exports for the tvOS Top Shelf. Compiled
//  into the app and the Top Shelf extension, so it must stay a plain Codable
//  surface with no SwiftData / app dependencies.
//  Everything is `nonisolated`: the app target builds with default MainActor
//  isolation while the extensions don't, and these values cross actors freely.
//

import Foundation

/// Everything the Top Shelf can render, precomputed by the app
/// (see `WidgetSnapshotExporter`) and written to the shared App Group container.
/// Extensions never query the catalog — they read this file only.
nonisolated struct WidgetSnapshot: Codable, Equatable {
    var generatedAt: Date
    var continueWatching: [WidgetMediaItem]
    var favorites: [WidgetMediaItem]
    /// How the tvOS Top Shelf presents this snapshot. Only the tvOS app writes
    /// it; absent (an older snapshot, or iOS), the Top Shelf uses the default.
    var topShelf: TopShelfConfiguration?

    static let empty = WidgetSnapshot(
        generatedAt: .distantPast,
        continueWatching: [],
        favorites: []
    )
}

/// One resumable or favorite title. `deepLink` carries the full launch intent so
/// renderers never rebuild routing logic.
nonisolated struct WidgetMediaItem: Codable, Equatable, Identifiable {
    nonisolated enum Kind: String, Codable {
        case movie
        case episode
        case series
        case live
    }

    var id: String
    var kind: Kind
    var title: String
    var subtitle: String?
    var imageURL: URL?
    /// Landscape artwork for the Top Shelf carousel, when the title has one.
    var backdropURL: URL?
    /// Resume fraction (0...1) for partially-watched items, nil otherwise.
    var progress: Double?
    var deepLink: URL
    /// The title's detail screen — for an episode, its show's. The Top Shelf
    /// opens this on Select and keeps `deepLink` for the Play button; nil for
    /// a channel, which has no detail screen.
    var detailLink: URL?
}
