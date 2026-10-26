//
//  MDBListScrobble.swift
//  Lume
//
//  Playback position on MDBList. `/scrobble/pause` saves a resumable session
//  any signed-in device can read back (`GET /sync/playback`), and `/stop`
//  below 80% does the same; at 80% or above it marks the title watched.
//  `/scrobble/clear` removes a paused session by the same payload. Same
//  lifecycle as Trakt's and Simkl's, driven by the same
//  `TraktPlaybackScrobbler`.
//

import Foundation

/// A movie, or a show with its season and episode, as the scrobble endpoints
/// name it. `progress` is omitted for a clear.
nonisolated struct MDBListScrobbleRequest: Encodable {
    let target: TraktScrobbleTarget
    var progress: Double?

    private struct Show: Encodable {
        let ids: MDBListIDs
        let season: Season
    }

    private struct Season: Encodable {
        let number: Int
        let episode: MDBListEpisodeNumber
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let progress {
            // At most two decimals, as the documented examples send.
            try container.encode((progress * 100).rounded() / 100, forKey: .progress)
            try container.encode(MDBListSyncClient.appVersion, forKey: .appVersion)
        }
        switch target {
        case let .movie(tmdbID):
            try container.encode(MDBListMedia(ids: MDBListIDs(tmdb: tmdbID)), forKey: .movie)
        case let .episode(showTMDBID, season, episode):
            let show = Show(ids: MDBListIDs(tmdb: showTMDBID), season: Season(number: season, episode: MDBListEpisodeNumber(number: episode)))
            try container.encode(show, forKey: .show)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case progress, movie, show
        case appVersion = "app_version"
    }
}

/// What MDBList recorded — `pause`, or `scrobble` (watched) for a stop. Logged
/// only. Progress can arrive as a decimal string (`"15.50"`).
nonisolated struct MDBListScrobbleResponse: Decodable {
    let action: String?
    let progress: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = container.lenientString(forKey: .action)
        progress = container.lenientDouble(forKey: .progress)
    }

    private enum CodingKeys: String, CodingKey {
        case action, progress
    }
}

/// One entry from `GET /sync/playback`.
nonisolated struct MDBListPlaybackSession: Decodable {
    let pausedAt: String?
    let movie: MDBListMedia?
    let show: MDBListMedia?
    let episode: Episode?

    nonisolated struct Episode: Decodable {
        let season: Int?
        let number: Int?
    }

    enum CodingKeys: String, CodingKey {
        case movie, show, episode
        case pausedAt = "paused_at"
    }

    /// Whether this entry is the paused progress of `target`.
    func matches(_ target: TraktScrobbleTarget) -> Bool {
        switch target {
        case let .movie(tmdbID):
            movie?.ids.tmdb == tmdbID
        case let .episode(showTMDBID, season, number):
            show?.ids.tmdb == showTMDBID && episode?.season == season && episode?.number == number
        }
    }
}

nonisolated extension MDBListSyncClient {
    /// Start, pause or stop the viewer's session on `target`. `discard` ends
    /// an abandoned start without leaving a resume point: MDBList keeps a stop
    /// below 80% as a paused session, so that one is then cleared. A success
    /// status is the answer; the reply is nil when it doesn't decode.
    @discardableResult
    func scrobble(
        _ target: TraktScrobbleTarget, action: TraktScrobbleAction, progress: Double, accessToken: String
    ) async throws -> MDBListScrobbleResponse? {
        let path = switch action {
        case .start: "/scrobble/start"
        case .pause: "/scrobble/pause"
        case .stop, .discard: "/scrobble/stop"
        }
        let response: MDBListScrobbleResponse? = try await postReporting(
            path, body: MDBListScrobbleRequest(target: target, progress: progress), accessToken: accessToken
        )
        if action == .discard {
            try await removePausedProgress(of: target, accessToken: accessToken)
        }
        return response
    }

    /// The account's paused sessions, from this app and others.
    func playback(accessToken: String) async throws -> [MDBListPlaybackSession] {
        let sessions: [MDBListPlaybackSession]? = try await get("/sync/playback", accessToken: accessToken)
        return sessions ?? []
    }

    /// Clears the title's paused session. Already gone (cleared elsewhere, or
    /// expired) counts as done.
    func removePausedProgress(of target: TraktScrobbleTarget, accessToken: String) async throws {
        do {
            try await post("/scrobble/clear", body: MDBListScrobbleRequest(target: target), accessToken: accessToken)
        } catch MDBListSyncError.server(404) {}
    }

    /// A position recovered after a crash or kill, sent as the pause the
    /// session never got to send — unless MDBList already holds a newer pause
    /// for the title, from another device or a later session here.
    func recordPausedProgress(_ target: TraktScrobbleTarget, progress: Double, pausedAt: Date, accessToken: String) async throws {
        let paused = try await playback(accessToken: accessToken).filter { $0.matches(target) }
        guard !paused.contains(where: { (MDBListDates.parse($0.pausedAt) ?? .distantPast) >= pausedAt }) else { return }
        try await scrobble(target, action: .pause, progress: progress, accessToken: accessToken)
    }
}
