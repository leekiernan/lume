import Foundation
@testable import Lume
import Testing

@MainActor
struct StreamRedirectTests {
    @Test func `a server ignoring Range does not have to finish its body`() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeaderOnlyStreamProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let start = ContinuousClock.now
        #expect(await StreamRedirect.resolve(provider, session: session) == nil)
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test func `a cancelled probe does not wait for its timeout`() async {
        let start = ContinuousClock.now
        let task = Task { await StreamRedirect.resolve(provider) }
        task.cancel()
        #expect(await task.value == nil)
        #expect(start.duration(to: .now) < .seconds(2))
    }

    private let provider = URL(string: "https://provider.test/series/user/pass/42.mkv")!

    private func media(
        url: URL? = nil,
        kind: PlayableMedia.Kind = .vod,
        headers: [String: String]? = nil
    ) -> PlayableMedia {
        PlayableMedia(
            id: "episode", url: url ?? provider, title: "Episode", subtitle: nil, posterURL: nil,
            kind: kind, startTime: 0, contentRef: .episode("episode"), httpHeaders: headers
        )
    }

    private func response(_ status: Int, location: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: provider, statusCode: status, httpVersion: "HTTP/2",
            headerFields: location.map { ["Location": $0] }
        )!
    }

    @Test func `a temporary redirect resolves to its location`() {
        let target = StreamRedirect.target(
            of: response(302, location: "https://cdn.test:8443/live/play/TOKEN/42"), for: provider
        )
        #expect(target == URL(string: "https://cdn.test:8443/live/play/TOKEN/42"))
    }

    @Test func `a relative location resolves against the provider URL`() {
        let target = StreamRedirect.target(of: response(307, location: "/play/TOKEN/42"), for: provider)
        #expect(target == URL(string: "https://provider.test/play/TOKEN/42"))
    }

    @Test func `a direct stream has no target`() {
        #expect(StreamRedirect.target(of: response(206, location: nil), for: provider) == nil)
        #expect(StreamRedirect.target(of: response(200, location: "https://cdn.test/x"), for: provider) == nil)
    }

    @Test func `a redirect off HTTP is not followed`() {
        #expect(StreamRedirect.target(of: response(302, location: "rtmp://cdn.test/x"), for: provider) == nil)
        #expect(StreamRedirect.target(of: response(302, location: nil), for: provider) == nil)
    }

    @Test func `only movies and episodes over HTTP without headers are resolved`() {
        #expect(StreamRedirect.isEligible(media()))
        #expect(!StreamRedirect.isEligible(media(kind: .live)))
        #expect(!StreamRedirect.isEligible(media(headers: ["Authorization": "Basic x"])))
        #expect(!StreamRedirect.isEligible(media(url: URL(string: "lumestalker://placeholder"))))
        #expect(!StreamRedirect.isEligible(media(url: URL(fileURLWithPath: "/tmp/movie.mkv"))))
    }

    @Test func `an unresolved stream opens on its own URL`() {
        let cache = StreamRedirectCache()
        #expect(cache.target(for: provider) == provider)
    }

    @Test func `an ineligible stream is not resolved`() async {
        let cache = StreamRedirectCache()
        let live = media(kind: .live)
        await cache.prepare(live)
        #expect(cache.target(for: live.url) == live.url)
    }
}

private final nonisolated class HeaderOnlyStreamProtocol: URLProtocol {
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                  "Content-Length": "9000000000", "Content-Type": "application/octet-stream"
              ]) else { return }
        // Without a MIME type Foundation waits for bytes to sniff, before it
        // delivers the response to either AsyncBytes or a response delegate.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Intentionally never deliver or finish the body.
    }

    override func stopLoading() {}
}
