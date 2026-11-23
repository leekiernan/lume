//
//  OrphanedDeviceStateSweepTests.swift
//  LumeTests
//
//  Settings named after a deleted playlist or profile are removed; a live
//  one's, the default profile's and unrelated keys are kept. Keys are built
//  with each store's own key function, so a renamed family fails here rather
//  than silently escaping the sweep.
//

import Foundation
@testable import Lume
import Testing

struct OrphanedDeviceStateSweepTests {
    private let live = UUID()
    private let gone = UUID()

    private func playlistKeys(_ id: UUID) -> [String] {
        [
            PlaylistSyncCoverage.key(playlistID: id),
            PlaylistSyncCoverage.legacyKey(playlistID: id),
            PlaylistSyncCoverage.deferredKey(playlistID: id),
            SweepSkipDefaults.key(playlistId: id, kind: "movie"),
            XtreamDigestStore.key(playlistId: id, endpoint: .movies),
            M3UDigestStore.key(playlistId: id),
            WebDAVDigestStore.key(playlistId: id),
            "liveVariants.version.\(id.uuidString)"
        ]
    }

    private func profileKeys(_ id: UUID) -> [String] {
        [
            ProfileScopedPreferences.key(HomeLayoutSettings.baseSectionOrderKey(.home), profileID: id),
            ProfileScopedPreferences.key(AppAreaSettings.baseAreaGenerationKey, profileID: id),
            "recommendations.cache.v1.\(id.uuidString)",
            "watchHistory.clears.v1.\(id.uuidString)",
            "player.live.currentChannelId.\(id.uuidString)"
        ]
    }

    @Test func `removes a deleted playlist's and profile's keys only`() {
        let keys = playlistKeys(live) + playlistKeys(gone) + profileKeys(live) + profileKeys(gone)
        let orphans = OrphanedDeviceStateSweep.orphanedKeys(in: keys, playlists: [live], profiles: [live])
        #expect(Set(orphans) == Set(playlistKeys(gone) + profileKeys(gone)))
    }

    @Test func `keeps the default profile's keys even when it isn't listed`() {
        let keys = profileKeys(UserProfile.defaultProfileID)
        #expect(OrphanedDeviceStateSweep.orphanedKeys(in: keys, playlists: [live], profiles: [live]).isEmpty)
    }

    @Test func `judges nothing against an empty roster`() {
        let keys = playlistKeys(gone) + profileKeys(gone)
        let noPlaylists = OrphanedDeviceStateSweep.orphanedKeys(in: keys, playlists: [], profiles: [live])
        #expect(Set(noPlaylists) == Set(profileKeys(gone)))
        let noProfiles = OrphanedDeviceStateSweep.orphanedKeys(in: keys, playlists: [live], profiles: [])
        #expect(Set(noProfiles) == Set(playlistKeys(gone)))
    }

    @Test func `leaves keys outside the families alone`() {
        let keys = [
            "sync.areaRefreshedSoon.\(gone.uuidString)",
            "profile.notAUUID.home.sectionOrder.v1",
            "profile.\(gone.uuidString)x",
            "player.live.currentChannelId",
            "app.appearance"
        ]
        #expect(OrphanedDeviceStateSweep.orphanedKeys(in: keys, playlists: [live], profiles: [live]).isEmpty)
    }

    @Test func `run removes the orphans from the store`() throws {
        try withIsolatedDefaults { defaults in
            for key in playlistKeys(live) + playlistKeys(gone) {
                defaults.set(1, forKey: key)
            }
            let removed = OrphanedDeviceStateSweep.run(playlists: [live], profiles: [live], defaults: defaults)
            #expect(removed == playlistKeys(gone).count)
            for key in playlistKeys(gone) {
                #expect(defaults.object(forKey: key) == nil)
            }
            for key in playlistKeys(live) {
                #expect(defaults.object(forKey: key) != nil)
            }
        }
    }

    @Test func `deleting a profile's scoped settings leaves other profiles' alone`() throws {
        try withIsolatedDefaults { defaults in
            for key in profileKeys(live) + profileKeys(gone) {
                defaults.set("x", forKey: key)
            }
            ProfileScopedPreferences.removeAll(profileID: gone, defaults: defaults)
            let scopedGone = profileKeys(gone).filter { $0.hasPrefix("profile.") }
            for key in scopedGone {
                #expect(defaults.object(forKey: key) == nil)
            }
            for key in profileKeys(live) {
                #expect(defaults.object(forKey: key) != nil)
            }
        }
    }
}
