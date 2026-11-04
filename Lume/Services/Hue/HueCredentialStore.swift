//
//  HueCredentialStore.swift
//  Lume
//
//  The one paired Hue Bridge: its id and host in UserDefaults, its application
//  key, client key and pinned certificate in the keychain (through
//  `CredentialBackend`, so tests never reach the real one). Device-local only —
//  never iCloud Keychain, never SwiftData — and one bridge per device, so
//  pairing another forgets the first.
//

import Foundation

nonisolated struct HueBridgeAddress: Hashable {
    /// The bridge id, lowercase hex as the bridge reports it; also its
    /// certificate's common name.
    var id: String
    var host: String
}

/// What the keychain holds for a bridge.
nonisolated struct HueBridgeSecrets: Codable, Hashable {
    var credentials: HueBridgeCredentials
    /// SHA-256 of the bridge's leaf certificate, pinned on first use when the
    /// chain doesn't verify against the Signify root.
    var certificatePin: Data?
}

nonisolated extension HueBridgeSecrets: HueRedacted {}

/// Prints and mirrors as `TypeName(redacted)`, so a secret or LAN address
/// never reaches a log through interpolation or `dump`.
nonisolated protocol HueRedacted: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {}

nonisolated extension HueRedacted {
    var description: String {
        "\(Self.self)(redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

nonisolated struct HueCredentialStore {
    static let service = "bilipp.Lume.hue"

    private typealias Keys = PlayerSettings.Hue

    var defaults: UserDefaults
    var storage: any CredentialStorage

    /// - Parameter storage: nil resolves `CredentialBackend.current` — the
    ///   keychain in the app, in-memory storage under tests.
    init(defaults: UserDefaults = .standard, storage: (any CredentialStorage)? = nil) {
        self.defaults = defaults
        self.storage = storage ?? CredentialBackend.current.storage
    }

    /// The paired bridge, or nil when none is paired or its keys are gone.
    var pairedBridge: HueBridgeAddress? {
        pairedBridgeAndSecrets()?.address
    }

    /// A bridge id and host are stored; doesn't reach the keychain, so the
    /// keys may still be missing.
    var hasPairing: Bool {
        pairedID != nil && !(defaults.string(forKey: Keys.bridgeHostKey) ?? "").isEmpty
    }

    /// The paired bridge with its secrets, read from the keychain once; nil
    /// when none is paired or on any keychain or decode miss.
    func pairedBridgeAndSecrets() -> (address: HueBridgeAddress, secrets: HueBridgeSecrets)? {
        guard let id = pairedID,
              let host = defaults.string(forKey: Keys.bridgeHostKey), !host.isEmpty,
              let secrets = loadSecrets(bridgeID: id)
        else { return nil }
        return (HueBridgeAddress(id: id, host: host), secrets)
    }

    /// The paired bridge's secrets, or nil on any keychain or decode miss.
    func loadSecrets() -> HueBridgeSecrets? {
        pairedID.flatMap(loadSecrets(bridgeID:))
    }

    private var pairedID: String? {
        guard let id = defaults.string(forKey: Keys.bridgeIDKey), !id.isEmpty else { return nil }
        return id
    }

    /// Stores a newly paired bridge. A different bridge paired before is
    /// forgotten first, with its area choice and pending restore.
    @discardableResult
    func savePairing(_ secrets: HueBridgeSecrets, for bridge: HueBridgeAddress) -> Bool {
        if let previous = defaults.string(forKey: Keys.bridgeIDKey), previous != bridge.id {
            forget()
        }
        guard let data = try? JSONEncoder().encode(secrets),
              storage.write(data, to: Self.item(bridgeID: bridge.id))
        else { return false }
        defaults.set(bridge.id, forKey: Keys.bridgeIDKey)
        defaults.set(bridge.host, forKey: Keys.bridgeHostKey)
        return true
    }

    /// Removes the paired bridge's keys, address, area choice and pending
    /// restore. Nothing paired counts as success.
    @discardableResult
    func forget() -> Bool {
        var removed = true
        if let id = defaults.string(forKey: Keys.bridgeIDKey) {
            removed = storage.delete(Self.item(bridgeID: id))
        }
        defaults.removeObject(forKey: Keys.bridgeIDKey)
        defaults.removeObject(forKey: Keys.bridgeHostKey)
        Keys.setEntertainmentAreaID(nil, in: defaults)
        Keys.clearRestoreSnapshot(in: defaults)
        return removed
    }

    /// One item per bridge, keyed by its id. Readable after first unlock, so a
    /// session can start while the screen is locked (tvOS has no lock, iOS might
    /// later).
    private static func item(bridgeID: String) -> CredentialItem {
        CredentialItem(service: service, account: bridgeID, accessibility: .afterFirstUnlock)
    }

    private func loadSecrets(bridgeID: String) -> HueBridgeSecrets? {
        guard case let .found(data) = storage.read(Self.item(bridgeID: bridgeID)) else { return nil }
        return try? JSONDecoder().decode(HueBridgeSecrets.self, from: data)
    }
}
