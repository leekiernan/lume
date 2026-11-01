import Foundation
@testable import Lume
import Testing

@Suite(.timeLimit(.minutes(5)))
struct PlaybackResourceTests {
    private let headers = ["X-Plex-Token": "private-source-token"]

    private func source() -> URL {
        URL(string: "https://\(UUID().uuidString.lowercased()).test/guide.xml")!
    }

    private func resolve(_ resource: PlaybackResource, session: URLSession) async throws -> PlaybackResource {
        // These tests exercise redirect policy, not elapsed time. The deadline
        // stays pending until the resolver cancels it after its response.
        let deadline = TestSleeper()
        return try await PlaybackResourceResolver.resolve(resource, session: session, sleep: deadline.sleep)
    }

    @Test func `relative redirects keep authentication on every source hop`() async throws {
        let original = source()
        let host = try #require(original.host)
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        StubURLProtocol.register(host: host, path: "/guide.xml", response: .init(status: 302, headers: ["Location": "/canonical"]))
        StubURLProtocol.register(host: host, path: "/canonical", response: .init(status: 206, body: "x"))
        let result = try await resolve(.init(url: original, headers: headers), session: session)
        #expect(result.url.path == "/canonical")
        #expect(result.headers == headers)
        let requests = StubURLProtocol.requests(forHost: host)
        #expect(requests.map { $0.url?.path } == ["/guide.xml", "/canonical"])
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Plex-Token") == headers["X-Plex-Token"]
                && $0.value(forHTTPHeaderField: "Range") == "bytes=0-0"
        })
    }

    @Test func `a foreign port loses headers and is not probed`() async throws {
        let original = source()
        let host = try #require(original.host)
        var components = try #require(URLComponents(url: original, resolvingAgainstBaseURL: false))
        components.port = 8443
        let target = try #require(components.url)
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        StubURLProtocol.register(host: host, path: "/guide.xml", response: .init(status: 307, headers: ["Location": target.absoluteString]))
        let result = try await resolve(.init(url: original, headers: headers), session: session)
        #expect(result == PlaybackResource(url: target, headers: nil))
        #expect(StubURLProtocol.requests(forHost: host).map(\.url) == [original])
    }

    @Test(arguments: ["file:///private/secret", "rtmp://media.test/film", "http://user:pass@media.test/film"])
    func `unsafe redirect targets fail closed`(target: String) async throws {
        let original = source()
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        try StubURLProtocol.register(host: #require(original.host), path: original.path, response: .init(status: 302, headers: ["Location": target]))
        await #expect(throws: URLError.self) {
            _ = try await resolve(.init(url: original, headers: headers), session: session)
        }
    }

    @Test func `redirect loops have a finite budget`() async throws {
        let original = source()
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        try StubURLProtocol.register(host: #require(original.host), path: original.path, response: .init(status: 302, headers: ["Location": original.path]))
        await #expect { _ = try await resolve(.init(url: original, headers: headers), session: session) } throws: { error in
            (error as? URLError)?.code == .httpTooManyRedirects
        }
    }

    @Test func `a slow source falls back to the unresolved handoff at its deadline`() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SilentStreamProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let resource = PlaybackResource(url: source(), headers: headers)
        let deadline = TestSleeper()
        let read = Task { try await PlaybackResourceResolver.resolve(resource, session: session, sleep: deadline.sleep) }
        defer { read.cancel() }
        var iterator = deadline.requests.makeAsyncIterator()
        let duration = try #require(await iterator.next())
        #expect(duration == .seconds(PlaybackResourceResolver.timeout))
        await deadline.advance()
        #expect(try await read.value == resource)
    }

    @Test func `an unreachable source falls back to the unresolved handoff`() async throws {
        let original = source()
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        try StubURLProtocol.register(host: #require(original.host), path: original.path, response: .init(error: URLError(.cannotConnectToHost)))
        let resource = PlaybackResource(url: original, headers: headers)
        #expect(try await resolve(resource, session: session) == resource)
    }

    @Test func `a cancelled caller is not handed the fallback`() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SilentStreamProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let original = source()
        let deadline = TestSleeper()
        let read = Task { try await PlaybackResourceResolver.resolve(.init(url: original, headers: headers), session: session, sleep: deadline.sleep) }
        defer { read.cancel() }
        var iterator = deadline.requests.makeAsyncIterator()
        _ = try #require(await iterator.next())
        read.cancel()
        await #expect(throws: (any Error).self) { _ = try await read.value }
    }

    @Test func `unprotected streams bypass the network`() async throws {
        let resource = try PlaybackResource(url: #require(URL(string: "https://unreachable.invalid/film")), headers: nil)
        #expect(try await PlaybackResourceResolver.resolve(resource) == resource)
    }

    @Test @MainActor func `replacement retires the previous preparations callbacks`() async throws {
        let (arrivals, arrived) = AsyncStream<CheckedContinuation<PlaybackResource, Error>>.makeStream()
        let preparation = PlaybackResourcePreparation(resolve: { _ in
            try await withCheckedThrowingContinuation { arrived.yield($0) }
        })
        let resource = try PlaybackResource(url: #require(URL(string: "https://media.test/film")), headers: headers)
        var retiredCallbacks = 0
        preparation.prepare(resource, onReady: { _ in retiredCallbacks += 1 }, onFailure: { retiredCallbacks += 1 })
        var iterator = arrivals.makeAsyncIterator()
        let first = try #require(await iterator.next())
        let (completions, completed) = AsyncStream<Void>.makeStream()
        preparation.prepare(resource, onReady: { _ in completed.yield(()) }, onFailure: { completed.finish() })
        let second = try #require(await iterator.next())
        first.resume(returning: resource)
        second.resume(returning: resource)
        for await _ in completions {
            break
        }
        #expect(retiredCallbacks == 0)
        preparation.cancel()
    }

    @Test @MainActor func `a cancelled caller cannot begin a preparation`() async throws {
        let preparation = PlaybackResourcePreparation(resolve: { _ in
            Issue.record("cancelled preparation must not perform network work")
            throw URLError(.cancelled)
        })
        let resource = try PlaybackResource(url: #require(URL(string: "https://media.test/film")), headers: headers)
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            preparation.prepare(resource, onReady: { _ in Issue.record("cancelled callback") }, onFailure: { Issue.record("cancelled failure") })
        }.value
        #expect(!preparation.isPreparing)
    }
}
