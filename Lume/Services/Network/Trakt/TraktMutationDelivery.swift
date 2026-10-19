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
            guard !mutation.isPresent else { return false }
            try await removePausedProgress(of: mutation.target, accessToken: accessToken)
        }
        return true
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
