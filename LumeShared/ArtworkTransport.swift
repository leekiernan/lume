import Foundation

/// Artwork authentication is explicit in ArtworkRequest. An ambient HTTP cache,
/// cookie or credential must not bypass its account-isolated cache identity.
nonisolated enum ArtworkTransport {
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }
}
