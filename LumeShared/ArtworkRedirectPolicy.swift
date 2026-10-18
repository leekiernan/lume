import Foundation

/// Custom token headers are not automatically stripped like Authorization.
/// Never forward a media-server credential to a different origin on redirect.
final nonisolated class ArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate {
    static let shared = ArtworkRedirectPolicy()
    private static let credentialNames: Set = ["x-plex-token", "api_key", "apikey"]

    static func redirect(_ request: URLRequest, from previous: URL) -> URLRequest? {
        guard let next = request.url else { return nil }
        guard !sameOrigin(next, previous) else { return request }
        // Do not rewrite a nested return URL: it may participate in a signature.
        // Refuse the hop if it embeds credentials, or cannot be checked within
        // the bounded inspection budget. Harmless redirects retain their bytes.
        guard !hasUnsafeEmbeddedURL(next) else { return nil }
        var safe = request
        for name in ["Authorization", "X-Plex-Token", "X-Emby-Token"] {
            safe.setValue(nil, forHTTPHeaderField: name)
        }
        // Jellyfin's `ApiKey` travels in the query. A `Location` that echoes the
        // original query would carry it to the new host, so credential items and
        // userinfo go too. Generic names (`token`, `sig`) stay: a CDN's signed
        // URL may depend on them.
        safe.url = withoutCredentials(next)
        return safe
    }

    static func withoutCredentials(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let items = components.queryItems?.filter { !credentialNames.contains($0.name.lowercased()) }
        guard components.user != nil || components.password != nil || items?.count != components.queryItems?.count else { return url }
        components.user = nil
        components.password = nil
        components.queryItems = items?.isEmpty == true ? nil : items
        return components.url ?? url
    }

    /// Query values are decoded for inspection only, never for transport. This
    /// catches URL-valued parameters at any name, with nested or repeatedly
    /// percent-encoded return addresses, without damaging signed CDN queries.
    private static func hasUnsafeEmbeddedURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        var budget = 65536
        return unsafeQuery(components, depth: 0, allowsCredentials: true, budget: &budget)
    }

    private static func unsafeEmbeddedValue(_ raw: String, depth: Int, budget: inout Int) -> Bool {
        guard depth < 8 else { return true }
        var value = raw
        for _ in 0 ..< 8 {
            budget -= value.utf8.count
            guard budget >= 0 else { return true }
            let decoded = decodingASCIIEscapes(value)
            if decoded == value {
                guard let components = URLComponents(string: value) else { return false }
                if components.percentEncodedUser != nil || components.percentEncodedPassword != nil { return true }
                return unsafeQuery(components, depth: depth + 1, allowsCredentials: false, budget: &budget)
            }
            value = decoded
        }
        return true
    }

    private static func unsafeQuery(_ components: URLComponents, depth: Int, allowsCredentials: Bool, budget: inout Int) -> Bool {
        // Read encoded values: queryItems drops a value containing non-UTF8
        // escapes, which could hide a return URL, or be an innocent binary sig.
        let query = components.percentEncodedQuery ?? ""
        budget -= query.utf8.count
        guard budget >= 0 else { return true }
        for field in query.split(separator: "&") {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if credentialNames.contains(decodingASCIIEscapes(String(pair[0])).lowercased()) {
                if allowsCredentials { continue } // Removed from the outer URL.
                return true
            }
            if pair.count == 2, unsafeEmbeddedValue(String(pair[1]), depth: depth, budget: &budget) { return true }
        }
        return false
    }

    /// Decode ASCII syntax only. Opaque non-UTF8 signature bytes stay encoded;
    /// they cannot hide URL separators or the ASCII authentication key names.
    private static func decodingASCIIEscapes(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37, index + 2 < bytes.count,
               let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]), high < 8
            {
                result.append(high * 16 + low)
                index += 3
            } else {
                result.append(bytes[index])
                index += 1
            }
        }
        return String(bytes: result, encoding: .utf8) ?? value
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48 ... 57: byte - 48
        case 65 ... 70: byte - 55
        case 97 ... 102: byte - 87
        default: nil
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
