//
//  PlayerSourceSwitch.swift
//  Lume
//
//  Switching to another copy of what's playing without leaving the player:
//  another category's copy of the film, or the same season and episode in
//  another copy of the series (`TitleSources`). Offered only when the switch
//  can resume at the same moment — both copies report a runtime and they're
//  the same cut (`MediaRuntime.isSameCut`). Where that can't be shown, the
//  copy isn't offered rather than guessed at.
//
//  The host publishes the result on `PlayerControlsBridge`; the switch itself
//  goes through `switchMedia`, the one safe way to change stream.
//

import Foundation
import SwiftData

/// Another copy the player can switch to at the same position.
struct PlayerSourceOption: Identifiable, Equatable {
    let source: TitleSource
    /// The copy as playable media; its start time is replaced by the current
    /// position when it's chosen.
    let media: PlayableMedia

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
    let alternatives: [PlayerSourceOption]
}

enum PlayerSourceSwitch {
    /// The copies `media` can switch to, or nil when there are none: live
    /// channels, a title with one copy, or no copy of the same cut.
    static func sources(for media: PlayableMedia, in context: ModelContext) -> PlayerSources? {
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        switch media.contentRef {
        case let .movie(id):
            guard let movie = first(Movie.self, #Predicate { $0.id == id }, in: context) else { return nil }
            return movieSources(movie, playlists: playlists, in: context)
        case let .episode(id):
            guard let episode = first(Episode.self, #Predicate { $0.id == id }, in: context) else { return nil }
            return episodeSources(episode, playlists: playlists, in: context)
        case .live:
            return nil
        }
    }

    private static func movieSources(_ movie: Movie, playlists: [Playlist], in context: ModelContext) -> PlayerSources? {
        guard let runtime = movie.runtime else { return nil }
        let sources = TitleSources.resolve(for: movie, in: context)
        guard let current = sources.first(where: { $0.id == movie.id }) else { return nil }
        let alternatives = sources.compactMap { source -> PlayerSourceOption? in
            guard source.id != movie.id, case let .movie(copy) = source.copy,
                  let copyRuntime = copy.runtime, runtime.isSameCut(as: copyRuntime),
                  let playlist = PlaylistOwner.playlist(forContentID: copy.id, in: playlists),
                  let media = PlayableMedia.from(movie: copy, playlist: playlist) else { return nil }
            return PlayerSourceOption(source: source, media: media)
        }
        return alternatives.isEmpty ? nil : PlayerSources(current: current, alternatives: alternatives)
    }

    /// The same season and episode in each other copy of the series. Only
    /// episodes this device has loaded are offered: fetching another copy's
    /// episodes from the player isn't worth a stall.
    private static func episodeSources(_ episode: Episode, playlists: [Playlist], in context: ModelContext) -> PlayerSources? {
        guard let runtime = episode.runtime, let series = episode.series else { return nil }
        let sources = TitleSources.resolve(for: series, in: context)
        guard let current = sources.first(where: { $0.id == series.id }) else { return nil }
        let alternatives = sources.compactMap { source -> PlayerSourceOption? in
            guard source.id != series.id, case let .series(copy) = source.copy,
                  let match = copy.episodes.first(where: {
                      $0.seasonNum == episode.seasonNum && $0.episodeNum == episode.episodeNum
                  }),
                  let matchRuntime = match.runtime, runtime.isSameCut(as: matchRuntime),
                  let playlist = PlaylistOwner.playlist(forContentID: match.id, in: playlists),
                  let media = PlayableMedia.from(episode: match, playlist: playlist) else { return nil }
            return PlayerSourceOption(source: source, media: media)
        }
        return alternatives.isEmpty ? nil : PlayerSources(current: current, alternatives: alternatives)
    }

    private static func first<Model: PersistentModel>(_: Model.Type, _ predicate: Predicate<Model>, in context: ModelContext) -> Model? {
        var descriptor = FetchDescriptor<Model>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
