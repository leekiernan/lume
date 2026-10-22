//
//  TraktMutationDelivery.swift
//  Lume
//
//  Translates one durable mutation into the matching Trakt sync request.
//

import Foundation

extension TraktClient {
    /// Returns false only for a malformed kind/target pairing. Network and API
    /// failures still throw so the caller retains the mutation for retry.
    func apply(_ mutation: TraktMutation, accessToken: String) async throws -> Bool {
        switch mutation.kind {
        case .history:
            guard let items = historyItems(for: mutation.target) else { return false }
            if mutation.isPresent {
                try await addToHistory(items, accessToken: accessToken)
            } else {
                try await removeFromHistory(items, accessToken: accessToken)
            }
        case .watchlist:
            guard let items = watchlistItems(for: mutation.target) else { return false }
            if mutation.isPresent {
                try await addToWatchlist(items, accessToken: accessToken)
            } else {
                try await removeFromWatchlist(items, accessToken: accessToken)
            }
        case .playback:
            guard mutation.isPresent else {
                try await removePausedProgress(of: mutation.target, accessToken: accessToken)
                return true
            }
            guard let target = TraktScrobbleTarget(mutation.target), let progress = mutation.progress,
                  let pausedAt = mutation.pausedAt else { return false }
            try await recordPausedProgress(of: mutation.target, as: target, progress: progress, pausedAt: pausedAt, accessToken: accessToken)
        }
        return true
    }

    /// A position recovered after a crash or kill, sent as the pause the
    /// session never got to send — unless Trakt already holds a newer pause
    /// for the title, from another device or a later session here.
    private func recordPausedProgress(
        of mutationTarget: TraktMutation.Target, as target: TraktScrobbleTarget,
        progress: Double, pausedAt: Date, accessToken: String
    ) async throws {
        let paused = try await playback(accessToken: accessToken).filter { $0.matches(mutationTarget) }
        guard !paused.contains(where: { (TraktWatchedImporter.parse($0.pausedAt) ?? .distantPast) >= pausedAt }) else { return }
        _ = try await scrobble(target, action: .pause, progress: progress, accessToken: accessToken)
    }

    /// Trakt deletes a paused entry by its own id, so look the title up first.
    /// Every match goes: other apps can each leave one for the same title.
    private func removePausedProgress(of target: TraktMutation.Target, accessToken: String) async throws {
        let ids = try await playback(accessToken: accessToken).filter { $0.matches(target) }.compactMap(\.id)
        for id in ids {
            do {
                try await removePlayback(id: id, accessToken: accessToken)
            } catch TraktError.server(404) {
                // Already removed, for example by another connected device.
            }
        }
    }

    private func historyItems(for target: TraktMutation.Target) -> TraktSyncItems? {
        switch target {
        case let .movie(tmdbID):
            TraktSyncItems.movie(tmdbID: tmdbID)
        case let .episode(showTMDBID, season, episode):
            TraktSyncItems.episode(
                showTMDBID: showTMDBID,
                season: season,
                episode: episode
            )
        case .show:
            nil
        }
    }

    private func watchlistItems(for target: TraktMutation.Target) -> TraktWatchlistSyncItems? {
        switch target {
        case let .movie(tmdbID):
            TraktWatchlistSyncItems.movie(tmdbID: tmdbID)
        case let .show(tmdbID):
            TraktWatchlistSyncItems.show(tmdbID: tmdbID)
        case .episode:
            nil
        }
    }
}
