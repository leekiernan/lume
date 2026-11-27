import CryptoKit
import Foundation

/// The digest a `CloudSyncShadow` baseline stores in place of values that can
/// carry provider credentials. The baseline lives in `UserDefaults` and is only
/// ever compared, so a digest preserves everything the three-way merge needs.
nonisolated enum ShadowFingerprint {
    /// SHA-256 over the length-prefixed components, so embedded separators
    /// cannot make two different value sets produce the same byte stream.
    static func digest(_ components: [String]) -> String {
        let canonical = components
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Encodes an optional so that nil and "" stay distinct.
    static func component(_ value: String?) -> String {
        value.map { "+\($0)" } ?? "-"
    }

    static func component(_ value: Bool) -> String {
        value ? "1" : "0"
    }
}
