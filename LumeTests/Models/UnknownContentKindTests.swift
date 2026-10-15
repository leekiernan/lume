import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.globalState)
struct UnknownContentKindTests {
    @Test func `unknown category types never become live TV`() {
        let category = Category(apiId: "1", name: "Future", parentId: 0, typeRaw: "future-category")
        #expect(category.type == nil)
        #expect(category.typeRaw == "future-category")
    }

    @Test func `reconcile and profile export preserve unsupported cloud records`() async throws {
        let activeProfile = ActiveProfileStore.current
        defer { ActiveProfileStore.current = activeProfile }
        let container = try makeProfileTestContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "Test", serverURL: "https://example.test", username: "", password: "")
        let movie = Movie(id: "\(playlist.id.uuidString)-movie-1", streamId: 1, name: "Test")
        movie.isFavorite = true
        context.insert(playlist)
        context.insert(movie)
        let mirror = UserContentState(contentId: movie.id, kind: .movie, profileID: UserProfile.defaultProfileID)
        mirror.kindRaw = "future-content"
        mirror.updatedAt = Date(timeIntervalSince1970: 0)
        context.insert(mirror)
        try context.save()
        let suite = "unknown-kind.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = CloudSyncEngine(container: container, shadow: CloudSyncShadow(defaults: defaults))
        _ = await engine.reconcile()
        #expect(movie.isFavorite)
        try await engine.switchProfile(from: UserProfile.defaultProfileID, to: UUID())
        #expect(mirror.kind == nil)
        #expect(mirror.kindRaw == "future-content")
        #expect(mirror.updatedAt == Date(timeIntervalSince1970: 0))
        #expect(try context.fetch(FetchDescriptor<UserContentState>()).count == 1)
    }
}
