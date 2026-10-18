import Foundation

/// A credentialed artwork request never leaves its server. Every cross-origin
/// redirect of one is refused, except the same host upgrading to HTTPS
/// (`HTTPOrigin.admits`), which keeps its credentials as the API clients do.
///
/// Inspecting the new address for the credential could not be made complete:
/// a gateway can carry it in a return URL's path, its fragment, a semicolon
/// query, base64, or under any name. Nothing legitimate is lost by refusing.
/// Private artwork is served by the media server itself; a hop elsewhere is
/// an SSO or forward-auth login page — HTML, not an image — or a
/// misconfiguration, and a target that needed the credential would fail
/// anyway once it was withheld.
///
/// Public artwork (no credential attached) follows redirects as before.
final nonisolated class ArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate {
    static let shared = ArtworkRedirectPolicy()
    private static let credentialHeaders = ["Authorization", "X-Plex-Token", "X-Emby-Token"]
    private static let credentialQueryNames: Set = ["x-plex-token", "api_key", "apikey"]

    static func redirect(_ request: URLRequest, from previous: URL) -> URLRequest? {
        guard let next = request.url, HTTPOrigin(next) != nil else { return nil }
        guard let origin = HTTPOrigin(previous), !origin.admits(HTTPOrigin(next)) else { return request }
        return isCredentialed(request, previous: previous) ? nil : request
    }

    /// What this policy guards: the token headers `ArtworkRequest` attaches,
    /// or a media-server key or userinfo in the address. Generic names a
    /// public or signed CDN URL uses (`token`, `sig`) don't count.
    static func isCredentialed(_ request: URLRequest, previous: URL) -> Bool {
        if credentialHeaders.contains(where: { request.value(forHTTPHeaderField: $0) != nil }) { return true }
        return [previous, request.url].compactMap(\.self).contains { url in
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
            if components.user != nil || components.password != nil { return true }
            return (components.queryItems ?? []).contains { credentialQueryNames.contains($0.name.lowercased()) }
        }
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        guard let origin = HTTPOrigin(first) else { return false }
        return origin == HTTPOrigin(second)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        guard let previous = response.url, let next = request.url, HTTPOrigin(next) != nil else { completionHandler(nil); return }
        completionHandler(Self.redirect(request, from: previous))
    }
}
