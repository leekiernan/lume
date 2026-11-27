//
//  LumeApp+LaunchMaintenance.swift
//  Lume
//
//  Launch housekeeping that nothing after it waits for, each piece on its own
//  utility task. Kept out of LumeApp, which composes the scenes.
//

import SwiftUI

extension LumeApp {
    func scheduleLaunchMaintenance() {
        let container = catalogContainer
        // A large upgraded library takes a while to scrub, and downloads and
        // the profile bootstrap don't need it.
        Task(priority: .utility) { await ProviderArtworkMaintenance.run(container: container) }
        LiveChannelVariants.displayIs4K = SportsChannelPreference.Context.current.displayIs4K
        // Channel qualities for playlists that haven't synced since grouping
        // arrived, or since its rules changed.
        Task(priority: .utility) { await LiveChannelVariants.backfill(container: container) }
        // Segment caches a killed process left in `tmp/`, up to 2 GiB each on
        // builds before the budget in `AetherLoadPlan`.
        #if !os(visionOS)
            Task(priority: .utility) { await AetherAbandonedCaches.remove() }
        #endif
    }
}
