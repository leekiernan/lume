import CryptoKit
import Foundation
import os

/// The digest a `CloudSyncShadow` baseline stores in place of values that can
/// carry provider credentials. The baseline lives in `UserDefaults` and is only
/// ever compared, so a digest preserves everything the three-way merge needs.
///
/// The digest is an HMAC under a random per-device key, not a bare hash: a
/// provider password is often short, and a plain SHA-256 of it in a readable
/// preferences file could be reversed by guessing. The key lives in a
/// this-device-only keychain item (never synced or backed up).
///
/// Losing the key is safe. Every stored fingerprint then stops matching, so the
/// next reconcile reads both sides as changed and resolves each playlist and
/// guide source by its normal conflict policy (the cloud's value), then
/// re-baselines under the new key — the same one-time degradation as a lost
/// shadow, never a deletion. That is what happens after restoring a device
/// backup, which carries the shadow but not the key.
nonisolated enum ShadowFingerprint {
    static let keyItem = CredentialItem(
        service: "lume.cloudsync.shadowFingerprintKey",
        account: "v1",
        accessibility: .afterFirstUnlockThisDeviceOnly
    )

    private static let keyByteCount = 32

    /// The key for this process, loaded or created on first use. Cached so the
    /// merge's many comparisons never touch the keychain, and so every
    /// fingerprint in a process agrees even if the keychain later fails.
    private static let cachedKey = OSAllocatedUnfairLock<Data?>(initialState: nil)

    /// HMAC-SHA256 over the length-prefixed components, under this device's key.
    static func digest(_ components: [String]) -> String {
        digest(components, key: key())
    }

    /// The keyed digest under an explicit key.
    static func digest(_ components: [String], key: Data) -> String {
        // Length-prefix every component so embedded separators cannot make two
        // different value sets produce the same byte stream.
        let canonical = components
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        let code = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: SymmetricKey(data: key))
        return Data(code).map { String(format: "%02x", $0) }.joined()
    }

    /// Encodes an optional so that nil and "" stay distinct.
    static func component(_ value: String?) -> String {
        value.map { "+\($0)" } ?? "-"
    }

    static func component(_ value: Bool) -> String {
        value ? "1" : "0"
    }

    private static func key() -> Data {
        cachedKey.withLock { cached in
            if let cached { return cached }
            let key = loadOrCreateKey(in: CredentialBackend.current.storage)
            cached = key
            return key
        }
    }

    /// Reads this device's key, creating and storing one if there is none (or
    /// the stored one is malformed). If the keychain can't be read or written,
    /// returns a key for this process only: fingerprints then won't match the
    /// persisted baseline, which degrades exactly like a lost key (see above).
    static func loadOrCreateKey(in storage: any CredentialStorage) -> Data {
        switch storage.read(keyItem) {
        case let .found(data) where data.count == keyByteCount:
            return data
        case .found, .notFound:
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            if !storage.write(key, to: keyItem) {
                Logger.sync.error("Sync shadow fingerprint key could not be stored; using a key for this launch only")
            }
            return key
        case .unavailable:
            Logger.sync.error("Sync shadow fingerprint key is unreadable; using a key for this launch only")
            return SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        }
    }
}
