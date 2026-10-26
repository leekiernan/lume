import Foundation
import SwiftData

nonisolated protocol TrackerPagedSummary: Sendable {
    var failed: Bool { get set }
    mutating func add(_ page: Self)
}

/// Scope fences cover one local transaction, not a whole household history.
/// No live model survives the boundary: the next context sees newer local
/// progress, and a profile/account change stops the remaining pages.
nonisolated enum TrackerImportPages {
    struct Scope {
        let container: ModelContainer
        let permit: TrackerImportPermit
        let isCurrent: @Sendable () -> Bool
    }

    @concurrent
    static func apply<Page: Sendable, Summary: TrackerPagedSummary>(
        _ pages: [Page], scope: Scope, initial: Summary,
        operation: @Sendable (Page, ModelContext) -> Summary
    ) async -> Summary {
        var total = initial
        for page in pages {
            let result = scope.permit.withCurrent { () -> Summary? in
                guard !Task.isCancelled, scope.isCurrent() else { return nil }
                let context = ModelContext(scope.container)
                context.autosaveEnabled = false
                let summary = operation(page, context)
                if summary.failed { context.rollback() }
                return summary
            } ?? nil
            guard let result else { total.failed = true; return total }
            total.add(result)
            if result.failed { return total }
            // Never yield with the projection gate or a dirty context held.
            await Task.yield()
        }
        return total
    }

    /// Keep duplicate remote records for a title together. Splitting them
    /// could change the importer's last-record/newest-pause selection rules.
    static func groups<Item, Key: Hashable>(
        _ items: [Item], maximumKeys: Int, key: (Item) -> Key?
    ) -> [[Item]] {
        var order: [Key] = []
        var groups: [Key: [Item]] = [:]
        for item in items {
            guard let id = key(item) else { continue }
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(item)
        }
        let size = max(1, maximumKeys)
        return stride(from: 0, to: order.count, by: size).map { start in
            order[start ..< min(start + size, order.count)].flatMap { groups[$0] ?? [] }
        }
    }
}

nonisolated extension TraktImportSummary {
    mutating func add(_ page: Self) {
        moviesMarked += page.moviesMarked
        episodesMarked += page.episodesMarked
        showsQueued += page.showsQueued
        inProgress += page.inProgress
        failed = failed || page.failed
    }
}
