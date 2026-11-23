//
//  OrphanedDeviceStateSweep.swift
//  Lume
//
//  UserDefaults keys named after a playlist or profile that no longer exists.
//  Deleting either cleans up after itself (`PlaylistDeletion`,
//  `ProfileManager.deleteProfile`), but older versions missed some keys, and a
//  playlist or profile can disappear without passing through those paths. One
//  development Mac had 26,000 of them, left by test runs, which took the app's
//  settings past the 4 MB UserDefaults limit.
//
//  One pass over the key names after launch: a key in a known per-playlist or
//  per-profile family whose id isn't a live playlist or profile is removed.
//

import Foundation
import OSLog
import SwiftData

nonisolated enum OrphanedDeviceStateSweep {
    /// Families of keys that carry a playlist id: `<prefix>.<UUID>`, optionally
    /// followed by `.<more>`.
    static let playlistKeyPrefixes = [
        "sync.areaRefreshed",
        "sync.areaCoverage",
        "sync.areaCoverage.deferred",
        "sync.sweepSkips",
        "sync.xtreamDigest",
        "sync.m3uDigest",
        "sync.webdavDigest",
        "liveVariants.version"
    ]

    /// Families of keys that carry a profile id.
    static let profileKeyPrefixes = [
        "profile",
        "recommendations.cache.v1",
        "watchHistory.clears.v1",
        "player.live.currentChannelId",
        "player.live.previousChannelId",
        "player.live.recentChannelIds"
    ]

    /// The keys to remove. Nothing is judged against an empty set: an empty
    /// catalog or profile list more likely means a store that hasn't loaded
    /// than one that is genuinely empty, and a playlist's or profile's keys
    /// are removed when it is deleted anyway.
    static func orphanedKeys(
        in keys: some Sequence<String>,
        playlists: Set<UUID>,
        profiles: Set<UUID>
    ) -> [String] {
        var profiles = profiles
        if !profiles.isEmpty { profiles.insert(UserProfile.defaultProfileID) }
        return keys.filter { key in
            if !playlists.isEmpty, let id = id(in: key, after: playlistKeyPrefixes) {
                return !playlists.contains(id)
            }
            if !profiles.isEmpty, let id = id(in: key, after: profileKeyPrefixes) {
                return !profiles.contains(id)
            }
            return false
        }
    }

    /// Reads the live playlists and profiles, then sweeps off the main thread.
    /// Called once at launch, after the profile bootstrap.
    @MainActor
    static func schedule(catalog: ModelContainer, profiles: ProfileManager) {
        let playlists = Set(((try? catalog.mainContext.fetch(FetchDescriptor<Playlist>())) ?? []).map(\.id))
        let profiles = Set(profiles.allProfiles().map(\.id))
        Task(priority: .utility) {
            await runAfterLaunch(playlists: playlists, profiles: profiles)
        }
    }

    /// Removes every orphaned key, off the main thread, and logs how many there
    /// were.
    @concurrent
    private static func runAfterLaunch(playlists: Set<UUID>, profiles: Set<UUID>) async {
        let removed = run(playlists: playlists, profiles: profiles)
        if removed > 0 {
            Logger.app.notice("Removed \(removed, privacy: .public) settings for deleted playlists and profiles")
        }
    }

    /// Removes every orphaned key and returns how many there were.
    @discardableResult
    static func run(playlists: Set<UUID>, profiles: Set<UUID>, defaults: UserDefaults = .standard) -> Int {
        let orphans = orphanedKeys(in: defaults.dictionaryRepresentation().keys, playlists: playlists, profiles: profiles)
        for key in orphans {
            defaults.removeObject(forKey: key)
        }
        return orphans.count
    }

    /// The UUID straight after one of `prefixes` and a dot, when the key ends
    /// there or continues with another dot.
    private static func id(in key: String, after prefixes: [String]) -> UUID? {
        for prefix in prefixes where key.hasPrefix(prefix + ".") {
            let start = key.index(key.startIndex, offsetBy: prefix.count + 1)
            guard let end = key.index(start, offsetBy: 36, limitedBy: key.endIndex),
                  end == key.endIndex || key[end] == ".",
                  let id = UUID(uuidString: String(key[start ..< end])) else { continue }
            return id
        }
        return nil
    }
}
