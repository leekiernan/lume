//
//  TrackerTokenStore.swift
//  Lume
//
//  The keychain half of a tracker sign-in, shared by Trakt, Simkl and
//  MDBList. A conformer names its keychain item and, when the pair travels
//  between devices through iCloud, the credential whose link state follows it
//  (`CredentialLinkState`); reading, writing and the disconnect bookkeeping
//  are shared. The keychain work goes through `CredentialBackend`, and items
//  use `AfterFirstUnlock` so a refresh can succeed while the device is locked.
//
//  The remembered account identity (not secret) is kept in defaults by
//  `TrackerAccountIdentityStoring`.
//

import Foundation

/// A stored token pair, or why there isn't one. A sync reconcile must tell a
/// missing token from a keychain read that failed while the device was
/// locked: treating the latter as a disconnect would delete the shared
/// authorization from every device.
nonisolated enum TrackerStoredTokens<Tokens: Equatable>: Equatable {
    case tokens(Tokens)
    case notSet
    case unavailable
}

nonisolated protocol TrackerTokenStoring {
    associatedtype Tokens: Codable & Equatable
    static var item: CredentialItem { get }
    /// The credential synced through iCloud, or nil for a pair that stays on
    /// this device (MDBList).
    static var syncedCredential: SyncedCredentialKind? { get }
}

nonisolated extension TrackerTokenStoring {
    typealias StoredTokens = TrackerStoredTokens<Tokens>

    static func storedTokens() -> StoredTokens {
        switch CredentialBackend.current.storage.read(item) {
        case .notFound:
            return .notSet
        case .unavailable:
            return .unavailable
        case let .found(data):
            guard let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else { return .unavailable }
            return .tokens(tokens)
        }
    }

    /// The stored pair, or nil if it is absent or temporarily unreadable.
    /// UI/network callers don't need that distinction; the CloudKit
    /// reconciler uses `storedTokens()` when it matters.
    static func load() -> Tokens? {
        guard case let .tokens(tokens) = storedTokens() else { return nil }
        return tokens
    }

    /// Saves the pair, replacing any existing one — a sign-in, a refresh, or
    /// a pair pulled from another device. Any of those means the account is
    /// connected here again.
    @discardableResult
    static func save(_ tokens: Tokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens),
              CredentialBackend.current.storage.write(data, to: item)
        else { return false }
        if let syncedCredential { CredentialLinkStateStore.apply(.credentialStored, to: syncedCredential) }
        return true
    }

    /// Removes the stored pair. A missing item is success: the desired end
    /// state is already met. Not a user decision on its own — the sync
    /// reconcile calls this to apply another device's disconnect.
    @discardableResult
    static func clear() -> Bool {
        CredentialBackend.current.storage.delete(item)
    }

    /// The user's explicit Disconnect: records the decision before the token
    /// goes, so the iCloud reconcile propagates the removal to every device
    /// rather than restoring the token as if the keychain had merely lost it.
    @discardableResult
    static func clearForUserDisconnect() -> Bool {
        guard let syncedCredential else { return clear() }
        CredentialLinkStateStore.apply(.userDisconnected, to: syncedCredential)
        guard clear() else {
            CredentialLinkStateStore.apply(.removalFailed, to: syncedCredential)
            return false
        }
        return true
    }
}

/// The account a tracker's tokens belong to, remembered in defaults so an
/// offline cold launch stays connected and keeps queueing account-scoped
/// changes; the next successful identity lookup refreshes it.
nonisolated protocol TrackerAccountIdentityStoring {
    associatedtype Identity: Codable
    static var key: String { get }
}

nonisolated extension TrackerAccountIdentityStoring {
    static func load(defaults: UserDefaults = .standard) -> Identity? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Identity.self, from: data)
    }

    static func save(_ identity: Identity, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
