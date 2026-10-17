import Foundation

/// Custom token headers are not automatically stripped like Authorization.
/// Never forward a media-server credential to a different origin on redirect.
final nonisolated class ArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate {
    static let shared = ArtworkRedirectPolicy()

    static func redirect(_ request: URLRequest, from previous: URL) -> URLRequest {
        guard let next = request.url else { return request }
        func origin(_ url: URL) -> String {
            let scheme = url.scheme?.lowercased() ?? ""
            return "\(scheme)://\(url.host?.lowercased() ?? ""):\(url.port ?? (scheme == "https" ? 443 : 80))"
        }
        guard origin(next) != origin(previous) else { return request }
        var safe = request
        for name in ["Authorization", "X-Plex-Token", "X-Emby-Token"] {
            safe.setValue(nil, forHTTPHeaderField: name)
        }
        return safe
    }

    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        guard let previous = response.url else { completionHandler(nil); return }
        completionHandler(Self.redirect(request, from: previous))
    }
}
