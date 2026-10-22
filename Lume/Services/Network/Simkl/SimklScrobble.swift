//
//  SimklScrobble.swift
//  Lume
//
//  Playback position on Simkl. `/scrobble/pause` saves a resumable playback
//  any signed-in device can read back (`GET /sync/playback`), and `/stop`
//  below 80% does the same; at 80% or above it marks the title watched. Same
//  lifecycle as Trakt's, driven by the same `TraktPlaybackScrobbler`.
//

import Foundation

/// A movie, or a show and episode, with a progress percentage. The unused
/// branch is omitted rather than sent as null.
nonisolated struct SimklScrobbleRequest: Encodable {
    let target: TraktScrobbleTarget
    let progress: Double

    private struct Media: Encodable {
        let ids: SimklIDs
    }

    private struct Episode: Encodable {
        let season: Int
        let number: Int
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // At most two decimals, per the API.
        try container.encode((progress * 100).rounded() / 100, forKey: .progress)
        switch target {
        case let .movie(tmdbID):
            try container.encode(Media(ids: SimklIDs(tmdb: tmdbID)), forKey: .movie)
        case let .episode(showTMDBID, season, episode):
            try container.encode(Media(ids: SimklIDs(tmdb: showTMDBID)), forKey: .show)
            try container.encode(Episode(season: season, number: episode), forKey: .episode)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case progress, movie, show, episode
    }
}

/// What Simkl recorded — `pause` or `scrobble` (watched) for a stop. Logged.
nonisolated struct SimklScrobbleResponse: Decodable {
    let action: String?
    let progress: Double?
}

nonisolated extension SimklClient {
    /// Start, pause or stop the viewer's session on `target`. `discard` ends
    /// an abandoned start without leaving a resume point: Simkl keeps a stop
    /// below 80% as a paused playback, so that one is then removed.
    @discardableResult
    func scrobble(
        _ target: TraktScrobbleTarget, action: TraktScrobbleAction, progress: Double, accessToken: String
    ) async throws -> SimklScrobbleResponse {
        let path = switch action {
        case .start: "/scrobble/start"
        case .pause: "/scrobble/pause"
        case .stop, .discard: "/scrobble/stop"
        }
        let response: SimklScrobbleResponse = try await post(
            path, body: SimklScrobbleRequest(target: target, progress: progress), accessToken: accessToken
        )
        if action == .discard {
            try await removePausedProgress(of: target.mutationTarget, accessToken: accessToken)
        }
        return response
    }

    /// A position recovered after a crash or kill, sent as the pause the
    /// session never got to send — unless Simkl already holds a newer pause
    /// for the title, from another device or a later session here.
    func recordPausedProgress(_ target: TraktScrobbleTarget, progress: Double, pausedAt: Date, accessToken: String) async throws {
        let paused = try await playback(accessToken: accessToken).filter { $0.matches(target.mutationTarget) }
        guard !paused.contains(where: { (TraktWatchedImporter.parse($0.pausedAt) ?? .distantPast) >= pausedAt }) else { return }
        try await scrobble(target, action: .pause, progress: progress, accessToken: accessToken)
    }
}
