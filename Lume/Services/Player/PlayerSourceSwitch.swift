//
//  PlayerSourceSwitch.swift
//  Lume
//
//  Switching to another copy of what's playing without leaving the player:
//  another category's copy of the film, or the same season and episode in
//  another copy of the series (`TitleSources`). Identity discovers copies;
//  runtime only detects a known mismatch when carrying the playhead across.
//  Missing or TMDB-estimated runtimes must not hide playable copies.
//
//  A live channel's copies are its other qualities (`LiveChannelVariants`):
//  "Sky Sports F1 FHD" switches to its UHD or HD. Swapping quality is not
//  changing channel — each choice is anchored to the row the viewer tuned
//  (`PlayableMedia.channelAnchorID`), and the one watched last is the one the
//  channel opens in next time, as with a film's copies.
//
//  The host publishes the result on `PlayerControlsBridge`; the switch itself
//  goes through `switchMedia`, the one safe way to change stream.
//

import Foundation
import SwiftData

/// Another playable copy, with file-duration evidence when available.
struct PlayerSourceOption: Identifiable, Equatable {
    let source: TitleSource
    /// The copy as playable media; its start time is replaced by the current
    /// position when it's chosen.
    let media: PlayableMedia
    let runtime: MediaRuntime?

    var id: String {
        media.id
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

/// What the player's Source menu shows: the copy playing, and the others it
/// can switch to.
struct PlayerSources: Equatable {
    let current: TitleSource
    let currentRuntime: MediaRuntime?
    let alternatives: [PlayerSourceOption]
}

enum PlayerSourceSwitch {
    enum Start { case currentPosition, beginning }

    /// Bound to the stream that opened the confirmation, not whatever happens
    /// to be playing when a delayed alert action arrives.
    struct Request: Identifiable {
        let originID: String
        let targetID: String

        var id: String {
            "\(originID)>\(targetID)"
        }

        func target(in sources: PlayerSources?, playingID: String) -> PlayerSourceOption? {
            guard originID == playingID else { return nil }
            return sources?.alternatives.first { $0.id == targetID }
        }
    }

    static func requiresRestart(current: MediaRuntime?, alternative: MediaRuntime?, measuredDuration: TimeInterval) -> Bool {
        let measured = MediaRuntime(seconds: Int(exactly: measuredDuration.rounded(.down)))
        guard let runtime = measured ?? current, let alternative else { return false }
        return !runtime.isSameCut(as: alternative)
    }

    static func media(for option: PlayerSourceOption, start: Start, position: TimeInterval) -> PlayableMedia {
        // A live stream has no position to carry: it joins at the live edge.
        guard !option.media.isLive else { return option.media }
        return option.media.resuming(at: start == .beginning ? 0 : position)
    }

    /// The copies `media` can switch to, or nil when there are none: a title
    /// or channel with one copy, or no playable alternative.
    static func sources(for media: PlayableMedia, restriction: ContentRestriction, in context: ModelContext) -> PlayerSources? {
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        switch media.contentRef {
        case let .movie(id):
            guard let movie = first(Movie.self, #Predicate { $0.id == id }, in: context) else { return nil }
            return movieSources(movie, playlists: playlists, restriction: restriction, in: context)
        case let .episode(id):
            guard let episode = first(Episode.self, #Predicate { $0.id == id }, in: context) else { return nil }
            return episodeSources(episode, playlists: playlists, restriction: restriction, in: context)
        case let .live(id):
            guard media.catchup == nil, let stream = PlayerContentLookup.liveStream(id, in: context) else { return nil }
            return liveSources(stream, playing: media, playlists: playlists, restriction: restriction, in: context)
        }
    }

    /// The playing channel's other qualities this viewer may see, best for
    /// the screen first. Each plays as the Source menu's choice, anchored to
    /// the row being watched.
    private static func liveSources(
        _ stream: LiveStream, playing media: PlayableMedia, playlists: [Playlist],
        restriction: ContentRestriction, in context: ModelContext
    ) -> PlayerSources? {
        guard let playlist = PlaylistOwner.playlist(forContentID: stream.id, in: playlists) else { return nil }
        let qualities = liveQualities(of: stream, playlist: playlist, restriction: restriction, in: context)
        guard let current = qualities.first(where: { $0.id == stream.id }) else { return nil }
        let anchor = media.channelRowID
        let alternatives = qualities.compactMap { source -> PlayerSourceOption? in
            guard source.id != stream.id, case let .live(member) = source.copy,
                  let target = PlayableMedia.from(stream: member, playlist: playlist, scope: media.channelScope, choosingQuality: false)
            else { return nil }
            return PlayerSourceOption(source: source, media: target.asQuality(anchoredAt: anchor), runtime: nil)
        }
        return alternatives.isEmpty ? nil : PlayerSources(current: current, currentRuntime: nil, alternatives: alternatives)
    }

    /// Every quality of `stream`'s channel this viewer may see, `stream`
    /// included, best for the screen first; empty when it has no others. A
    /// quality in another category names it — the rest are this list's.
    /// Shared by the player's Source menu and the programme sheet's.
    static func liveQualities(
        of stream: LiveStream, playlist: Playlist, restriction: ContentRestriction, in context: ModelContext
    ) -> [TitleSource] {
        guard stream.variantKey != nil else { return [] }
        let members = LiveChannelVariants.members(of: stream, prefix: playlist.contentIDPrefix, in: context)
            .filter { $0.id == stream.id || !restriction.hides(categoryID: $0.categoryId) }
        guard members.count > 1 else { return [] }
        let ids = Array(Set(members.compactMap(\.categoryId)))
        let categories = (try? context.fetch(FetchDescriptor<Category>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return LiveChannelVariants.ranked(members).map { member in
            let elsewhere = member.categoryId != stream.categoryId
            return TitleSource(copy: .live(member), categoryName: elsewhere ? member.categoryId.flatMap { names[$0] } : nil, playlistName: nil)
        }
    }

    private static func movieSources(_ movie: Movie, playlists: [Playlist], restriction: ContentRestriction, in context: ModelContext) -> PlayerSources? {
        let sources = TitleSources.resolve(for: movie, restriction: restriction, in: context)
        guard let current = sources.first(where: { $0.id == movie.id }) else { return nil }
        let alternatives = sources.compactMap { source -> PlayerSourceOption? in
            guard source.id != movie.id, case let .movie(copy) = source.copy,
                  let playlist = PlaylistOwner.playlist(forContentID: copy.id, in: playlists),
                  let media = PlayableMedia.from(movie: copy, playlist: playlist) else { return nil }
            return PlayerSourceOption(source: source, media: media, runtime: movieRuntime(copy))
        }
        return alternatives.isEmpty ? nil : PlayerSources(current: current, currentRuntime: movieRuntime(movie), alternatives: alternatives)
    }

    /// The same season and episode in each other copy of the series. Only
    /// episodes this device has loaded are offered: fetching another copy's
    /// episodes from the player isn't worth a stall.
    private static func episodeSources(_ episode: Episode, playlists: [Playlist], restriction: ContentRestriction, in context: ModelContext) -> PlayerSources? {
        guard let series = episode.series else { return nil }
        let sources = TitleSources.resolve(for: series, restriction: restriction, in: context)
        guard let current = sources.first(where: { $0.id == series.id }) else { return nil }
        let alternatives = sources.compactMap { source -> PlayerSourceOption? in
            guard source.id != series.id, case let .series(copy) = source.copy,
                  let match = copy.episodes.first(where: {
                      $0.seasonNum == episode.seasonNum && $0.episodeNum == episode.episodeNum
                  }),
                  let playlist = PlaylistOwner.playlist(forContentID: match.id, in: playlists),
                  let media = PlayableMedia.from(episode: match, playlist: playlist) else { return nil }
            return PlayerSourceOption(source: source, media: media, runtime: match.runtime)
        }
        return alternatives.isEmpty ? nil : PlayerSources(current: current, currentRuntime: episode.runtime, alternatives: alternatives)
    }

    private static func movieRuntime(_ movie: Movie) -> MediaRuntime? {
        StreamDetailsLoader.measuredRuntime(for: movie.id) ?? movie.streamRuntime
    }

    private static func first<Model: PersistentModel>(_: Model.Type, _ predicate: Predicate<Model>, in context: ModelContext) -> Model? {
        var descriptor = FetchDescriptor<Model>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
