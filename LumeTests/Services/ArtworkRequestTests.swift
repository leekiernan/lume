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
        let safe = try #require(ArtworkRedirectPolicy.redirect(request, from: previous))
        #expect(safe.value(forHTTPHeaderField: "X-Plex-Token") == nil)
        #expect(safe.value(forHTTPHeaderField: "X-Emby-Token") == nil)
        #expect(safe.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(safe.value(forHTTPHeaderField: "Accept") == "image/png")
        request.url = URL(string: "https://server.test:443/another")
        #expect(ArtworkRedirectPolicy.redirect(request, from: previous)?.value(forHTTPHeaderField: "X-Plex-Token") == "secret")
    }

    @Test func `cross-origin redirects drop credentials echoed into the new address`() throws {
        let previous = try #require(URL(string: "https://server.test/Items/1/Images/Primary?ApiKey=secret"))
        let echoed = try #require(URL(string: "https://sso.test/login?rd=x&ApiKey=secret&api_key=secret&X-Plex-Token=secret&sig=keep"))
        let safe = try #require(ArtworkRedirectPolicy.redirect(URLRequest(url: echoed), from: previous))
        #expect(safe.url?.absoluteString == "https://sso.test/login?rd=x&sig=keep")
        // Same origin keeps its own query untouched.
        let local = try #require(URL(string: "https://server.test/Items/1/Images/Primary?ApiKey=secret&tag=b"))
        #expect(ArtworkRedirectPolicy.redirect(URLRequest(url: local), from: previous)?.url == local)
    }

    @Test(arguments: ["ApiKey", "aPi_KeY", "X-Plex-Token"], [0, 1, 2])
    func `cross-origin redirects refuse encoded nested credentials`(key: String, extraEncoding: Int) throws {
        let previous = try #require(URL(string: "https://server.test/image"))
        var nested = "https://server.test/Items/1/Images/Primary?\(key)=secret&tag=a"
        for _ in 0 ..< extraEncoding {
            nested = try #require(nested.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        }
        var destination = try #require(URLComponents(string: "https://sso.test/login"))
        destination.queryItems = [URLQueryItem(name: "return_url", value: nested), URLQueryItem(name: "sig", value: "keep")]
        let request = try URLRequest(url: #require(destination.url))
        #expect(ArtworkRedirectPolicy.redirect(request, from: previous) == nil)
    }

    @Test(arguments: ["https://user:secret@server.test/image", "/image?ApiKey=secret", "//server.test/image?api_key=secret"])
    func `nested userinfo and relative return URLs are refused`(address: String) throws {
        var wrapper = try #require(URLComponents(string: "https://intermediate.test/login"))
        wrapper.queryItems = [URLQueryItem(name: "next", value: address)]
        var destination = try #require(URLComponents(string: "https://sso.test/login"))
        destination.queryItems = try [URLQueryItem(name: "rd", value: #require(wrapper.url).absoluteString)]
        let previous = try #require(URL(string: "https://server.test/image"))
        let request = try URLRequest(url: #require(destination.url))
        #expect(ArtworkRedirectPolicy.redirect(request, from: previous) == nil)
    }

    @Test func `harmless signed CDN redirects and same-origin return URLs stay byte identical`() throws {
        let previous = try #require(URL(string: "https://server.test/image"))
        let cdn = try #require(URL(string: "https://cdn.test/image?sig=a%2Bb%2Fc%3D%25%FF&token=cdn-own&url=https%3A%2F%2Fpublic.test%2Fart%3Ftag%3Da"))
        #expect(ArtworkRedirectPolicy.redirect(URLRequest(url: cdn), from: previous)?.url?.absoluteString == cdn.absoluteString)
        let local = try #require(URL(string: "https://server.test/login?rd=%2Fimage%3FApiKey%3Dsecret"))
        #expect(ArtworkRedirectPolicy.redirect(URLRequest(url: local), from: previous)?.url == local)
    }

    @Test func `non-UTF8 query bytes cannot hide a nested credential`() throws {
        let previous = try #require(URL(string: "https://server.test/image"))
        let destination = try #require(URL(string: "https://sso.test/login?rd=https%3A%2F%2Fserver.test%2Fimage%3FApiKey%3Dsecret%FF"))
        #expect(ArtworkRedirectPolicy.redirect(URLRequest(url: destination), from: previous) == nil)
    }

    @Test(arguments: [false, true])
    func `embedded URL inspection fails closed at its bounds`(exceedsSize: Bool) throws {
        var value = "https://public.test/image"
        if exceedsSize {
            value += String(repeating: "a", count: 65537)
        } else {
            for _ in 0 ..< 10 {
                var wrapper = try #require(URLComponents(string: "https://public.test/login"))
                wrapper.queryItems = [URLQueryItem(name: "rd", value: value)]
                value = try #require(wrapper.url).absoluteString
            }
        }
        var destination = try #require(URLComponents(string: "https://sso.test/login"))
        destination.queryItems = [URLQueryItem(name: "rd", value: value)]
        let previous = try #require(URL(string: "https://server.test/image"))
        #expect(try ArtworkRedirectPolicy.redirect(URLRequest(url: #require(destination.url)), from: previous) == nil)
    }

    @Test func `too many query flags also exhaust the inspection budget`() throws {
        let previous = try #require(URL(string: "https://server.test/image"))
        let destination = try #require(URL(string: "https://cdn.test/image?" + String(repeating: "flag&", count: 14000)))
        #expect(ArtworkRedirectPolicy.redirect(URLRequest(url: destination), from: previous) == nil)
    }
}
