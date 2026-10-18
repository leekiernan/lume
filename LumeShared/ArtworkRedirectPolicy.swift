import Foundation

/// Custom token headers are not automatically stripped like Authorization.
/// Never forward a media-server credential to a different origin on redirect.
final nonisolated class ArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate {
    static let shared = ArtworkRedirectPolicy()

    static func redirect(_ request: URLRequest, from previous: URL) -> URLRequest {
        guard let next = request.url else { return request }
        guard !sameOrigin(next, previous) else { return request }
        var safe = request
        for name in ["Authorization", "X-Plex-Token", "X-Emby-Token"] {
            safe.setValue(nil, forHTTPHeaderField: name)
        }
        // Jellyfin's `ApiKey` travels in the query. A `Location` that echoes the
        // original address (an SSO gateway's `?rd=`, a proxy keeping the query)
        // would carry it to the new host, so media-server credential items and
        // userinfo go too. Generic names (`token`, `sig`) stay: a CDN's signed
        // URL may depend on them.
        safe.url = withoutCredentials(next)
        return safe
    }

    static func withoutCredentials(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let credentials: Set = ["x-plex-token", "api_key", "apikey"]
        let items = components.queryItems?.filter { !credentials.contains($0.name.lowercased()) }
        guard components.user != nil || components.password != nil || items?.count != components.queryItems?.count else { return url }
        components.user = nil
        components.password = nil
        components.queryItems = items?.isEmpty == true ? nil : items
        return components.url ?? url
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
