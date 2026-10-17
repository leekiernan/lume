import Foundation
@testable import Lume
import SwiftData
import Synchronization
import Testing

@MainActor
@Suite(.readsGlobalState)
struct WatchProgressFailureTests {
    @Test func `held channel touches survive a failed save and retry together`() async throws {
        let container = try makeTestContainer()
        let first = LiveStream(id: UUID().uuidString, streamId: 1, name: "First")
        let second = LiveStream(id: UUID().uuidString, streamId: 2, name: "Second")
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        try container.mainContext.save()
        let attempts = Mutex(0)
        let writer = WatchProgressWriter(container: container, save: { context in
            if attempts.withLock({ $0 += 1; return $0 }) == 1 { throw CocoaError(.fileWriteNoPermission) }
            try context.save()
        })
        _ = await writer.record(ref: .live(first.id), progress: 1, duration: 0, holdLive: true)
        _ = await writer.record(ref: .live(second.id), progress: 1, duration: 0)
        _ = await writer.record(ref: .live(second.id), progress: 1, duration: 0)
        let stored = try ModelContext(container).fetch(FetchDescriptor<LiveStream>())
        #expect(stored.allSatisfy { $0.lastWatchedDate != nil })
    }

    @Test func `a failed save cannot flush old progress with the next titles write`() async throws {
        let container = try makeTestContainer()
        let first = Movie(id: UUID().uuidString, streamId: 1, name: "First")
        let second = Movie(id: UUID().uuidString, streamId: 2, name: "Second")
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        try container.mainContext.save()
        let attempts = Mutex(0)
        let writer = WatchProgressWriter(container: container, save: { context in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            if attempt == 1 { throw CocoaError(.fileWriteNoPermission) }
            try context.save()
        })
        _ = await writer.record(ref: .movie(first.id), progress: 120, duration: 600)
        _ = await writer.record(ref: .movie(second.id), progress: 180, duration: 600)
        let stored = try ModelContext(container).fetch(FetchDescriptor<Movie>())
        #expect(stored.first { $0.id == first.id }?.watchProgress == 0)
        #expect(stored.first { $0.id == second.id }?.watchProgress == 180)
    }
}
