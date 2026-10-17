import Foundation

/// Directory discovery never needs to leave the configured server. Reject a
/// cross-origin redirect rather than authenticate it or treat its listing as
/// an authoritative empty share (which would prune the local catalogue).
final nonisolated class WebDAVRedirectPolicy: NSObject, URLSessionTaskDelegate {
    static let shared = WebDAVRedirectPolicy()

    static func allows(from original: URL, to target: URL) -> Bool {
        guard let origin = HTTPOrigin(original) else { return false }
        return origin == HTTPOrigin(target)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        guard let original = response.url, let target = request.url, Self.allows(from: original, to: target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
