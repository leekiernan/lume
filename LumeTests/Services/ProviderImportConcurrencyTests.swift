import Foundation
@testable import Lume
import Testing

/// Open-ended libraries and the concurrent library walk — see
/// `ProviderTotalTracker` and `walkLibrariesConcurrently`.
@Suite(.readsGlobalState)
struct ProviderImportConcurrencyTests {
    private actor Probe {
        private(set) var inFlight = 0
        private(set) var peak = 0
        private(set) var walked: [Int] = []

        func enter(_ library: Int) {
            inFlight += 1
            peak = max(peak, inFlight)
            walked.append(library)
        }

        func leave() {
            inFlight -= 1
        }
    }

    // MARK: Open-ended libraries

    @Test func `a total that moves in step with the pages marks a library open-ended`() {
        var tracker = ProviderTotalTracker()
        tracker.record(total: 100, itemCount: 50)
        #expect(!tracker.isOpenEnded, "one page can't tell")
        tracker.record(total: 150, itemCount: 50)
        #expect(tracker.isOpenEnded)
        tracker.record(total: 151, itemCount: 50)
        #expect(!tracker.isOpenEnded, "one page out of step is a real library")
    }

    @Test func `a library growing during the scan is not open-ended`() {
        var tracker = ProviderTotalTracker()
        tracker.record(total: 120, itemCount: 50)
        tracker.record(total: 121, itemCount: 50)
        tracker.record(total: 121, itemCount: 21)
        #expect(!tracker.isOpenEnded)
    }

    @Test func `an open-ended library stops at the cap and counts as complete`() async throws {
        let manager = try ContentSyncManager(modelContainer: makeTestContainer())
        var imported = 0
        var shown: [Int] = []
        let count = try await manager.walkProviderPages(openEndedLimit: 120) { offset in
            ProviderImportPage(items: Array(repeating: 0, count: 50), total: offset + 100)
        } consume: { imported += $0.count } report: { _, total in shown.append(total) }
        #expect(count == 150)
        #expect(imported == 150)
        #expect(shown.last == 120, "progress shows the cap, not the receding total")
    }

    @Test func `a page failure inside an open-ended library keeps what was read`() async throws {
        let manager = try ContentSyncManager(modelContainer: makeTestContainer())
        var imported = 0
        await #expect(throws: ProviderImportError.openEndedStopped(fetched: 100)) {
            try await manager.walkProviderPages(openEndedLimit: 500) { offset in
                if offset >= 100 { throw URLError(.timedOut) }
                return ProviderImportPage(items: Array(repeating: 0, count: 50), total: offset + 100)
            } consume: { imported += $0.count } report: { _, _ in }
        }
        #expect(imported == 100)
    }

    @Test func `without a cap an in-step total is still paged strictly`() async throws {
        let manager = try ContentSyncManager(modelContainer: makeTestContainer())
        await #expect(throws: URLError.self) {
            try await manager.walkProviderPages { offset in
                if offset >= 100 { throw URLError(.timedOut) }
                return ProviderImportPage(items: Array(repeating: 0, count: 50), total: offset + 100)
            } consume: { _ in } report: { _, _ in }
        }
    }

    @Test func `an empty page ends an open-ended library`() async throws {
        let manager = try ContentSyncManager(modelContainer: makeTestContainer())
        let count = try await manager.walkProviderPages(openEndedLimit: 500) { offset in
            ProviderImportPage(items: offset < 100 ? Array(repeating: 0, count: 50) : [], total: offset + 100)
        } consume: { _ in } report: { _, _ in }
        #expect(count == 100)
    }

    // MARK: Concurrent libraries

    private func walk(
        _ libraries: [Int],
        isFatal: @escaping @Sendable (Error) -> Bool = { _ in false },
        body: @escaping @Sendable (Int) async throws -> Int
    ) async throws -> ContentSyncManager.LibraryWalk<Int> {
        let manager = try ContentSyncManager(modelContainer: makeTestContainer())
        return try await manager.walkLibrariesConcurrently(libraries, name: { "\($0)" }, isFatal: isFatal, walk: { _, library in
            try await body(library)
        })
    }

    @Test func `libraries are walked at most four at a time and all of them finish`() async throws {
        let probe = Probe()
        let walk = try await walk(Array(1 ... 9)) { library in
            await probe.enter(library)
            try await Task.sleep(for: .milliseconds(20))
            await probe.leave()
            return library
        }
        #expect(walk.incomplete == nil)
        #expect(walk.seen.sorted() == Array(1 ... 9))
        let peak = await probe.peak
        #expect(peak > 1 && peak <= 4)
    }

    @Test func `a failing library is skipped while the others import`() async throws {
        let walk = try await walk([1, 2, 3]) { library in
            if library == 2 { throw URLError(.timedOut) }
            return library
        }
        #expect(walk.seen.sorted() == [1, 3])
        if case .libraryUnavailable = walk.incomplete {} else { Issue.record("expected the skipped library to veto the prune") }
    }

    @Test func `a structural truncation is reported as itself`() async throws {
        let walk = try await walk([1, 2]) { library in
            if library == 1 { throw ProviderImportError.incompletePage(fetched: 1, expected: 2) }
            return library
        }
        #expect(walk.incomplete == .incompletePage(fetched: 1, expected: 2))
        #expect(walk.seen == [2])
    }

    @Test func `a fatal error ends the walk`() async throws {
        await #expect(throws: JellyfinError.self) {
            try await walk([1, 2, 3], isFatal: { $0 is JellyfinError }, body: { library in
                if library == 1 { throw JellyfinError.unauthorized }
                return library
            })
        }
    }

    @Test func `every library failing fails the walk`() async throws {
        await #expect(throws: URLError.self) {
            try await walk([1, 2]) { _ in throw URLError(.timedOut) }
        }
        let empty = try await walk([]) { $0 }
        #expect(empty.seen.isEmpty && empty.incomplete == nil)
    }
}
