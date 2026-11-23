//
//  TraktTokenStore.swift
//  Lume
//
//  Keychain-backed persistence for the Trakt OAuth token set. Tokens are
//  secrets, so they live in the keychain rather than UserDefaults — encrypted
//  at rest and excluded from plaintext backups.
//
//  The store itself is the shared tracker one (`TrackerTokenStoring`); this
//  file holds Trakt's token type.
//

import Foundation

/// The OAuth token set returned by Trakt, plus the metadata needed to know when
/// the access token needs refreshing.
nonisolated struct TraktTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// Unix timestamp (seconds) when the access token was issued — Trakt's
    /// `created_at`.
    var createdAt: TimeInterval
    /// Lifetime of the access token in seconds — Trakt's `expires_in`.
    var expiresIn: TimeInterval
    var scope: String?
    var tokenType: String?

    /// Absolute moment the access token expires.
    var expiryDate: Date {
        Date(timeIntervalSince1970: createdAt + expiresIn)
    }

    /// Whether the token has expired or is within a day of doing so. The API's
    /// current lifetime is short and supplied dynamically in `expiresIn`, so no
    /// fixed Trakt lifetime is assumed here.
    var needsRefresh: Bool {
        expiryDate.timeIntervalSinceNow < 60 * 60 * 24
    }
}

/// The Trakt token pair in the keychain (`TrackerTokenStoring`), carried
/// between devices through iCloud.
nonisolated enum TraktTokenStore: TrackerTokenStoring {
    typealias Tokens = TraktTokens
    static let item = CredentialItem(service: "bilipp.Lume.trakt", account: "oauth-tokens", accessibility: .afterFirstUnlock)
    static let syncedCredential: SyncedCredentialKind? = .trakt
}
