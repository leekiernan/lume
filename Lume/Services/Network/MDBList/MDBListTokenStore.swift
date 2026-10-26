//
//  MDBListTokenStore.swift
//  Lume
//
//  Keychain-backed persistence for the MDBList OAuth token set, and the
//  remembered account identity. Mirrors `SimklTokenStore`: the keychain work
//  goes through `CredentialBackend`, with `AfterFirstUnlock` accessibility so
//  a refresh can succeed even if it ever runs while the device is locked.
//
//  Unlike Trakt and Simkl, the pair stays on this device: it isn't carried
//  between devices through iCloud, so each one signs in by itself.
//

import Foundation

/// The OAuth token set from MDBList's `/oauth/token/`, plus what is needed to
/// know when the access token needs refreshing.
nonisolated struct MDBListTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// Unix timestamp (seconds) when the access token was issued — captured
    /// client-side, as the token response carries no `created_at`.
    var issuedAt: TimeInterval
    /// Lifetime of the access token in seconds (30 days).
    var expiresIn: TimeInterval
    var scope: String?

    var expiryDate: Date {
        Date(timeIntervalSince1970: issuedAt + expiresIn)
    }

    /// Whether the token has expired or is within a day of doing so.
    var needsRefresh: Bool {
        expiryDate.timeIntervalSinceNow < 60 * 60 * 24
    }
}

nonisolated enum MDBListTokenStore {
    private static let item = CredentialItem(
        service: "bilipp.Lume.mdblist",
        account: "oauth-tokens",
        accessibility: .afterFirstUnlock
    )

    /// The stored token set, or nil if it is absent or unreadable.
    static func load() -> MDBListTokens? {
        guard case let .found(data) = CredentialBackend.current.storage.read(item) else { return nil }
        return try? JSONDecoder().decode(MDBListTokens.self, from: data)
    }

    /// Saves the token set, replacing any existing one.
    @discardableResult
    static func save(_ tokens: MDBListTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        return CredentialBackend.current.storage.write(data, to: item)
    }

    /// Removes the stored token set. A missing item is treated as success.
    @discardableResult
    static func clear() -> Bool {
        CredentialBackend.current.storage.delete(item)
    }
}

// MARK: - Account identity

nonisolated struct MDBListAccountIdentity: Codable, Equatable {
    let username: String
    /// The outbox partition for this account: the stable MDBList user id where
    /// the response carries one, else the normalized username.
    let scope: String

    init(username: String, scope: String) {
        self.username = username
        self.scope = scope
    }

    /// Nil when the user has no name to show or scope by.
    init?(user: MDBListUser) {
        guard let name = user.displayName else { return nil }
        username = name
        if let id = user.userID {
            scope = "mdblist:\(id)"
        } else {
            scope = "username:\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }
    }
}

/// The account identity is not secret. Remembering it alongside the keychain
/// token lets an offline cold launch stay connected and keep queueing watched
/// changes; the next successful `/user` response refreshes it.
nonisolated enum MDBListAccountIdentityStore {
    private static let key = "mdblist.lastAccountIdentity.v1"

    static func load(defaults: UserDefaults = .standard) -> MDBListAccountIdentity? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MDBListAccountIdentity.self, from: data)
    }

    static func save(_ identity: MDBListAccountIdentity, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
