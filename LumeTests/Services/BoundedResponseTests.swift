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
}
