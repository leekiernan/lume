import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SectionFeedCustomLoadingTests {
    private func container(ids: [Int]) throws -> ModelContainer {
        let schema = Schema([Movie.self, Series.self, Episode.self, LiveStream.self, CastMember.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        for id in ids {
            let movie = Movie(id: "mine-\(id)", streamId: id, name: "Local \(id)")
            movie.tmdbId = id
            container.mainContext.insert(movie)
        }
        try container.mainContext.save()
        return container
    }

    private func feed(_ container: ModelContainer, cache: HomeListCache, probe: ListPageProbe) -> SectionFeed {
        let feed = SectionFeed(surface: .movies, listCache: cache, fetchListPage: { _, number in try await probe.page(number) })
        feed.update(context: .init(modelContext: container.mainContext, restriction: ContentRestriction(), playlistPrefix: "mine-"))
        return feed
    }

    private func entries(_ ids: ClosedRange<Int>) -> [HomeListEntry] {
        ids.map { HomeListEntry(tmdbId: $0, mediaType: .movie, title: "Remote \($0)") }
    }

    @Test func `twenty local matches need one remote page and show all continues lazily`() async throws {
        let container = try container(ids: Array(1 ... 40))
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ListPageProbe(pages: [1: HomeListPage(entries: entries(1 ... 20), nextPage: 2),
                                          2: HomeListPage(entries: entries(21 ... 40), nextPage: nil)])
        let feed = feed(container, cache: HomeListCache(directory: directory), probe: probe)
        let section = CustomHomeSection(title: "List", sourceURL: "https://themoviedb.org/list/1")
        await feed.loadCustomSections(cacheKey: UUID().uuidString, sections: [section])
        let snapshot = try #require(feed.collection(for: .custom(section.id)))
        #expect(snapshot.preview.count == 20)
        #expect(snapshot.hasMoreCandidates)
        #expect(await probe.calls == [1])
        let page = try await feed.page(entries: snapshot.entries, continuation: snapshot.continuation, from: snapshot.nextOffset)
        #expect(page.items.map(\.title) == (21 ... 40).map { "Local \($0)" })
        #expect(!page.hasMoreCandidates)
        #expect(page.nextOffset == 40)
        #expect(await probe.calls == [1, 2])
    }

    @Test func `sparse catalogue continues only until twenty eligible matches`() async throws {
        let container = try container(ids: Array(1 ... 5) + Array(21 ... 35))
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ListPageProbe(pages: [1: HomeListPage(entries: entries(1 ... 20), nextPage: 2),
                                          2: HomeListPage(entries: entries(21 ... 40), nextPage: 3)])
        let feed = feed(container, cache: HomeListCache(directory: directory), probe: probe)
        let section = CustomHomeSection(title: "Sparse", sourceURL: "https://themoviedb.org/list/2")
        await feed.loadCustomSections(cacheKey: UUID().uuidString, sections: [section])
        #expect(feed.items(for: .custom(section.id)).count == 20)
        #expect(await probe.calls == [1, 2])
        #expect(feed.collection(for: .custom(section.id))?.continuation?.page == 3)
    }

    @Test func `stale membership renders before background refresh and changed membership replaces it`() async throws {
        let container = try container(ids: Array(1 ... 40))
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HomeListCache(directory: directory)
        let section = CustomHomeSection(title: "Cached", sourceURL: "https://themoviedb.org/list/3")
        let key = HomeListCacheKey(source: section.sourceURL, account: nil)
        await cache.store(HomeListPage(entries: entries(1 ... 20), nextPage: nil), for: key, now: .now.addingTimeInterval(-901))
        let probe = ListPageProbe(pages: [:], blocked: true)
        let feed = feed(container, cache: HomeListCache(directory: directory), probe: probe)
        let task = Task { await feed.loadCustomSections(cacheKey: UUID().uuidString, sections: [section]) }
        await probe.waitForRequest()
        #expect(feed.items(for: .custom(section.id)).map(\.title) == (1 ... 20).map { "Local \($0)" })
        #expect(feed.loads.state(of: .custom(section.id)) == .cached)
        await probe.release(HomeListPage(entries: entries(21 ... 40), nextPage: nil))
        await task.value
        #expect(feed.items(for: .custom(section.id)).map(\.title) == (21 ... 40).map { "Local \($0)" })
        #expect(feed.loads.state(of: .custom(section.id)) == .loaded)
    }

    /// A refreshed page with more to come mustn't shrink the saved rail to its
    /// own few titles: here page 2 then fails, and the 20 saved titles stay.
    @Test func `a partial refresh page does not shrink the saved rail`() async throws {
        let container = try container(ids: Array(1 ... 40))
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HomeListCache(directory: directory)
        let section = CustomHomeSection(title: "Partial", sourceURL: "https://themoviedb.org/list/7")
        await cache.store(HomeListPage(entries: entries(1 ... 20), nextPage: nil),
                          for: HomeListCacheKey(source: section.sourceURL, account: nil), now: .now.addingTimeInterval(-901))
        let probe = ListPageProbe(pages: [1: HomeListPage(entries: entries(21 ... 30), nextPage: 2)])
        let feed = feed(container, cache: HomeListCache(directory: directory), probe: probe)
        await feed.loadCustomSections(cacheKey: UUID().uuidString, sections: [section])
        #expect(await probe.calls == [1, 2])
        #expect(feed.items(for: .custom(section.id)).map(\.title) == (1 ... 20).map { "Local \($0)" })
    }

    @Test func `fresh disk membership needs no remote request after process cache recreation`() async throws {
        let container = try container(ids: Array(1 ... 20))
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let section = CustomHomeSection(title: "Fresh", sourceURL: "https://themoviedb.org/list/4")
        await HomeListCache(directory: directory).store(HomeListPage(entries: entries(1 ... 20), nextPage: nil),
                                                        for: HomeListCacheKey(source: section.sourceURL, account: nil))
        let probe = ListPageProbe(pages: [:])
        let feed = feed(container, cache: HomeListCache(directory: directory), probe: probe)
        await feed.loadCustomSections(cacheKey: UUID().uuidString, sections: [section])
        #expect(feed.items(for: .custom(section.id)).count == 20)
        #expect(await probe.calls.isEmpty)
    }

    @Test func `network failure retains stale membership but successful empty response clears it`() async throws {
        let container = try container(ids: [1])
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HomeListCache(directory: directory)
        let section = CustomHomeSection(title: "Offline", sourceURL: "https://themoviedb.org/list/5")
        await cache.store(HomeListPage(entries: entries(1 ... 1), nextPage: nil),
                          for: HomeListCacheKey(source: section.sourceURL, account: nil), now: .now.addingTimeInterval(-901))
        let offline = feed(container, cache: cache, probe: ListPageProbe(pages: [:]))
        await offline.loadCustomSections(cacheKey: UUID().uuidString, sections: [section])
        #expect(offline.items(for: .custom(section.id)).count == 1)
        let empty = feed(container, cache: cache, probe: ListPageProbe(pages: [1: HomeListPage(entries: [], nextPage: nil)]))
        await empty.loadCustomSections(cacheKey: UUID().uuidString, sections: [section])
        #expect(empty.items(for: .custom(section.id)).isEmpty)
    }

    @Test(arguments: [false, true])
    func `newer complete saved membership replaces an older session rail without fetching`(_ emptied: Bool) async throws {
        let container = try container(ids: Array(1 ... 40))
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HomeListCache(directory: directory)
        let probe = ListPageProbe(pages: [:])
        let feed = feed(container, cache: cache, probe: probe)
        let section = CustomHomeSection(title: "Shared", sourceURL: "https://themoviedb.org/list/8")
        let cacheKey = UUID().uuidString
        let context = try #require(feed.context)
        let previous = await feed.makeCollection(entries: entries(1 ... 20), context: context)
        let updated = emptied ? [] : entries(21 ... 40)
        await cache.store(HomeListPage(entries: updated, nextPage: nil), for: HomeListCacheKey(source: section.sourceURL, account: nil))
        // Seed immediately before loading: another parallel test must not
        // overwrite the single session-cache slot and hide this regression.
        SectionFeedCache.shared.storeCustom(.movies, key: feed.scoped(cacheKey), collections: [section.id: previous])
        await feed.loadCustomSections(cacheKey: cacheKey, sections: [section])
        let expected = emptied ? [] : (21 ... 40).map { "Local \($0)" }
        #expect(feed.items(for: .custom(section.id)).map(\.title) == expected)
        #expect(await probe.calls.isEmpty)
    }

    @Test func `newer partial saved membership continues fetching rather than trusting the old full rail`() async throws {
        let container = try container(ids: Array(1 ... 40))
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HomeListCache(directory: directory)
        let probe = ListPageProbe(pages: [:])
        let feed = feed(container, cache: cache, probe: probe)
        let section = CustomHomeSection(title: "Partial shared", sourceURL: "https://themoviedb.org/list/9")
        let cacheKey = UUID().uuidString
        let context = try #require(feed.context)
        let previous = await feed.makeCollection(entries: entries(1 ... 20), context: context)
        await cache.store(HomeListPage(entries: entries(21 ... 30), nextPage: 2), for: HomeListCacheKey(source: section.sourceURL, account: nil))
        SectionFeedCache.shared.storeCustom(.movies, key: feed.scoped(cacheKey), collections: [section.id: previous])
        await feed.loadCustomSections(cacheKey: cacheKey, sections: [section])
        #expect(await probe.calls == [2])
        // Page 2 failed, so the partial saved page mustn't shrink the rail.
        #expect(feed.items(for: .custom(section.id)).map(\.title) == (1 ... 20).map { "Local \($0)" })
    }

    @Test func `cancelled refresh cannot publish or persist its late response`() async throws {
        let container = try container(ids: [1])
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HomeListCache(directory: directory)
        let probe = ListPageProbe(pages: [:], blocked: true)
        let feed = feed(container, cache: cache, probe: probe)
        let section = CustomHomeSection(title: "Cancelled", sourceURL: "https://themoviedb.org/list/6")
        let task = Task { await feed.loadCustomSections(cacheKey: UUID().uuidString, sections: [section]) }
        await probe.waitForRequest()
        task.cancel()
        await probe.release(HomeListPage(entries: entries(1 ... 1), nextPage: nil))
        await task.value
        #expect(feed.items(for: .custom(section.id)).isEmpty)
        #expect(await cache.record(for: HomeListCacheKey(source: section.sourceURL, account: nil)) == nil)
    }
}

private actor ListPageProbe {
    let pages: [Int: HomeListPage]
    let blocked: Bool
    private(set) var calls: [Int] = []
    private var response: CheckedContinuation<HomeListPage, Error>?
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(pages: [Int: HomeListPage], blocked: Bool = false) {
        self.pages = pages
        self.blocked = blocked
    }

    func page(_ number: Int) async throws -> HomeListPage {
        calls.append(number)
        waiting.forEach { $0.resume() }
        waiting.removeAll()
        if blocked { return try await withCheckedThrowingContinuation { response = $0 } }
        guard let page = pages[number] else { throw URLError(.notConnectedToInternet) }
        return page
    }

    func waitForRequest() async {
        guard calls.isEmpty else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release(_ page: HomeListPage) {
        response?.resume(returning: page)
        response = nil
    }
}
