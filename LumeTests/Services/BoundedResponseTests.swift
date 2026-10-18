//
//  BoundedResponseTests.swift
//  LumeTests
//
//  A body read against its size limit as it arrives: within the limit it is
//  the whole body; past it — declared or not — the read fails rather than
//  collecting it.
//

import Foundation
@testable import Lume
import Testing

struct BoundedResponseTests {
    private func serve(_ response: GuideHTTPServer.Response) async throws -> (GuideHTTPServer, URLRequest) {
        let server = try GuideHTTPServer { _ in response }
        let url = try await server.start()
        return (server, URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    @Test(arguments: [true, false])
    func `a body within the limit arrives whole`(declaresLength: Bool) async throws {
        let body = String(repeating: "a", count: 4096)
        let (server, request) = try await serve(.init(body: body, declaresLength: declaresLength))
        defer { server.stop() }
        let (data, response) = try await BoundedResponse.data(for: request, session: .shared, limit: 4096)
        #expect(data == Data(body.utf8))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test(arguments: [true, false])
    func `a body past the limit fails whether or not it was declared`(declaresLength: Bool) async throws {
        let (server, request) = try await serve(.init(body: String(repeating: "a", count: 256 * 1024), declaresLength: declaresLength))
        defer { server.stop() }
        await #expect(throws: BoundedResponse.TooLarge(limit: 4096)) {
            _ = try await BoundedResponse.data(for: request, session: .shared, limit: 4096)
        }
    }

    @Test func `an error status still returns its body for the caller to judge`() async throws {
        let (server, request) = try await serve(.init(status: 404, body: "missing"))
        defer { server.stop() }
        let (data, response) = try await BoundedResponse.data(for: request, session: .shared, limit: 4096)
        #expect(data == Data("missing".utf8))
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func `cancelling the caller cancels the request`() async throws {
        let (server, request) = try await serve(.init(body: "late", delay: 5))
        defer { server.stop() }
        let read = Task { try await BoundedResponse.data(for: request, session: .shared, limit: 4096) }
        try await Task.sleep(for: .milliseconds(100))
        read.cancel()
        await #expect(throws: URLError.self) { _ = try await read.value }
    }

    @Test func `a caller cancelled before starting always completes`() async throws {
        let (server, request) = try await serve(.init(body: "unused"))
        defer { server.stop() }
        for _ in 0 ..< 100 {
            let read = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await BoundedResponse.data(for: request, session: .shared, limit: 4096)
            }
            await #expect { _ = try await read.value } throws: { error in
                (error as? URLError)?.code == .cancelled
            }
        }
    }

    @Test(arguments: ["HEAD", "GET"])
    func `bodyless responses may advertise a larger representation`(method: String) async throws {
        let (server, original) = try await serve(.init(status: method == "HEAD" ? 200 : 304,
                                                       headers: ["Content-Length": "65536"], declaresLength: false))
        defer { server.stop() }
        var request = original
        request.httpMethod = method
        if method == "GET" { request.setValue("\"cached\"", forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await BoundedResponse.data(for: request, session: .shared, limit: 4096)
        #expect(data.isEmpty)
        #expect((response as? HTTPURLResponse)?.statusCode == (method == "HEAD" ? 200 : 304))
    }

    @Test(arguments: [404, 503], [true, false])
    func `discarding error bodies preserves their HTTP status`(status: Int, declaresLength: Bool) async throws {
        let (server, request) = try await serve(.init(status: status, body: String(repeating: "x", count: 65537), declaresLength: declaresLength))
        defer { server.stop() }
        let (data, response) = try await BoundedResponse.data(for: request, session: .shared, limit: 4096, bodyPolicy: .successful)
        #expect(data.isEmpty)
        #expect((response as? HTTPURLResponse)?.statusCode == status)
    }

    /// The bounded reader supplies the task delegate; the session's redirect
    /// policy must still be consulted. A credentialed request never reaches
    /// the other origin, and a public one is still followed.
    @Test(arguments: [true, false])
    func `the sessions redirect delegate still governs foreign hops`(credentialed: Bool) async throws {
        let log = RequestLog()
        let destination = try GuideHTTPServer { request in
            log.append(request)
            return .init(body: "safe")
        }
        let target = try await destination.start()
        defer { destination.stop() }
        let (origin, original) = try await serve(.init(status: 302, headers: ["Location": target.absoluteString], body: ""))
        defer { origin.stop() }
        var request = original
        if credentialed { request.setValue("private-token", forHTTPHeaderField: "X-Plex-Token") }
        let session = URLSession(configuration: .ephemeral, delegate: ArtworkRedirectPolicy.shared, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await BoundedResponse.data(for: request, session: session, limit: 4096)
        if credentialed {
            #expect((response as? HTTPURLResponse)?.statusCode == 302)
            #expect(log.requests.isEmpty)
        } else {
            #expect(body == Data("safe".utf8))
            #expect(log.requests.count == 1)
        }
    }

    @Test func `the limit applies after HTTP decompression`() async throws {
        let encoded = "H4sIAAAAAAAAA+3BgQAAAACAINb9JRapCgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGr/kSDDAAABAA=="
        let body = try #require(Data(base64Encoded: encoded))
        let (server, request) = try await serve(.init(headers: ["Content-Encoding": "gzip"], bodyBytes: body))
        defer { server.stop() }
        await #expect(throws: BoundedResponse.TooLarge(limit: 4096)) {
            _ = try await BoundedResponse.data(for: request, session: .shared, limit: 4096)
        }
    }
}
