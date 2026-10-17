import Foundation

/// Authenticated API calls and directory discovery stay on their configured
/// origin. Refuse the redirect entirely: removing headers would still forward
/// a login POST's body, and accepting a foreign listing could prune a catalogue.
///
/// Media-server APIs also follow the same host upgrading to HTTPS
/// (`HTTPOrigin.admits`): a server typed as `http://` behind a TLS proxy.
/// WebDAV does not: its listings are checked against the configured root's
/// origin (`WebDAVPathIdentity`), so an upgraded listing would read as empty.
final nonisolated class SameOriginRedirectPolicy: NSObject, URLSessionTaskDelegate {
    static let shared = SameOriginRedirectPolicy(followsHTTPSUpgrade: false)
    static let mediaServer = SameOriginRedirectPolicy(followsHTTPSUpgrade: true)

    private let followsHTTPSUpgrade: Bool

    private init(followsHTTPSUpgrade: Bool) {
        self.followsHTTPSUpgrade = followsHTTPSUpgrade
    }

    static func allows(from original: URL, to target: URL, followsHTTPSUpgrade: Bool = false) -> Bool {
        guard let origin = HTTPOrigin(original), let target = HTTPOrigin(target) else { return false }
        return followsHTTPSUpgrade ? origin.admits(target) : origin == target
    }

    func urlSession(_: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        guard let original = task.originalRequest?.url ?? response.url, let target = request.url,
              Self.allows(from: original, to: target, followsHTTPSUpgrade: followsHTTPSUpgrade)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
