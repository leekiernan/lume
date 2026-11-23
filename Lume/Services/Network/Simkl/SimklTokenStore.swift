//
//  SimklTokenStore.swift
//  Lume
//
//  Keychain-backed persistence for the Simkl OAuth token set. Tokens are
//  secrets, so they live in the keychain rather than UserDefaults — encrypted
//  at rest and excluded from plaintext backups.
//
//  The store itself is the shared tracker one (`TrackerTokenStoring`); this
//  file holds Simkl's token and account types.
//

import Foundation

/// The OAuth token set returned by Simkl's `/oauth2/token`, plus the metadata
/// needed to know when the access token needs refreshing.
nonisolated struct SimklTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// Unix timestamp (seconds) when the access token was issued — captured
    /// client-side, as Simkl's token response carries no `created_at`.
    var issuedAt: TimeInterval
    /// Lifetime of the access token in seconds — Simkl's `expires_in` (7 days).
    var expiresIn: TimeInterval
    var scope: String?
    var tokenType: String?

    /// Absolute moment the access token expires.
    var expiryDate: Date {
        Date(timeIntervalSince1970: issuedAt + expiresIn)
    }

    /// Whether the token has expired or is within a day of doing so. Simkl
    /// access tokens last a week, so refreshing a day early is cheap insurance.
    var needsRefresh: Bool {
        expiryDate.timeIntervalSinceNow < 60 * 60 * 24
    }
}

/// The Simkl token pair in the keychain (`TrackerTokenStoring`), carried
/// between devices through iCloud.
nonisolated enum SimklTokenStore: TrackerTokenStoring {
    typealias Tokens = SimklTokens
    static let item = CredentialItem(service: "bilipp.Lume.simkl", account: "oauth-tokens", accessibility: .afterFirstUnlock)
    static let syncedCredential: SyncedCredentialKind? = .simkl
}

// MARK: - Account identity

nonisolated struct SimklAccountIdentity: Codable, Equatable {
    let username: String
    /// The outbox partition for this account: the stable Simkl account id
    /// where the settings response carries one, else the normalized username.
    let scope: String

    init(username: String, scope: String) {
        self.username = username
        self.scope = scope
    }

    init(settings: SimklUserSettings) {
        username = settings.user.name
        if let id = settings.account?.id {
            scope = "simkl:\(id)"
        } else {
            scope = "username:\(Self.normalized(settings.user.name))"
        }
    }

    /// The partition the outbox used before identities were persisted — the
    /// bare normalized username. Changes queued under it are adopted into
    /// `scope` so an upgrade doesn't strand them.
    var legacyScope: String {
        Self.normalized(username)
    }

    private static func normalized(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Remembers the Simkl account (`TrackerAccountIdentityStoring`).
nonisolated enum SimklAccountIdentityStore: TrackerAccountIdentityStoring {
    typealias Identity = SimklAccountIdentity
    static let key = "simkl.lastAccountIdentity.v1"
}
