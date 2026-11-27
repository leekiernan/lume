import Foundation

/// The syncable fields of a `Playlist`. Conflicts resolve last-write-wins
/// favouring the cloud (see `mergeConflict`), since playlist config is shared
/// truth that rarely changes on two devices at once.
///
/// Like `ParentalPINValues`, the fields are the payload and a digest of them is
/// the identity. `Codable` writes only that digest: the shadow baseline lives in
/// `UserDefaults`, and the fields hold provider credentials — the password, and
/// often the username and password again inside an M3U server or guide URL. A
/// value decoded from the shadow therefore has empty fields, which is harmless:
/// the merge only compares a baseline, and every verdict payload comes from the
/// local catalog or the cloud mirror (whose credentials CloudKit encrypts).
nonisolated struct PlaylistConfigValues: Codable, Equatable {
    var name: String
    var serverURL: String
    var username: String
    var password: String
    var macAddress: String
    var sourceTypeRaw: String
    var epgURL: String?
    var syncEnabled: Bool
    var syncFrequencyRaw: String?
    /// The digest a shadow baseline was decoded with; nil on a live value, whose
    /// digest is computed from its fields so an edited field is never stale.
    private var decodedFingerprint: String?
    /// True when this baseline was decoded from the pre-fingerprint format,
    /// which stored the fields themselves; the shadow rewrites it at once.
    private(set) var decodedFromPlaintext = false

    /// The merge's entire notion of identity.
    var fingerprint: String {
        decodedFingerprint ?? Self.fingerprint(
            name: name,
            serverURL: serverURL,
            username: username,
            password: password,
            macAddress: macAddress,
            sourceTypeRaw: sourceTypeRaw,
            epgURL: epgURL,
            syncEnabled: syncEnabled,
            syncFrequencyRaw: syncFrequencyRaw
        )
    }

    static func == (lhs: PlaylistConfigValues, rhs: PlaylistConfigValues) -> Bool {
        lhs.fingerprint == rhs.fingerprint
    }

    init(
        name: String,
        serverURL: String,
        username: String,
        password: String,
        macAddress: String = "",
        sourceTypeRaw: String,
        epgURL: String?,
        syncEnabled: Bool,
        syncFrequencyRaw: String? = nil
    ) {
        self.name = name
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.macAddress = macAddress
        self.sourceTypeRaw = sourceTypeRaw
        self.epgURL = epgURL
        self.syncEnabled = syncEnabled
        self.syncFrequencyRaw = syncFrequencyRaw
    }

    private enum CodingKeys: String, CodingKey {
        case fingerprint
    }

    /// The fields of the pre-fingerprint format, read only to migrate it.
    private enum PlaintextCodingKeys: String, CodingKey {
        case name, serverURL, username, password, macAddress, sourceTypeRaw, epgURL, syncEnabled, syncFrequencyRaw
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fingerprint, forKey: .fingerprint)
    }

    /// Decodes a fingerprint baseline, or migrates a plaintext one by digesting
    /// its fields exactly as a live value would, so the migration reads as "no
    /// change" rather than triggering a spurious reconcile. A plaintext baseline
    /// persisted before Stalker support has no `macAddress` key; it falls back
    /// to "" rather than failing (and discarding) the whole baseline.
    nonisolated init(from decoder: any Decoder) throws {
        name = ""
        serverURL = ""
        username = ""
        password = ""
        macAddress = ""
        sourceTypeRaw = ""
        epgURL = nil
        syncEnabled = false
        syncFrequencyRaw = nil

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint) {
            decodedFingerprint = fingerprint
            return
        }
        let plaintext = try decoder.container(keyedBy: PlaintextCodingKeys.self)
        decodedFingerprint = try Self.fingerprint(
            name: plaintext.decode(String.self, forKey: .name),
            serverURL: plaintext.decode(String.self, forKey: .serverURL),
            username: plaintext.decode(String.self, forKey: .username),
            password: plaintext.decode(String.self, forKey: .password),
            macAddress: plaintext.decodeIfPresent(String.self, forKey: .macAddress) ?? "",
            sourceTypeRaw: plaintext.decode(String.self, forKey: .sourceTypeRaw),
            epgURL: plaintext.decodeIfPresent(String.self, forKey: .epgURL),
            syncEnabled: plaintext.decode(Bool.self, forKey: .syncEnabled),
            syncFrequencyRaw: plaintext.decodeIfPresent(String.self, forKey: .syncFrequencyRaw)
        )
        decodedFromPlaintext = true
    }

    // swiftlint:disable:next function_parameter_count
    private static func fingerprint(
        name: String,
        serverURL: String,
        username: String,
        password: String,
        macAddress: String,
        sourceTypeRaw: String,
        epgURL: String?,
        syncEnabled: Bool,
        syncFrequencyRaw: String?
    ) -> String {
        ShadowFingerprint.digest([
            name, serverURL, username, password, macAddress, sourceTypeRaw,
            ShadowFingerprint.component(epgURL),
            ShadowFingerprint.component(syncEnabled),
            ShadowFingerprint.component(syncFrequencyRaw)
        ])
    }

    /// Whether a sync would reach the provider differently: the fields it
    /// logs in with. A rename or a new guide URL can't turn a failed sync
    /// into a working one, so they don't count.
    func connectsDifferently(from other: PlaylistConfigValues) -> Bool {
        serverURL != other.serverURL || username != other.username || password != other.password
            || macAddress != other.macAddress || sourceTypeRaw != other.sourceTypeRaw
    }

    /// Conflict policy: cloud wins. Deterministic and adequate for config.
    static func mergeConflict(local _: PlaylistConfigValues, cloud: PlaylistConfigValues) -> PlaylistConfigValues {
        cloud
    }
}
