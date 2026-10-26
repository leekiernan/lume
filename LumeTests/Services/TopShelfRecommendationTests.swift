import Foundation
@testable import Lume
import Testing

@MainActor
struct TopShelfRecommendationTests {
    @Test func `unopened recommendation surfaces cannot export another accounts recorded titles`() throws {
        let domain = "TopShelfRecommendationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let profile = UUID()
        let preset = AuthenticatedHomeList.traktRecommendations
        let section = preset.section(title: "Picks", surface: .movies)
        let source = TopShelfSource(surface: .movies, ref: .custom(section.id))
        let favorites = TopShelfSource(surface: .movies, ref: .builtin(.favorites))
        let alice = try #require(preset.accountScope("alice"))
        let bob = try #require(preset.accountScope("bob"))
        TopShelfSettings.setFollowedProfile(profile, defaults: defaults)
        defaults.set(TopShelfSettings.encode([source, favorites]), forKey: TopShelfSettings.sourcesKey)
        defaults.set(CustomHomeSections.encode([section]), forKey: CustomHomeSections.storageKey(.movies))
        TopShelfSettings.record([source: .loaded(["movie-a"]), favorites: .loaded(["movie-favorite"])],
                                profile: profile, accountScopes: [source: alice], defaults: defaults)

        let original = WidgetSnapshotExporter.plan(defaults: defaults, traktAccount: "alice")
        let switched = WidgetSnapshotExporter.plan(defaults: defaults, traktAccount: "bob")
        let disconnected = WidgetSnapshotExporter.plan(defaults: defaults, traktAccount: nil)
        #expect(original.first?.recordedItems == ["movie-a"])
        #expect(switched.first?.recordedItems.isEmpty == true)
        #expect(disconnected.first?.recordedItems.isEmpty == true)
        #expect(switched.last?.recordedItems == ["movie-favorite"])
        // The refresher's publication check rejects an in-flight export even
        // when the source surface never reloaded or changed its row layout.
        #expect(!TopShelfRowPlan.sameLayout(original, switched))
        #expect(!TopShelfRowPlan.sameLayout(original, disconnected))

        TopShelfSettings.record([source: .loaded(["movie-b"])], profile: profile, accountScopes: [source: bob], defaults: defaults)
        #expect(WidgetSnapshotExporter.plan(defaults: defaults, traktAccount: "bob").first?.recordedItems == ["movie-b"])
        #expect(WidgetSnapshotExporter.plan(defaults: defaults, traktAccount: "alice").first?.recordedItems == ["movie-a"])
    }

    @Test func `a different active profile cannot retain a snapshot from a disconnected tracker account`() {
        let followed = UUID(), active = UUID()
        #expect(TopShelfSettings.exportAction(followed: followed, active: active, snapshotProfile: followed,
                                              snapshotAccount: "alice-scope", currentAccount: "alice-scope") == .keep)
        #expect(TopShelfSettings.exportAction(followed: followed, active: active, snapshotProfile: followed,
                                              snapshotAccount: "alice-scope", currentAccount: "bob-scope") == .clear)
        #expect(TopShelfSettings.exportAction(followed: followed, active: active, snapshotProfile: followed,
                                              snapshotAccount: "alice-scope", currentAccount: nil) == .clear)
        #expect(TopShelfSettings.exportAction(followed: followed, active: followed, snapshotProfile: followed,
                                              snapshotAccount: "alice-scope", currentAccount: "bob-scope") == .build)
        #expect(TopShelfSettings.exportAction(followed: followed, active: active, snapshotProfile: followed,
                                              snapshotAccount: nil, currentAccount: "bob-scope") == .keep)
    }

    @Test func `older snapshots decode and new snapshots persist only an opaque account scope`() throws {
        let old = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(#"{"generatedAt":0,"sections":[]}"#.utf8))
        #expect(old.traktAccountScope == nil)
        let scope = try #require(AuthenticatedHomeList.traktRecommendations.accountScope("private-account"))
        let snapshot = WidgetSnapshot(generatedAt: Date(), sections: [], traktAccountScope: scope)
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: data) == snapshot)
        #expect(String(data: data, encoding: .utf8)?.contains("private-account") == false)
    }
}
