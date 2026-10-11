import Foundation
import SwiftData

extension Playlist {
    var syncFrequency: SyncFrequency {
        get { SyncFrequency.resolve(syncFrequencyRaw ?? "") }
        set { syncFrequencyRaw = newValue.rawValue }
    }
}

enum PlaylistSyncPreferences {
    /// TEMPORARY HOUSEHOLD MIGRATION: remove migrate and its launch call after
    /// the conversion build has uploaded each playlist's explicit cadence.
    /// Adopt the old device-wide choice once per existing playlist, before
    /// reconciliation establishes its new shared configuration baseline.
    static func migrate(in context: ModelContext, defaults: UserDefaults = .standard) throws {
        let playlists = try context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.syncFrequencyRaw == nil }))
        let frequency = SyncFrequency.resolve(defaults.string(forKey: SyncFrequency.storageKey) ?? "")
        for playlist in playlists {
            playlist.syncFrequencyRaw = frequency.rawValue
        }
        if !playlists.isEmpty { try context.save() }
    }
}
