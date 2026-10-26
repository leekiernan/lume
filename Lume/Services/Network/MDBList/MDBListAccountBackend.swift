//
//  MDBListAccountBackend.swift
//  Lume
//
//  MDBList's side of the shared tracker sign-in (`TrackerAccountSession`): its
//  device-flow and token endpoints, with MDBList's errors mapped to the shared
//  outcomes, where its tokens and account identity live, and how a durable
//  change is delivered.
//

import Foundation
import OSLog

extension MDBListDeviceCode: TrackerDeviceCode {}
extension MDBListTokens: TrackerTokens {}
extension MDBListAccountIdentity: TrackerAccountIdentity {}

struct MDBListAccountBackend: TrackerAccountBackend {
    static let name = "MDBList"
    /// RFC 8628's +5 s on slow-down.
    static let slowDownStep: TimeInterval = 5
    static let outboxStorageKey = "mdblist.mutationOutbox.v1"

    private let client: MDBListSyncClient

    init(client: MDBListSyncClient = .shared) {
        self.client = client
    }

    var isConfigured: Bool {
        client.isConfigured
    }

    func requestDeviceCode() async throws -> MDBListDeviceCode {
        try await client.requestDeviceCode()
    }

    func poll(_ code: MDBListDeviceCode) async -> TrackerPollOutcome<MDBListTokens> {
        do {
            return try await .approved(client.pollForToken(deviceCode: code.deviceCode).tokens())
        } catch MDBListSyncError.authorizationPending {
            return .pending
        } catch MDBListSyncError.slowDown {
            return .slowDown
        } catch MDBListSyncError.codeExpired {
            return .failed(.codeExpired)
        } catch MDBListSyncError.accessDenied {
            return .failed(.declined)
        } catch MDBListSyncError.invalidClient {
            return .failed(.rejectedApp)
        } catch {
            return .failed(.unreachable)
        }
    }

    /// A refresh that answers without a new refresh token keeps the old one.
    /// OAuth answers a dead grant with 400 `invalid_grant`; anything else is
    /// worth retrying on the next request.
    func refresh(_ refreshToken: String) async -> TrackerRefreshOutcome<MDBListTokens> {
        do {
            return try await .refreshed(client.refreshToken(refreshToken).tokens(previousRefreshToken: refreshToken))
        } catch {
            Logger.network.warning("MDBList token refresh failed: \(LogRedaction.describe(error), privacy: .public)")
            if case MDBListSyncError.server(400) = error { return .rejected }
            return .unavailable
        }
    }

    func revoke(accessToken: String) async {
        try? await client.revokeToken(accessToken)
    }

    func fetchIdentity(accessToken: String) async -> MDBListAccountIdentity? {
        do {
            return try await MDBListAccountIdentity(user: client.currentUser(accessToken: accessToken))
        } catch {
            Logger.network.warning("MDBList account verification failed: \(LogRedaction.describe(error), privacy: .public)")
            return nil
        }
    }

    func deliver(_ mutation: TrackerMutation, accessToken: String) async throws -> Bool {
        switch mutation.kind {
        case .watchlist:
            return try await client.setWatchlist(mutation.target, watchlisted: mutation.isPresent, accessToken: accessToken)
        case .playback:
            guard let target = TraktScrobbleTarget(mutation.target) else { return false }
            guard mutation.isPresent else {
                try await client.removePausedProgress(of: target, accessToken: accessToken)
                return true
            }
            guard let progress = mutation.progress, let pausedAt = mutation.pausedAt else { return false }
            try await client.recordPausedProgress(target, progress: progress, pausedAt: pausedAt, accessToken: accessToken)
            return true
        case .history:
            return try await deliverHistory(mutation, accessToken: accessToken)
        }
    }

    /// A whole show is never sent: on MDBList it would cascade to every episode.
    private func deliverHistory(_ mutation: TrackerMutation, accessToken: String) async throws -> Bool {
        let items: MDBListSyncItems? = switch mutation.target {
        case let .movie(tmdbID): .movie(tmdbID: tmdbID)
        case let .episode(showTMDBID, season, episode): .episode(showTMDBID: showTMDBID, season: season, episode: episode)
        case .show: nil
        }
        guard let items else { return false }
        if mutation.isPresent {
            try await client.addToHistory(items, accessToken: accessToken)
        } else {
            try await client.removeFromHistory(items, accessToken: accessToken)
        }
        return true
    }

    func loadTokens() -> MDBListTokens? {
        MDBListTokenStore.load()
    }

    func saveTokens(_ tokens: MDBListTokens) -> Bool {
        MDBListTokenStore.save(tokens)
    }

    func clearTokensForUserDisconnect() -> Bool {
        MDBListTokenStore.clear()
    }

    /// The pair stays on this device, so there's no iCloud copy to tell.
    func credentialsDidChange() {}

    func loadIdentity() -> MDBListAccountIdentity? {
        MDBListAccountIdentityStore.load()
    }

    func saveIdentity(_ identity: MDBListAccountIdentity) {
        MDBListAccountIdentityStore.save(identity)
    }

    func clearIdentity() {
        MDBListAccountIdentityStore.clear()
    }
}
