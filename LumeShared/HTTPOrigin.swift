import Foundation

/// An HTTP authority, not a string prefix: default ports and host casing are
/// equivalent, but changing scheme, host or effective port crosses the boundary.
nonisolated struct HTTPOrigin: Hashable {
    let scheme: String
    let host: String
    let port: Int

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}
