import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct PlaylistSyncPreferencesTests {
    @Test func `migration adopts legacy cadence without replacing a playlist choice`() throws {
        let container = try ModelContainer(for: Playlist.self, Category.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let suite = "playlist.cadence.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("daily", forKey: SyncFrequency.storageKey)
        let legacy = Playlist(name: "Legacy", serverURL: "", username: "", password: "")
        legacy.syncFrequencyRaw = nil
        let configured = Playlist(name: "Configured", serverURL: "", username: "", password: "")
        configured.syncFrequency = .weekly
        context.insert(legacy)
        context.insert(configured)
        try context.save()
        try PlaylistSyncPreferences.migrate(in: context, defaults: defaults)
        #expect(legacy.syncFrequencyRaw == "daily")
        #expect(configured.syncFrequency == .weekly)
        defaults.set("sixHours", forKey: SyncFrequency.storageKey)
        try PlaylistSyncPreferences.migrate(in: context, defaults: defaults)
        #expect(legacy.syncFrequencyRaw == "daily")
    }

    @Test func `playlist cadence survives a cloud configuration round trip`() throws {
        let playlist = Playlist(name: "Test", serverURL: "", username: "", password: "")
        playlist.syncFrequency = .sixHours
        let values = CloudSyncEngine.values(from: playlist)
        let decoded = try JSONDecoder().decode(PlaylistConfigValues.self, from: JSONEncoder().encode(values))
        #expect(decoded.syncFrequencyRaw == "sixHours")
        let legacyJSON = """
        {"name":"Test","serverURL":"","username":"","password":"","sourceTypeRaw":"xtream","syncEnabled":true}
        """
        let legacy = try JSONDecoder().decode(PlaylistConfigValues.self, from: Data(legacyJSON.utf8))
        #expect(legacy.syncFrequencyRaw == nil)
    }
}
