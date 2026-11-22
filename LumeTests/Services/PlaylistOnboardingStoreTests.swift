import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct PlaylistOnboardingStoreTests {
    @Test func `a failed insert rolls back its guide and leaves unrelated view edits untouched`() throws {
        let container = try makeTestContainer()
        let view = container.mainContext
        let unrelated = Movie(id: "unsaved", streamId: 1, name: "Unsaved edit")
        view.insert(unrelated)
        let playlist = Playlist(name: "P", m3uURL: "https://example.invalid/list.m3u", epgURL: "https://example.invalid/guide.xml")
        #expect(throws: CocoaError.self) {
            try PlaylistOnboardingStore.insert(playlist, in: container) { _ in throw CocoaError(.fileWriteOutOfSpace) }
        }
        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<Playlist>()) == 0)
        #expect(try fresh.fetchCount(FetchDescriptor<EPGSource>()) == 0)
        #expect(view.hasChanges)
        #expect(unrelated.name == "Unsaved edit")
    }

    @Test func `a successful insert is visible to the sync context with its guide source`() throws {
        let container = try makeTestContainer()
        let playlist = Playlist(name: "P", m3uURL: "https://example.invalid/list.m3u", epgURL: "https://example.invalid/guide.xml")
        try PlaylistOnboardingStore.insert(playlist, in: container)
        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<Playlist>()).map(\.id) == [playlist.id])
        #expect(try fresh.fetch(FetchDescriptor<EPGSource>()).map(\.playlistID) == [playlist.id])
    }
}
