//
//  SimklPlayback.swift
//  Lume
//
//  The account's paused playback on Simkl: left by lume's scrobbles
//  (`SimklScrobble`) and other apps. Taking a title out of Continue Watching
//  removes them, so Simkl's resume rows agree with lume's.
//

import Foundation

/// One entry from `GET /sync/playback`.
nonisolated struct SimklPlaybackSession: Decodable {
    /// For `DELETE /sync/playback/{id}`.
    let id: Int64?
    let movie: SimklWatchedMedia?
    let show: SimklWatchedMedia?
    let episode: SimklPlaybackEpisode?
    /// When it was paused (`paused_at`), so a newer pause from elsewhere wins.
    let pausedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, movie, show, episode
        case pausedAt = "paused_at"
    }

    /// Whether this entry is the paused progress of `target`.
    func matches(_ target: TrackerMutation.Target) -> Bool {
        switch target {
        case let .movie(tmdbID):
            movie?.ids.tmdb == tmdbID
        case let .episode(showTMDBID, season, number):
            show?.ids.tmdb == showTMDBID && episode?.season == season && episode?.number == number
        case .show:
            false
        }
    }
}

/// The episode a session paused, by season and number.
nonisolated struct SimklPlaybackEpisode: Decodable {
    let season: Int?
    let number: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        season = try container.decodeIfPresent(Int.self, forKey: .season)
        // The schema names it `number`; Simkl's own example sends `episode`.
        number = try container.decodeIfPresent(Int.self, forKey: .number)
            ?? container.decodeIfPresent(Int.self, forKey: .episode)
    }

    enum CodingKeys: String, CodingKey {
        case season, number, episode
    }
}

nonisolated extension SimklClient {
    /// The account's paused sessions. An account with none may answer `null`.
    func playback(accessToken: String) async throws -> [SimklPlaybackSession] {
        let sessions: [SimklPlaybackSession]? = try await get("/sync/playback", accessToken: accessToken)
        return sessions ?? []
    }

    /// Simkl deletes a paused session by its own id, so look the title up
    /// first. Every match goes: other apps can each leave one.
    func removePausedProgress(of target: TrackerMutation.Target, accessToken: String) async throws {
        let ids = try await playback(accessToken: accessToken).filter { $0.matches(target) }.compactMap(\.id)
        for id in ids {
            do {
                try await delete("/sync/playback/\(id)", accessToken: accessToken)
            } catch SimklError.server(404) {
                // Already gone: removed elsewhere, or expired with the plan's retention.
            }
        }
    }
}
