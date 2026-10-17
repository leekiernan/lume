import Foundation
@testable import Lume
import SwiftData
import Synchronization
import Testing

private nonisolated struct ImportPageCount: TrackerPagedSummary {
    var count = 0
    var failed = false
    mutating func add(_ page: Self) {
        count += page.count
        failed = failed || page.failed
    }
}

@MainActor
@Suite(.serialized, .globalState)
struct TrackerImportPagesTests {
    @Test func `duplicate remote titles remain together at page boundaries`() {
        let batches = TrackerImportPages.groups([1, 2, 3, 1, 2, 4], maximumKeys: 2, key: { $0 })
        #expect(batches == [[1, 1, 2, 2], [3, 4]])
    }

    @Test func `an account replacement between pages stops the remaining writes`() async throws {
        let container = try makeTestContainer()
        let account = TrackerAccountLifetime()
        let permit = TrackerImportPermit(account: account)
        let scope = TrackerImportPages.Scope(container: container, permit: permit, isCurrent: { true })
        let result = await TrackerImportPages.apply([1, 2, 3], scope: scope, initial: ImportPageCount()) { page, context in
            context.insert(Movie(id: "movie-\(page)", streamId: page, name: "Movie"))
            do { try context.save() } catch { return ImportPageCount(failed: true) }
            account.invalidate()
            return ImportPageCount(count: 1)
        }
        #expect(result.count == 1 && result.failed)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Movie>()) == 1)
    }

    @Test func `each page refetches local state and an empty response still checks ownership`() async throws {
        let container = try makeTestContainer()
        let calls = Mutex(0)
        let scope = TrackerImportPages.Scope(container: container, permit: TrackerImportPermit(account: TrackerAccountLifetime()), isCurrent: { true })
        let result = await TrackerImportPages.apply([1, 2], scope: scope, initial: ImportPageCount()) { page, context in
            let previous = (try? context.fetch(FetchDescriptor<Movie>())) ?? []
            guard previous.count == page - 1 else { return ImportPageCount(failed: true) }
            calls.withLock { $0 += 1 }
            context.insert(Movie(id: "movie-\(page)", streamId: page, name: "Movie"))
            do { try context.save() } catch { return ImportPageCount(failed: true) }
            return ImportPageCount(count: 1)
        }
        #expect(result.count == 2 && !result.failed && calls.withLock { $0 } == 2)
        let refusedScope = TrackerImportPages.Scope(container: container, permit: TrackerImportPermit(account: TrackerAccountLifetime()), isCurrent: { false })
        let refused = await TrackerImportPages.apply([0], scope: refusedScope, initial: ImportPageCount()) { _, _ in
            Issue.record("an unauthorized page ran")
            return ImportPageCount()
        }
        #expect(refused.failed)
    }
}
