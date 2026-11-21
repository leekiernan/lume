//
//  MainTabView+AutoSync.swift
//  Lume
//
//  When to look for automatic sync work: launch, a playlist added or
//  switched to, a profile or area change, the foreground, and iCloud bringing
//  new connection details. What is due, and running it, is
//  `PlaylistSyncCenter`'s. Kept out of MainTabView, which composes the tabs.
//

import SwiftUI

extension MainTabView {
    /// Re-evaluate auto-sync when the profile or its enabled areas change, even
    /// though neither operation changes the shared playlist rows themselves.
    var autoSyncTrigger: AutoSyncTrigger {
        AutoSyncTrigger(
            playlistCount: playlists.count,
            activeProfileToken: activeProfileToken,
            disabledAreasRaw: disabledAreasRaw
        )
    }

    /// The playlist the content tabs are showing, resolved rather than read raw:
    /// the stored id can name a deleted playlist, in which case the app falls
    /// back to the same playlist every other surface does, and auto-sync has to
    /// follow it there.
    var activePlaylistID: String {
        playlists.activeID(for: selectedPlaylistID)
    }

    /// Queues every due playlist behind the library — the one on screen, plus
    /// any the viewer just added (see `AutoSync.shouldSync`). Covers the
    /// never-synced first launch as well as periodic refreshes and repairs of
    /// areas the active profile enables but whose own refresh is missing.
    func enqueueDueSyncs(_ candidates: [Playlist]) {
        syncCenter?.enqueueDue(candidates, activePlaylistID: activePlaylistID, disabledAreasRaw: disabledAreasRaw)
    }

    /// iCloud brought new connection details for these playlists; any whose
    /// sync failed this session against the old ones is tried again.
    func retryFailedSyncs(_ ids: Set<UUID>) {
        syncCenter?.reconnected(ids, playlists: playlists, activePlaylistID: activePlaylistID, disabledAreasRaw: disabledAreasRaw)
    }
}

struct AutoSyncTrigger: Hashable {
    let playlistCount: Int
    let activeProfileToken: String
    let disabledAreasRaw: String
}
