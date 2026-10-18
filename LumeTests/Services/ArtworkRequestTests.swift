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

    // MARK: - Redirects

    private let privateImage = URL(string: "https://server.test/Items/1/Images/Primary?ApiKey=SECRET")!

    private func redirect(to location: String, from previous: URL? = nil, headers: [String: String] = [:]) throws -> URLRequest? {
        var request = try URLRequest(url: #require(URL(string: location)))
        request.allHTTPHeaderFields = headers
        return ArtworkRedirectPolicy.redirect(request, from: previous ?? privateImage)
    }

    /// Every shape a gateway can echo the credential in. Inspecting the new
    /// address caught the first and missed the rest; refusing the hop
    /// covers them all without needing to know.
    @Test(arguments: [
        "https://sso.test/login?rd=https%3A%2F%2Fserver.test%2Fimg%3FApiKey%3DSECRET",
        "https://sso.test/login/https%3A%2F%2Fserver.test%2Fimg%3FApiKey%3DSECRET",
        "https://sso.test/login?rd=https%3A%2F%2Fserver.test%2Fimg%23ApiKey%3DSECRET",
        "https://sso.test/login?rd=https%3A%2F%2Fserver.test%2Fimg%3Ftag%3Da%3BApiKey%3DSECRET",
        "https://sso.test/login?state=ApiKey%3DSECRET",
        "https://sso.test/login?t=SECRET",
        "https://sso.test/login?rd=aHR0cHM6Ly9zZXJ2ZXIudGVzdC9pbWc_QXBpS2V5PVNFQ1JFVA",
        "https://cdn.test/plain.jpg"
    ])
    func `a credentialed request never follows a redirect to another origin`(location: String) throws {
        #expect(try redirect(to: location) == nil)
    }

    @Test(arguments: ["X-Plex-Token", "X-Emby-Token", "Authorization"])
    func `a credential header alone makes the request private`(header: String) throws {
        let previous = try #require(URL(string: "https://server.test/library/metadata/1/thumb/2"))
        #expect(try redirect(to: "https://cdn.test/plain.jpg", from: previous, headers: [header: "SECRET"]) == nil)
        let userinfo = try #require(URL(string: "https://user:pass@server.test/image.jpg"))
        #expect(try redirect(to: "https://cdn.test/plain.jpg", from: userinfo) == nil)
    }

    @Test func `same-origin and same-host HTTPS upgrades keep their credentials`() throws {
        let headers = ["X-Emby-Token": "SECRET"]
        let local = try #require(try redirect(to: "https://server.test:443/Items/1/Images/Primary?ApiKey=SECRET&tag=b", headers: headers))
        #expect(local.url?.query == "ApiKey=SECRET&tag=b" && local.value(forHTTPHeaderField: "X-Emby-Token") == "SECRET")
        let insecure = try #require(URL(string: "http://server.test:8096/Items/1/Images/Primary?ApiKey=SECRET"))
        let upgraded = try #require(try redirect(to: "https://server.test:8920/Items/1/Images/Primary?ApiKey=SECRET", from: insecure, headers: headers))
        #expect(upgraded.value(forHTTPHeaderField: "X-Emby-Token") == "SECRET")
        // Downgrades and port changes over plain HTTP are other origins.
        #expect(try redirect(to: "http://server.test/Items/1/Images/Primary", headers: headers) == nil)
        #expect(try redirect(to: "http://server.test:8080/image", from: insecure) == nil)
    }

    @Test func `public artwork follows redirects byte for byte`() throws {
        let previous = try #require(URL(string: "https://public.test/poster.jpg"))
        let signed = "https://cdn.test/image?sig=a%2Bb%2Fc%3D%25%FF&token=cdn-own&url=https%3A%2F%2Fpublic.test%2Fart%3Ftag%3Da"
        let followed = try #require(try redirect(to: signed, from: previous, headers: ["Accept": "image/png"]))
        #expect(followed.url?.absoluteString == signed)
        #expect(followed.value(forHTTPHeaderField: "Accept") == "image/png")
        // A public URL's own generic `token` is not a media-server credential.
        let tokenised = try #require(URL(string: "https://logos.test/channel.png?token=public-signature"))
        #expect(try redirect(to: "https://cdn.test/channel.png", from: tokenised) != nil)
    }

    @Test func `non-HTTP redirect targets are refused`() throws {
        let previous = try #require(URL(string: "https://public.test/poster.jpg"))
        #expect(try redirect(to: "file:///private/secret", from: previous) == nil)
    }
}
