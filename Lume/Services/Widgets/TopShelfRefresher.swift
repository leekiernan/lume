//
//  TopShelfRefresher.swift
//  Lume
//
//  The one way the app asks for a new Top Shelf snapshot. Owned by `LumeApp`
//  and handed to views through the environment, so a view asks with
//  `refresh()` instead of gathering the container and the active profile's
//  child flag itself.
//
//  - Requests coalesce: a burst (a reorder is one per remote press, and
//    adding a row from an area changes two settings) becomes one export.
//  - One export runs at a time; newer requests replace pending work and
//    revoke the active export's publication rights immediately.
//  - The request captures the active profile and its child flag together on
//    the main actor; the export re-checks the profile before building rows.
//  - The roster is watched too: a profile deleted while it holds the Top
//    Shelf — here, or on another device — turns it off.
//
//  tvOS only does any work: no other platform ships an extension that reads
//  the snapshot.
//

import Foundation
import SwiftData
import SwiftUI

@MainActor
final class TopShelfRefresher {
    private let coordinator: TopShelfExportCoordinator

    init(container: ModelContainer, profiles: ProfileManager) {
        coordinator = TopShelfExportCoordinator { canPublish in
            guard profiles.isReady, !profiles.isSwitching else { return }
            let input = TopShelfExportInput(
                request: TopShelfExportRequest(profileID: profiles.activeProfileID, isChildProfile: profiles.activeProfileIsChild),
                followed: TopShelfSettings.followedProfile(),
                playlistID: UserDefaults.standard.string(forKey: PlaylistSelectionStore.key) ?? "",
                rows: WidgetSnapshotExporter.plan(),
                configuration: TopShelfSettings.configuration()
            )
            let check: TopShelfExportCoordinator.PublicationCheck = {
                canPublish() && !profiles.isSwitching
                    && profiles.activeProfileID == input.request.profileID
                    && profiles.activeProfileIsChild == input.request.isChildProfile
                    && input.followed == TopShelfSettings.followedProfile()
                    && input.playlistID == (UserDefaults.standard.string(forKey: PlaylistSelectionStore.key) ?? "")
                    && input.configuration == TopShelfSettings.configuration()
                    && input.rows == WidgetSnapshotExporter.plan()
            }
            await BackgroundActivity.perform("Top Shelf snapshot") {
                let task = Task.detached(priority: .utility) {
                    await WidgetSnapshotExporter.export(container: container, input: input, canPublish: check)
                }
                await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            }
        }
    }

    /// Asks for a new snapshot. `immediately` skips the coalescing delay —
    /// for backgrounding, when the app may be suspended before it ends.
    func refresh(immediately: Bool = false) {
        #if os(tvOS)
            coordinator.refresh(immediately: immediately)
        #endif
    }

    /// Turns the Top Shelf off when the profile it follows is gone. An empty
    /// roster is a store still loading, not every profile deleted.
    func rosterChanged(_ ids: [UUID]) {
        guard let followed = TopShelfSettings.followedProfile(), !ids.isEmpty, !ids.contains(followed) else { return }
        TopShelfSettings.setFollowedProfile(nil)
        refresh()
    }

    func invalidate() {
        #if os(tvOS)
            coordinator.invalidate()
        #endif
    }
}

extension EnvironmentValues {
    /// The app's `TopShelfRefresher`; nil in previews and secondary windows,
    /// where asking for a refresh does nothing.
    @Entry var topShelfRefresher: TopShelfRefresher?
}
