import Foundation
@testable import Lume
import Testing

struct MediaServerRedirectTests {
    @Test func `plex catalogue redirects cannot disclose the account token`() async throws {
        let log = RequestLog()
        let destination = try GuideHTTPServer { request in
            log.append(request)
            return .init(status: 404, body: "")
        }
        let target = try await destination.start()
        defer { destination.stop() }
        let origin = try GuideHTTPServer { _ in
            .init(status: 302, headers: ["Location": target.absoluteString], body: "")
        }
        let url = try await origin.start()
        defer { origin.stop() }
        _ = try? await PlexClient().sections(server: url.deletingLastPathComponent(), token: "private-plex-token")
        #expect(log.requests.isEmpty)
    }

    @Test(arguments: [false, true])
    func `login redirects never forward a credential bearing POST`(plex: Bool) async throws {
        let log = RequestLog()
        let destination = try GuideHTTPServer { request in
            log.append(request)
            return .init(status: 401, body: "")
        }
        let target = try await destination.start()
        defer { destination.stop() }
        let origin = try GuideHTTPServer { _ in
            .init(status: 307, headers: ["Location": target.absoluteString], body: "")
        }
        let url = try await origin.start()
        defer { origin.stop() }
        if plex {
            _ = try? await PlexClient(accountBaseURL: url).signIn(username: "viewer", password: "private-password")
        } else {
            _ = try? await JellyfinClient().authenticate(server: url, username: "viewer", password: "private-password")
        }
        #expect(log.requests.isEmpty)
    }

    @Test func `same origin API redirects still work`() async throws {
        let log = RequestLog()
        let server = try GuideHTTPServer { request in
            log.append(request)
            if request.contains("GET /library/sections ") {
                return .init(status: 302, headers: ["Location": "/canonical"], body: "")
            }
            return .init(body: #"{"MediaContainer":{"Directory":[]}}"#)
        }
        let url = try await server.start()
        defer { server.stop() }
        let sections = try await PlexClient().sections(server: url.deletingLastPathComponent(), token: "private-plex-token")
        #expect(sections.isEmpty)
        #expect(log.requests.count == 2)
        #expect(log.requests.last?.contains("X-Plex-Token: private-plex-token") == true)
    }
}
