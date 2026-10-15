import Foundation
@testable import Lume
import Testing

struct HomeListCacheTests {
    @Test func `membership survives cache recreation without storing title metadata`() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = HomeListCacheKey(source: "https://themoviedb.org/movie/popular", account: nil)
        let cache = HomeListCache(directory: directory)
        let entries = [HomeListEntry(tmdbId: 1, mediaType: .movie, title: "Do not store me"),
                       HomeListEntry(tmdbId: 1, mediaType: .series, title: "Different namespace")]
        await cache.store(HomeListPage(entries: entries, nextPage: 2), for: key)
        let restored = await HomeListCache(directory: directory).record(for: key)
        #expect(restored?.entries.map(\.tmdbId) == [1, 1])
        #expect(restored?.entries.map(\.mediaType) == [.movie, .series])
        #expect(restored?.entries.map(\.title) == ["", ""])
        #expect(restored?.nextPage == 2)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("membership-v1.json"))
        let json = try #require(String(data: bytes, encoding: .utf8))
        #expect(!json.contains("Do not store me"))
    }

    @Test func `private lists isolate connected and disconnected accounts and languages`() {
        let source = "https://trakt.tv/users/a/lists/private"
        let key = HomeListCacheKey(source: source, account: "a", language: "en-GB")
        #expect(key != HomeListCacheKey(source: source, account: "b", language: "en-GB"))
        #expect(key != HomeListCacheKey(source: source, account: nil, language: "en-GB"))
        #expect(key != HomeListCacheKey(source: source, account: "a", language: "de-DE"))
        #expect(key.digest.count == 64)
        #expect(!key.digest.contains("private"))
    }

    @Test func `empty successful response replaces membership and old records expire`() async {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = HomeListCacheKey(source: "https://mdblist.com/lists/a/b", account: nil)
        let cache = HomeListCache(directory: directory)
        let now = Date()
        await cache.store(HomeListPage(entries: [], nextPage: nil), for: key, now: now)
        #expect(await cache.record(for: key, now: now)?.entries.isEmpty == true)
        #expect(await cache.record(for: key, now: now.addingTimeInterval(31 * 24 * 60 * 60)) == nil)
    }

    @Test func `source count is bounded and newest membership wins`() async {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HomeListCache(directory: directory, maximumSources: 1)
        let old = HomeListCacheKey(source: "https://themoviedb.org/list/1", account: nil)
        let new = HomeListCacheKey(source: "https://themoviedb.org/list/2", account: nil)
        await cache.store(HomeListPage(entries: [], nextPage: nil), for: old, now: .now.addingTimeInterval(-1))
        await cache.store(HomeListPage(entries: [], nextPage: nil), for: new)
        #expect(await cache.record(for: old) == nil)
        #expect(await cache.record(for: new) != nil)
    }
}
