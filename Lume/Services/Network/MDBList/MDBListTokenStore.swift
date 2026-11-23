//
//  MDBListTokenStore.swift
//  Lume
//
//  Keychain-backed persistence for the MDBList OAuth token set, and the
//  remembered account identity, through the shared tracker stores
//  (`TrackerTokenStoring`, `TrackerAccountIdentityStoring`).
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

/// The MDBList token pair in the keychain (`TrackerTokenStoring`). It stays
/// on this device.
nonisolated enum MDBListTokenStore: TrackerTokenStoring {
    typealias Tokens = MDBListTokens
    static let item = CredentialItem(service: "bilipp.Lume.mdblist", account: "oauth-tokens", accessibility: .afterFirstUnlock)
    static let syncedCredential: SyncedCredentialKind? = nil
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

/// Remembers the MDBList account (`TrackerAccountIdentityStoring`).
nonisolated enum MDBListAccountIdentityStore: TrackerAccountIdentityStoring {
    typealias Identity = MDBListAccountIdentity
    static let key = "mdblist.lastAccountIdentity.v1"
}
