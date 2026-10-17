import Foundation

/// Authenticated API calls and directory discovery stay on their configured
/// origin. Refuse the redirect entirely: removing headers would still forward
/// a login POST's body, and accepting a foreign listing could prune a catalogue.
final nonisolated class SameOriginRedirectPolicy: NSObject, URLSessionTaskDelegate {
    static let shared = SameOriginRedirectPolicy()

    static func allows(from original: URL, to target: URL) -> Bool {
        guard let origin = HTTPOrigin(original) else { return false }
        return origin == HTTPOrigin(target)
    }

    func urlSession(_: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        guard let original = task.originalRequest?.url ?? response.url, let target = request.url, Self.allows(from: original, to: target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
