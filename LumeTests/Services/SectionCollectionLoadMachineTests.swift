import Foundation
@testable import Lume
import Testing

@MainActor
struct SectionCollectionLoadMachineTests {
    private func item(_ id: Int) -> HomeMediaItem {
        .movie(Movie(id: "movie-\(id)", streamId: id, name: "Movie \(id)"))
    }

    private func snapshot(_ id: Int = 1) -> SectionCollectionSnapshot {
        SectionCollectionSnapshot(entries: (1 ... 3).map { HomeListEntry(tmdbId: $0, mediaType: .movie, title: "") },
                                  preview: [item(id)], nextOffset: 1)
    }

    @Test func `cancelled page cannot publish and its unfinished offset can be retried`() async throws {
        let loader = SectionCollectionLoadMachine()
        let gate = CollectionPageGate()
        var offsets: [Int] = []
        let fetch: SectionCollectionLoadMachine.Fetch = { request in
            offsets.append(request.offset)
            _ = await gate.arrive()
            return SectionCollectionPage(items: [item(2)], nextOffset: 2, hasMoreCandidates: false)
        }
        loader.open(key: "list", snapshot: snapshot(), fetch: fetch)
        let old = try #require(loader.requestNextPage(fetch: fetch))
        await gate.waitForCalls(1)
        loader.cancel()
        #expect(!loader.pagination.isLoading)
        #expect(loader.pagination.nextOffset == 1)
        await gate.resume(call: 1)
        await old.value
        #expect(loader.items.map(\.id) == [item(1).id])
        let retry = try #require(loader.requestNextPage(fetch: fetch))
        await gate.waitForCalls(2)
        await gate.resume(call: 2)
        await retry.value
        #expect(offsets == [1, 1])
        #expect(loader.items.map(\.id) == [item(1).id, item(2).id])
        #expect(loader.pagination.nextOffset == 2)
    }

    @Test func `late cancelled page cannot release or replace its newer in flight request`() async throws {
        let loader = SectionCollectionLoadMachine()
        let gate = CollectionPageGate()
        let fetch: SectionCollectionLoadMachine.Fetch = { _ in
            let call = await gate.arrive()
            return SectionCollectionPage(items: [item(call + 1)], nextOffset: 2, hasMoreCandidates: false)
        }
        loader.open(key: "list", snapshot: snapshot(), fetch: fetch)
        let old = try #require(loader.requestNextPage(fetch: fetch))
        await gate.waitForCalls(1)
        loader.cancel()
        let current = try #require(loader.requestNextPage(fetch: fetch))
        await gate.waitForCalls(2)
        await gate.resume(call: 1)
        await old.value
        #expect(loader.pagination.isLoading)
        #expect(loader.requestNextPage(fetch: fetch) == nil)
        #expect(loader.items.map(\.id) == [item(1).id])
        await gate.resume(call: 2)
        await current.value
        #expect(loader.items.map(\.id) == [item(1).id, item(3).id])
    }

    @Test func `changing collections revokes the old page and retains the new preview`() async throws {
        let loader = SectionCollectionLoadMachine()
        let gate = CollectionPageGate()
        let fetch: SectionCollectionLoadMachine.Fetch = { _ in
            _ = await gate.arrive()
            return SectionCollectionPage(items: [item(2)], nextOffset: 2, hasMoreCandidates: false)
        }
        loader.open(key: "old", snapshot: snapshot(), fetch: fetch)
        let old = try #require(loader.requestNextPage(fetch: fetch))
        await gate.waitForCalls(1)
        loader.open(key: "new", snapshot: snapshot(99), fetch: fetch)
        await gate.resume(call: 1)
        await old.value
        #expect(loader.pagination.key == "new")
        #expect(loader.items.map(\.id) == [item(99).id])
        #expect(loader.pagination.nextOffset == 1)
    }

    @Test func `failed page releases ownership without advancing or removing visible titles`() async throws {
        let loader = SectionCollectionLoadMachine()
        let fetch: SectionCollectionLoadMachine.Fetch = { _ in throw URLError(.timedOut) }
        loader.open(key: "list", snapshot: snapshot(), fetch: fetch)
        let task = try #require(loader.requestNextPage(fetch: fetch))
        await task.value
        #expect(!loader.pagination.isLoading)
        #expect(loader.pagination.canLoadMore)
        #expect(loader.pagination.nextOffset == 1)
        #expect(loader.items.map(\.id) == [item(1).id])
    }

    @Test func `empty zero progress page cannot loop indefinitely`() async throws {
        let loader = SectionCollectionLoadMachine()
        var calls = 0
        let fetch: SectionCollectionLoadMachine.Fetch = { request in
            calls += 1
            return SectionCollectionPage(items: [], nextOffset: request.offset, hasMoreCandidates: true)
        }
        loader.open(key: "list", snapshot: snapshot(), fetch: fetch)
        let task = try #require(loader.requestNextPage(fetch: fetch))
        await task.value
        #expect(calls == 1)
        #expect(!loader.pagination.canLoadMore)
        #expect(loader.items.map(\.id) == [item(1).id])
    }
}

/// Only values cross this actor; managed catalogue models stay on MainActor.
private actor CollectionPageGate {
    private var calls = 0
    private var responses: [Int: CheckedContinuation<Void, Never>] = [:]
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []

    func arrive() async -> Int {
        calls += 1
        let call = calls
        for (expected, waiter) in waiting where expected <= calls {
            waiter.resume()
        }
        waiting.removeAll { $0.0 <= calls }
        await withCheckedContinuation { responses[call] = $0 }
        return call
    }

    func waitForCalls(_ expected: Int) async {
        guard calls < expected else { return }
        await withCheckedContinuation { waiting.append((expected, $0)) }
    }

    func resume(call: Int) {
        responses.removeValue(forKey: call)?.resume()
    }
}
