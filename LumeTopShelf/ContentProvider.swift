//
//  ContentProvider.swift
//  LumeTopShelf
//
//  The tvOS Top Shelf — the marquee row above the app icon on the Apple TV
//  home screen: the rows the user promoted from the Home, Movies and Series
//  layouts (Settings › Library), from the shared snapshot the app exports,
//  shown and sized the way they set it up (`TopShelfConfiguration`). Selecting
//  an item deep-links into the app via `lume://`. The system fetches poster
//  and backdrop artwork itself; channel logos go up as tiles rendered here
//  (`ChannelTileRenderer`).
//

import Foundation
import TVServices

final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let snapshot = WidgetDataStore.load() else {
            completionHandler(nil)
            return
        }
        let configuration = snapshot.topShelf ?? .default
        let sections = TopShelfSection.build(from: snapshot, configuration: configuration)
        // No rows promoted, or none with anything to show: tvOS falls back to
        // the app's static Top Shelf image.
        guard !sections.isEmpty else {
            completionHandler(nil)
            return
        }
        switch configuration.style {
        case .sectioned:
            // Channel logos go up as rendered tiles (see `ChannelTileRenderer`),
            // which takes a download per new logo — hence the async hop.
            let channels = sections.flatMap(\.entries).filter(\.isChannel).map {
                ChannelTileRenderer.Channel(id: $0.id, name: $0.title, logoURL: $0.posterURL)
            }
            Task {
                let tiles = await ChannelTileRenderer.tiles(for: channels)
                completionHandler(TVTopShelfSectionedContent(sections: sections.map { $0.sectionedCollection(tiles: tiles) }))
            }
        case .carousel:
            // A title's logo is drawn into its art (see `CarouselArtRenderer`),
            // which takes a download per new title — hence the async hop.
            let entries = TopShelfSection.carouselEntries(sections)
            let art = entries.compactMap { entry, _ in
                entry.backdropURL.map { CarouselArtRenderer.Art(id: entry.id, backdropURL: $0, logoURL: entry.logoURL) }
            }
            Task {
                let images = await CarouselArtRenderer.images(for: art)
                let items = entries.map { entry, contextTitle in
                    entry.carouselItem(contextTitle: contextTitle, art: images[entry.id])
                }
                completionHandler(items.isEmpty ? nil : TVTopShelfCarouselContent(style: .details, items: items))
            }
        }
    }
}

/// One promoted row's entries, ready to become either layout's items.
private struct TopShelfSection {
    let id: String
    let title: String
    let entries: [Entry]

    /// A single Top Shelf entry, from either a title or a channel.
    struct Entry {
        let id: String
        let title: String
        let summary: String?
        let posterURL: URL?
        let backdropURL: URL?
        /// The title's wordmark, drawn into the carousel art.
        let logoURL: URL?
        let isChannel: Bool
        let progress: Double?
        /// Played by the remote's Play button.
        let deepLink: URL
        /// Opened on Select: the detail screen, so a click never starts
        /// playback by surprise. Nil for a channel, which has none.
        let detailLink: URL?

        /// Select opens the detail screen; Play plays. A channel plays on both.
        func applyActions(to item: TVTopShelfItem) {
            item.displayAction = TVTopShelfAction(url: detailLink ?? deepLink)
            item.playAction = TVTopShelfAction(url: deepLink)
        }
    }

    /// The promoted rows in order, each capped at the chosen size; empty rows
    /// are left out.
    static func build(from snapshot: WidgetSnapshot, configuration: TopShelfConfiguration) -> [TopShelfSection] {
        snapshot.sections.compactMap { section in
            let capped = section.items.prefix(configuration.itemsPerSection).map(Entry.init(media:))
            return capped.isEmpty ? nil : TopShelfSection(id: section.id, title: section.title, entries: capped)
        }
    }

    /// `tiles` holds the rendered channel tiles, keyed by entry id.
    func sectionedCollection(tiles: [String: URL]) -> TVTopShelfItemCollection<TVTopShelfSectionedItem> {
        // Identifiers are scoped to the section: a favorite that's also in
        // progress appears in both rows.
        let collection = TVTopShelfItemCollection(items: entries.map {
            $0.sectionedItem(identifier: "\(id)-\($0.id)", tile: tiles[$0.id])
        })
        collection.title = title
        return collection
    }

    /// The carousel is one flat list: the sections in order, each item labelled
    /// with its section, and a title that appears in two sections (a favorite
    /// that's also in progress) shown once. Channels are left out — a logo is
    /// all the art they have, and it can't fill a full-screen backdrop — so
    /// they show only in the sectioned layout.
    /// The carousel's entries — titles only, each once — with the row each
    /// came from as its context title.
    static func carouselEntries(_ sections: [TopShelfSection]) -> [(entry: Entry, contextTitle: String)] {
        var seen = Set<String>()
        return sections.flatMap { section in
            section.entries
                .filter { !$0.isChannel && seen.insert($0.id).inserted }
                .map { ($0, section.title) }
        }
    }
}

private extension TopShelfSection.Entry {
    init(media: WidgetMediaItem) {
        self.init(
            id: media.id,
            title: media.title,
            summary: media.subtitle,
            posterURL: media.imageURL,
            backdropURL: media.backdropURL,
            logoURL: media.logoURL,
            isChannel: media.kind == .live,
            progress: media.progress,
            deepLink: media.deepLink,
            detailLink: media.detailLink
        )
    }

    func sectionedItem(identifier: String, tile: URL?) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: identifier)
        item.title = title
        item.imageShape = isChannel ? .square : .poster
        if let imageURL = isChannel ? tile : posterURL {
            item.setImageURL(imageURL, for: [.screenScale1x, .screenScale2x])
        }
        if let progress {
            item.playbackProgress = progress
        }
        applyActions(to: item)
        return item
    }

    /// `art` is the backdrop with the logo drawn in, when it rendered.
    func carouselItem(contextTitle: String, art: URL?) -> TVTopShelfCarouselItem {
        let item = TVTopShelfCarouselItem(identifier: id)
        item.title = title
        item.contextTitle = contextTitle
        item.summary = summary
        // Landscape art fills the carousel; a poster or logo is the fallback.
        if let imageURL = art ?? backdropURL ?? posterURL {
            item.setImageURL(imageURL, for: [.screenScale1x, .screenScale2x])
        }
        // Carousel items have no progress bar (`playbackProgress` is a
        // sectioned-item property), so resume state shows only in Rows.
        applyActions(to: item)
        return item
    }
}
