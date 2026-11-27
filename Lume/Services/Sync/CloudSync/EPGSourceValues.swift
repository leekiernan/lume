import Foundation

/// The syncable fields of a *manual* `EPGSource`. Conflicts resolve cloud-wins,
/// like playlist config — EPG sources are shared truth that rarely change on two
/// devices at once.
///
/// Like `PlaylistConfigValues`, `Codable` writes only a digest of the fields:
/// the shadow baseline lives in `UserDefaults`, and a guide URL often carries
/// the provider's username and password in its query string
/// (`xmltv.php?username=…&password=…`). A value decoded from the shadow has
/// empty fields, which is harmless: the merge only compares a baseline, and
/// every verdict payload comes from the local catalog or the cloud mirror.
nonisolated struct EPGSourceValues: Codable, Equatable {
    var name: String
    var url: String
    var isEnabled: Bool
    /// The digest a shadow baseline was decoded with; nil on a live value.
    private var decodedFingerprint: String?
    /// True when decoded from the pre-fingerprint format, which stored the
    /// fields themselves; the shadow rewrites it at once.
    private(set) var decodedFromPlaintext = false

    init(name: String, url: String, isEnabled: Bool) {
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
    }

    /// The merge's entire notion of identity.
    var fingerprint: String {
        decodedFingerprint ?? Self.fingerprint(name: name, url: url, isEnabled: isEnabled)
    }

    static func == (lhs: EPGSourceValues, rhs: EPGSourceValues) -> Bool {
        lhs.fingerprint == rhs.fingerprint
    }

    static func mergeConflict(local _: EPGSourceValues, cloud: EPGSourceValues) -> EPGSourceValues {
        cloud
    }

    private enum CodingKeys: String, CodingKey {
        case fingerprint
    }

    /// The fields of the pre-fingerprint format, read only to migrate it.
    private enum PlaintextCodingKeys: String, CodingKey {
        case name, url, isEnabled
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fingerprint, forKey: .fingerprint)
    }

    /// Decodes a fingerprint baseline, or migrates a plaintext one by digesting
    /// its fields exactly as a live value would, so the migration reads as "no
    /// change" rather than triggering a spurious reconcile.
    nonisolated init(from decoder: any Decoder) throws {
        name = ""
        url = ""
        isEnabled = false

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint) {
            decodedFingerprint = fingerprint
            return
        }
        let plaintext = try decoder.container(keyedBy: PlaintextCodingKeys.self)
        decodedFingerprint = try Self.fingerprint(
            name: plaintext.decode(String.self, forKey: .name),
            url: plaintext.decode(String.self, forKey: .url),
            isEnabled: plaintext.decode(Bool.self, forKey: .isEnabled)
        )
        decodedFromPlaintext = true
    }

    private static func fingerprint(name: String, url: String, isEnabled: Bool) -> String {
        ShadowFingerprint.digest([name, url, ShadowFingerprint.component(isEnabled)])
    }
}
