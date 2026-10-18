import Foundation
@testable import Lume
import Testing

@MainActor
struct ProxyErrorResponseTests {
    @Test(arguments: [404, 503])
    func `oversized error pages retain capability status semantics`(status: Int) async throws {
        let host = UUID().uuidString.lowercased() + ".example.com"
        let playlist = Playlist(name: "Test", serverURL: "https://\(host)", username: "u", password: "p")
        let source = try #require(LumeProxySource(playlist: playlist))
        StubURLProtocol.register(host: host, pathSuffix: "/capabilities",
                                 response: .init(status: status, body: String(repeating: "x", count: 65537)))
        let store = LumeProxyCapabilityStore(session: StubURLProtocol.makeSession())
        let result = try await store.negotiation(for: source)
        if status == 404 {
            #expect(result.state == .unsupported)
        } else {
            #expect(result.hostDown)
        }
    }
}
