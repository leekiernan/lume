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

    /// Where an authenticated redirect may keep its credentials: this origin,
    /// or the same host upgraded to HTTPS (a proxy's `http://` → `https://`,
    /// Jellyfin's 8096 → 8920). TLS then proves the host name, whatever the
    /// port; plain HTTP to another port stays a different origin.
    func admits(_ target: HTTPOrigin?) -> Bool {
        guard let target else { return false }
        return target == self || (target.host == host && scheme == "http" && target.scheme == "https")
    }
}
