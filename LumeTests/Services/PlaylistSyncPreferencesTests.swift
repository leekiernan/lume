import Foundation
@testable import Lume
import Testing

@MainActor
struct PlaylistSyncPreferencesTests {
    @Test func `each playlist retains its own cadence`() {
        let first = Playlist(name: "First", serverURL: "", username: "", password: "")
        let second = Playlist(name: "Second", serverURL: "", username: "", password: "")
        first.syncFrequency = .daily
        second.syncFrequency = .weekly
        #expect(first.syncFrequency == .daily)
        #expect(second.syncFrequency == .weekly)
    }

    @Test(.globalState) func `new and unset playlist cadences ignore the old device setting`() {
        let defaults = UserDefaults.standard
        let legacyKey = "lume.syncFrequency"
        let previous = defaults.object(forKey: legacyKey)
        defer {
            if let previous { defaults.set(previous, forKey: legacyKey) } else { defaults.removeObject(forKey: legacyKey) }
        }
        defaults.set("weekly", forKey: legacyKey)
        let playlist = Playlist(name: "Test", serverURL: "", username: "", password: "")
        #expect(playlist.syncFrequency == .everyThreeDays)
        playlist.syncFrequencyRaw = nil
        #expect(playlist.syncFrequency == .everyThreeDays)
    }

    @Test func `playlist cadence is part of the synced configuration's identity`() throws {
        let playlist = Playlist(name: "Test", serverURL: "", username: "", password: "")
        playlist.syncFrequency = .sixHours
        let values = CloudSyncEngine.values(from: playlist)
        #expect(values.syncFrequencyRaw == "sixHours")
        let decoded = try JSONDecoder().decode(PlaylistConfigValues.self, from: JSONEncoder().encode(values))
        #expect(decoded == values)

        playlist.syncFrequency = .weekly
        #expect(decoded != CloudSyncEngine.values(from: playlist))
    }
}
