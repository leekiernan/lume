import Foundation
import Synchronization

/// A source-owned artwork credential snapshot. Never persisted or exported.
/// The owner is explicit; two accounts on one origin must never be inferred
/// from the image URL alone.
nonisolated struct ProviderArtworkAccount: Hashable {
    let playlistID: UUID
    let connection: PlaylistConnection
    let scope: String

    init?(playlist: Playlist) {
        guard let connection = playlist.connection else { return nil }
        let account: String
        switch connection {
        case let .mediaServer(_, _, _, session):
            guard let session else { return nil }
            account = session.userId
        case let .plex(_, token):
            // Plex's credential-only/manual-token setup has no stable account
            // identifier. Keep conservative token isolation for that case;
            // username-backed sign-ins survive normal token rotation.
            let username = playlist.username.trimmingCharacters(in: .whitespacesAndNewlines)
            account = username.isEmpty ? (token ?? "anonymous") : username
        default: return nil
        }
        playlistID = playlist.id
        self.connection = connection
        scope = playlist.id.uuidString + "|" + connection.sourceType.rawValue + "|" + account
    }

    func request(for url: URL) -> ArtworkRequest? {
        guard let clean = Self.tokenFree(url) else { return nil }
        switch connection {
        case let .mediaServer(_, endpoint, _, session):
            guard ArtworkRedirectPolicy.sameOrigin(clean, endpoint) else { return ArtworkRequest(url: clean) }
            guard let session, var components = URLComponents(url: clean, resolvingAgainstBaseURL: false) else { return nil }
            components.queryItems = (components.queryItems ?? []) + JellyfinPlaybackAuth.queryItems(token: session.accessToken)
            return components.url.flatMap { ArtworkRequest(url: $0, accountScope: scope) }
        case let .plex(endpoint, token):
            guard ArtworkRedirectPolicy.sameOrigin(clean, endpoint) else { return ArtworkRequest(url: clean) }
            guard var components = URLComponents(url: clean, resolvingAgainstBaseURL: false) else { return nil }
            if let token, !token.isEmpty {
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: PlexClient.tokenQueryItem, value: token)]
            }
            return components.url.flatMap { ArtworkRequest(url: $0, accountScope: scope) }
        default: return nil
        }
    }

    static func tokenFree(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil
        components.password = nil
        components.queryItems = components.queryItems?.filter { !["x-plex-token", "api_key", "apikey"].contains($0.name.lowercased()) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }

    func ownsOrigin(_ url: URL) -> Bool {
        switch connection {
        case let .mediaServer(_, endpoint, _, _), let .plex(endpoint, _): ArtworkRedirectPolicy.sameOrigin(url, endpoint)
        default: false
        }
    }
}

/// One small source table, not a SwiftData fetch per poster. SwiftUI observes
/// the revision; off-main loaders read immutable snapshots through the mutex.
@MainActor
@Observable
final class ProviderArtworkAccounts {
    static let shared = ProviderArtworkAccounts()
    private(set) var revision = RequestToken()
    private nonisolated static let snapshots = Mutex<[UUID: ProviderArtworkAccount]>([:])

    func replace(_ accounts: [ProviderArtworkAccount]) {
        let next = Dictionary(accounts.map { ($0.playlistID, $0) }, uniquingKeysWith: { _, latest in latest })
        let changed = Self.snapshots.withLock { current in
            guard current != next else { return false }
            current = next
            return true
        }
        if changed { revision = RequestToken() }
    }

    nonisolated static func request(for url: URL, ownerID: String? = nil) -> ArtworkRequest? {
        let id = ownerID.map { MediaItemKey($0)?.id ?? $0 }
        let playlistID = id.flatMap { UUID(uuidString: String($0.prefix(36))) }
        return snapshots.withLock { accounts in
            if let playlistID, let account = accounts[playlistID] { return account.request(for: url) }
            // An unowned prefetch cannot guess which account supplies private
            // server artwork. Public CDN art continues through the usual path.
            if accounts.values.contains(where: { $0.ownsOrigin(url) }) { return nil }
            // A removed source's legacy credential must not remain usable.
            if let id, ["-plex-", "-jellyfin-", "-emby-"].contains(where: { id.dropFirst(36).hasPrefix($0) }) { return nil }
            return ArtworkRequest(url: url)
        }
    }

    nonisolated static func requiresPrivateRendering(_ url: URL) -> Bool {
        ArtworkRequest.carriesCredentials(url) || snapshots.withLock { accounts in
            accounts.values.contains { $0.ownsOrigin(url) }
        }
    }
}
