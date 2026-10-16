import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CatalogMaintenanceTests {
    @Test func `keyset maintenance crosses pages as matching rows disappear`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        for id in ["1", "2", "10", "A", "a", "z"] {
            let movie = Movie(id: id, streamId: 1, name: id)
            movie.tmdbEnrichedAt = .now
            context.insert(movie)
        }
        try context.save()
        var visited: [String] = []
        try CatalogMaintenance.mutate(container: container, pageSize: 2, page: { cursor in
            FetchDescriptor<Movie>(
                predicate: #Predicate { $0.id > cursor && $0.tmdbEnrichedAt != nil },
                sortBy: [SortDescriptor(\.id, comparator: .lexical)]
            )
        }, mutate: { rows, _ in
            #expect(rows.count <= 2)
            visited += rows.map(\.id)
            for row in rows {
                row.tmdbEnrichedAt = nil
            }
        })
        #expect(visited == ["1", "10", "2", "A", "a", "z"])
        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<Movie>()).allSatisfy { $0.tmdbEnrichedAt == nil })
    }

    @Test func `retired maintenance scope does not mutate another page`() throws {
        let container = try makeTestContainer()
        var visits = 0
        #expect(throws: CancellationError.self) {
            try CatalogMaintenance.mutate(container: container, isCurrent: { false }, page: { cursor in
                FetchDescriptor<Movie>(predicate: #Predicate { $0.id > cursor })
            }, mutate: { _, _ in visits += 1 })
        }
        #expect(visits == 0)
    }
}
