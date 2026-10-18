import CryptoKit
import Foundation

/// Transport authentication is not artwork identity. Explicit account scopes
/// survive token rotation; legacy URL-only callers use a credential fingerprint
/// rather than risk sharing private artwork across accounts on the same server.
nonisolated struct ArtworkRequest: Hashable {
    let url: URL
    let headers: [String: String]
    let cacheIdentity: String
    /// Credential-sensitive in-flight/failure key, computed once. Successful
    /// decoded/disk images use cacheIdentity and survive token rotation.
    let transportIdentity: String

    init?(url original: URL, accountScope: String? = nil) {
        guard ["http", "https"].contains(original.scheme?.lowercased() ?? ""), original.host != nil,
              var components = URLComponents(url: original, resolvingAgainstBaseURL: false) else { return nil }
        var headers: [String: String] = [:]
        if let username = components.user {
            headers["Authorization"] = "Basic " + Data("\(username):\(components.password ?? "")".utf8).base64EncodedString()
            components.user = nil
            components.password = nil
        }
        var retained: [URLQueryItem] = []
        for item in components.queryItems ?? [] {
            switch item.name.lowercased() {
            case "x-plex-token": headers["X-Plex-Token"] = item.value
            case "api_key" where components.path.lowercased().contains("/images/"):
                headers["X-Emby-Token"] = item.value
            default: retained.append(item)
            }
        }
        components.queryItems = retained.isEmpty ? nil : retained
        guard let url = components.url else { return nil }
        self.url = url
        self.headers = headers
        let authentication = headers.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: "\n")
        // Canonical Jellyfin ApiKey must remain in transport: X-Emby-Token
        // alone requires legacy authorization. It is authentication, not image
        // identity. Without an explicit account scope, fingerprint every token
        // (including duplicate aliases) so distinct accounts cannot share art.
        var identityURL = url
        if accountScope != nil, components.path.lowercased().contains("/images/") {
            components.queryItems = retained.filter { $0.name.lowercased() != "apikey" }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
            identityURL = components.url ?? url
        }
        let scope = accountScope ?? authentication
        // Preserve existing public-image cache entries and offline artwork.
        // Recognized private requests use opaque, account-isolated identities.
        let isPublic = headers.isEmpty && accountScope == nil && !Self.carriesCredentials(original)
        cacheIdentity = isPublic
            ? original.absoluteString : Self.digest(identityURL.absoluteString + "\n" + scope)
        transportIdentity = isPublic ? cacheIdentity : Self.digest(cacheIdentity + "\n" + url.absoluteString + "\n" + authentication)
    }

    var request: URLRequest {
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        return request
    }

    static func carriesCredentials(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        if components.user != nil || components.password != nil { return true }
        let keys: Set = ["x-plex-token", "api_key", "apikey", "access_token", "token", "password", "username", "authorization"]
        return (components.queryItems ?? []).contains { keys.contains($0.name.lowercased()) }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
