import Foundation
@testable import Lume
import Testing

struct ArtworkRequestTests {
    @Test func `tokens travel as headers rather than part of the request URL`() throws {
        let plex = try #require(ArtworkRequest(url: #require(URL(string: "https://server.test/photo?width=300&X-Plex-Token=secret"))))
        #expect(plex.url.absoluteString == "https://server.test/photo?width=300")
        #expect(plex.request.value(forHTTPHeaderField: "X-Plex-Token") == "secret")
        #expect(!plex.cacheIdentity.contains("secret"))
        let jellyfin = try #require(ArtworkRequest(url: #require(URL(string: "https://server.test/Items/42/Images/Primary?tag=1&api_key=secret"))))
        #expect(jellyfin.headers["X-Emby-Token"] == "secret")
        #expect(jellyfin.url.query == "tag=1")
    }

    @Test func `stable account scope survives token rotation without leaking across accounts`() throws {
        let oldURL = try #require(URL(string: "https://server.test/photo?X-Plex-Token=old"))
        let newURL = try #require(URL(string: "https://server.test/photo?X-Plex-Token=new"))
        let first = try #require(ArtworkRequest(url: oldURL, accountScope: "account-a"))
        let rotated = try #require(ArtworkRequest(url: newURL, accountScope: "account-a"))
        let other = try #require(ArtworkRequest(url: newURL, accountScope: "account-b"))
        #expect(first.cacheIdentity == rotated.cacheIdentity)
        #expect(first.cacheIdentity != other.cacheIdentity)
        #expect(ArtworkRequest(url: oldURL)?.cacheIdentity != ArtworkRequest(url: newURL)?.cacheIdentity)
    }

    @Test func `image transport rejects local files and detects export credentials`() throws {
        #expect(ArtworkRequest(url: URL(fileURLWithPath: "/private/secret")) == nil)
        #expect(try ArtworkRequest.carriesCredentials(#require(URL(string: "https://server.test/image?password=secret"))))
        #expect(try !ArtworkRequest.carriesCredentials(#require(URL(string: "https://server.test/image?tag=42"))))
    }
}
