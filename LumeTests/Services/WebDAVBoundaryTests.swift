import Foundation
@testable import Lume
import Testing

struct WebDAVBoundaryTests {
    @Test func `a collection slash belongs before its query and fragment`() throws {
        let url = try #require(URL(string: "https://nas.test/Movies%20HD?share=one#folder"))
        let normalized = WebDAVClient.normalizedCollectionURL(url)
        #expect(normalized.absoluteString == "https://nas.test/Movies%20HD/?share=one#folder")
        #expect(WebDAVClient.normalizedCollectionURL(normalized) == normalized)
    }

    @Test(arguments: [
        "https://other.test/Movies/file.mkv", "http://nas.test/Movies/file.mkv",
        "https://nas.test:444/Movies/file.mkv", "https://nas.test/MoviesElsewhere/file.mkv",
        "https://nas.test/Movies/../Private/file.mkv", "https://nas.test/Movies/%2e%2e/Private/file.mkv",
        "file:///Movies/file.mkv"
    ])
    func `listed resources cannot escape the share`(address: String) throws {
        let root = try #require(URL(string: "https://nas.test/Movies/"))
        #expect(try !WebDAVPathIdentity.contains(#require(URL(string: address)), in: root))
    }

    @Test func `origin equality normalizes host case and default ports but not protocols`() throws {
        let root = try #require(URL(string: "https://NAS.test/Movies/"))
        let child = try #require(URL(string: "https://nas.test:443/Movies/Sub/Film.mkv"))
        #expect(WebDAVPathIdentity.contains(child, in: root))
        #expect(SameOriginRedirectPolicy.allows(from: root, to: child))
        #expect(try !SameOriginRedirectPolicy.allows(from: root, to: #require(URL(string: "http://nas.test/Movies/"))))
        #expect(HTTPOrigin(URL(fileURLWithPath: "/Movies")) == nil)
    }

    @Test(arguments: [
        ("http://media.test/api", "https://media.test/api", true),
        ("http://media.test:8096/api", "https://media.test:8920/api", true),
        ("http://media.test/api", "http://media.test:8080/api", false),
        ("https://media.test/api", "http://media.test/api", false),
        ("http://media.test/api", "https://other.test/api", false)
    ])
    func `media servers follow only their own host upgrading to HTTPS`(source: String, destination: String, allowed: Bool) throws {
        let original = try #require(URL(string: source))
        let target = try #require(URL(string: destination))
        #expect(SameOriginRedirectPolicy.allows(from: original, to: target, followsHTTPSUpgrade: true) == allowed)
        // WebDAV listings are checked against the root's origin, so it never upgrades.
        #expect(!SameOriginRedirectPolicy.allows(from: original, to: target))
    }
}
