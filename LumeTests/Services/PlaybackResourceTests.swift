import Foundation
@testable import Lume
import Testing

struct PlaybackResourceTests {
    private let headers = ["X-Plex-Token": "private-source-token"]

    @Test func `relative redirects keep authentication on every source hop`() async throws {
        let log = RequestLog()
        let server = try GuideHTTPServer { request in
            log.append(request)
            if request.contains("/guide.xml") { return .init(status: 302, headers: ["Location": "/canonical"], body: "") }
            return .init(status: 206, body: "x")
        }
        let original = try await server.start()
        defer { server.stop() }
        let result = try await PlaybackResourceResolver.resolve(.init(url: original, headers: headers))
        #expect(result.url.path == "/canonical")
        #expect(result.headers == headers)
        #expect(log.requests.count == 2)
        #expect(log.requests.allSatisfy { $0.contains("private-source-token") && $0.contains("bytes=0-0") })
    }

    @Test func `a foreign port loses headers and is not probed`() async throws {
        let log = RequestLog()
        let destination = try GuideHTTPServer { request in log.append(request); return .init(body: "x") }
        let target = try await destination.start()
        defer { destination.stop() }
        let origin = try GuideHTTPServer { _ in .init(status: 307, headers: ["Location": target.absoluteString], body: "") }
        let original = try await origin.start()
        defer { origin.stop() }
        let result = try await PlaybackResourceResolver.resolve(.init(url: original, headers: headers))
        #expect(result == PlaybackResource(url: target, headers: nil))
        #expect(log.requests.isEmpty)
    }

    @Test(arguments: ["file:///private/secret", "rtmp://media.test/film", "http://user:pass@media.test/film"])
    func `unsafe redirect targets fail closed`(target: String) async throws {
        let server = try GuideHTTPServer { _ in .init(status: 302, headers: ["Location": target], body: "") }
        let original = try await server.start()
        defer { server.stop() }
        await #expect(throws: URLError.self) {
            _ = try await PlaybackResourceResolver.resolve(.init(url: original, headers: headers))
        }
    }

    @Test func `redirect loops have a finite budget`() async throws {
        let server = try GuideHTTPServer { _ in .init(status: 302, headers: ["Location": "/guide.xml"], body: "") }
        let original = try await server.start()
        defer { server.stop() }
        await #expect { _ = try await PlaybackResourceResolver.resolve(.init(url: original, headers: headers)) } throws: { error in
            (error as? URLError)?.code == .httpTooManyRedirects
        }
    }

    @Test func `a slow source falls back to the unresolved handoff at its deadline`() async throws {
        // The server stalls a minute; the deadline must end the wait long
        // before, however busy the machine (a tight bound fails under a full
        // parallel run without telling a regression from load).
        let server = try GuideHTTPServer { _ in .init(body: "late", delay: 60) }
        let original = try await server.start()
        defer { server.stop() }
        let resource = PlaybackResource(url: original, headers: headers)
        let start = ContinuousClock.now
        #expect(try await PlaybackResourceResolver.resolve(resource, timeout: 0.1) == resource)
        #expect(start.duration(to: .now) < .seconds(30))
    }

    @Test func `an unreachable source falls back to the unresolved handoff`() async throws {
        let server = try GuideHTTPServer { _ in .init(body: "x") }
        let original = try await server.start()
        server.stop()
        let resource = PlaybackResource(url: original, headers: headers)
        #expect(try await PlaybackResourceResolver.resolve(resource) == resource)
    }

    @Test func `a cancelled caller is not handed the fallback`() async throws {
        let server = try GuideHTTPServer { _ in .init(body: "late", delay: 5) }
        let original = try await server.start()
        defer { server.stop() }
        let read = Task { try await PlaybackResourceResolver.resolve(.init(url: original, headers: headers)) }
        try await Task.sleep(for: .milliseconds(100))
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
