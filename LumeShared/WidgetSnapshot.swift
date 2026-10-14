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
    /// The rows promoted to the Top Shelf, in the user's order. None means the
    /// Top Shelf is off and tvOS shows the app's static image.
    var sections: [WidgetSection]
    /// How the Top Shelf presents this snapshot.
    var topShelf: TopShelfConfiguration?

    static let empty = WidgetSnapshot(generatedAt: .distantPast, sections: [])
}

/// One promoted row: its title as the Top Shelf heads it, and its titles.
nonisolated struct WidgetSection: Codable, Equatable, Identifiable {
    /// The row's identity in the app (`TopShelfSource.token`), stable across
    /// exports so the Top Shelf keeps its place.
    var id: String
    var title: String
    var items: [WidgetMediaItem]
}

/// One title or channel. `deepLink` carries the full launch intent so
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
    /// The title's wordmark — a transparent TMDB logo, an episode's being its
    /// show's — which the app draws onto the carousel art.
    var logoURL: URL?
    /// The carousel image with the logo drawn in: a file the app rendered in
    /// the App Group's Caches (`TopShelfCarouselArt`), nil until it has. The
    /// extension only reads it, so its memory never holds the rendering.
    /// Optional, like `logoURL`, so older snapshots still decode.
    var artURL: URL?
}
