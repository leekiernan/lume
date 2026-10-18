import Foundation
@testable import Lume
import Testing

struct ArtworkRequestTests {
    @Test func `artwork transport has no ambient account state or URL-only cache`() {
        let configuration = ArtworkTransport.configuration()
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCredentialStorage == nil)
    }

    @Test func `public artwork retains the existing disk and memory cache identity`() throws {
        let url = try #require(URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg"))
        #expect(ArtworkRequest(url: url)?.cacheIdentity == url.absoluteString)
    }

    @Test func `tokens travel as headers rather than part of the request URL`() throws {
        let plexURL = try #require(URL(string: "https://server.test/photo?width=300&X-Plex-Token=secret"))
        let plex = try #require(ArtworkRequest(url: plexURL))
        #expect(plex.url.absoluteString == "https://server.test/photo?width=300")
        #expect(plex.request.value(forHTTPHeaderField: "X-Plex-Token") == "secret")
        #expect(!plex.cacheIdentity.contains("secret"))
        let jellyfinURL = try #require(URL(string: "https://server.test/Items/42/Images/Primary?tag=1&api_key=secret"))
        let jellyfin = try #require(ArtworkRequest(url: jellyfinURL))
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

    @Test(arguments: [false, true])
    func `canonical Jellyfin tokens remain in transport but not scoped artwork identity`(includesLegacyAlias: Bool) throws {
        let prefix = "https://server.test/Items/42/Images/Primary?tag=1&ApiKey="
        let oldURL = try #require(URL(string: prefix + "old" + (includesLegacyAlias ? "&api_key=old" : "")))
        let newURL = try #require(URL(string: prefix + "new" + (includesLegacyAlias ? "&api_key=new" : "")))
        let first = try #require(ArtworkRequest(url: oldURL, accountScope: "account-a"))
        let rotated = try #require(ArtworkRequest(url: newURL, accountScope: "account-a"))
        #expect(first.url.query?.contains("ApiKey=old") == true)
        #expect(rotated.url.query?.contains("ApiKey=new") == true)
        #expect(first.cacheIdentity == rotated.cacheIdentity)
        #expect(first.cacheIdentity != ArtworkRequest(url: newURL, accountScope: "account-b")?.cacheIdentity)
        #expect(ArtworkRequest(url: oldURL)?.cacheIdentity != ArtworkRequest(url: newURL)?.cacheIdentity)
        let changedTag = try #require(URL(string: "https://server.test/Items/42/Images/Primary?tag=2&ApiKey=new"))
        #expect(first.cacheIdentity != ArtworkRequest(url: changedTag, accountScope: "account-a")?.cacheIdentity)
    }

    @Test func `unscoped canonical token duplicates all participate in account isolation`() throws {
        let first = try #require(URL(string: "https://server.test/Items/42/Images/Primary?ApiKey=one&ApiKey=two&api_key=legacy"))
        let second = try #require(URL(string: "https://server.test/Items/42/Images/Primary?ApiKey=three&ApiKey=two&api_key=legacy"))
        #expect(ArtworkRequest(url: first)?.cacheIdentity != ArtworkRequest(url: second)?.cacheIdentity)
    }

    @Test func `cross-origin redirects do not forward private headers`() throws {
        let previous = try #require(URL(string: "https://server.test/image"))
        var request = try URLRequest(url: #require(URL(string: "https://cdn.test/image")))
        request.allHTTPHeaderFields = ["X-Plex-Token": "secret", "X-Emby-Token": "secret", "Authorization": "Bearer secret", "Accept": "image/png"]
        let safe = ArtworkRedirectPolicy.redirect(request, from: previous)
        #expect(safe.value(forHTTPHeaderField: "X-Plex-Token") == nil)
        #expect(safe.value(forHTTPHeaderField: "X-Emby-Token") == nil)
        #expect(safe.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(safe.value(forHTTPHeaderField: "Accept") == "image/png")
        request.url = URL(string: "https://server.test:443/another")
        #expect(ArtworkRedirectPolicy.redirect(request, from: previous).value(forHTTPHeaderField: "X-Plex-Token") == "secret")
    }

    @Test func `cross-origin redirects drop credentials echoed into the new address`() throws {
        let previous = try #require(URL(string: "https://server.test/Items/1/Images/Primary?ApiKey=secret"))
        let echoed = try #require(URL(string: "https://sso.test/login?rd=x&ApiKey=secret&api_key=secret&X-Plex-Token=secret&sig=keep"))
        let safe = ArtworkRedirectPolicy.redirect(URLRequest(url: echoed), from: previous)
        #expect(safe.url?.absoluteString == "https://sso.test/login?rd=x&sig=keep")
        // Same origin keeps its own query untouched.
        let local = try #require(URL(string: "https://server.test/Items/1/Images/Primary?ApiKey=secret&tag=b"))
        #expect(ArtworkRedirectPolicy.redirect(URLRequest(url: local), from: previous).url == local)
    }
}
