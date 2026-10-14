//
//  TopShelfRefresher.swift
//  Lume
//
//  The one way the app asks for a new Top Shelf snapshot. Owned by `LumeApp`
//  and handed to views through the environment, so a view asks with
//  `refresh()` instead of gathering the container and the active profile's
//  child flag itself.
//
//  - Requests coalesce: a burst (a reorder is one per remote press, and a
//    long press on a row's ⭐ changes two settings) becomes one export.
//  - Exports run one at a time, in the order they were asked for, so an older
//    one can never finish last and leave a stale Top Shelf.
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
    private let container: ModelContainer
    private let profiles: ProfileManager
    /// A request waiting out the coalescing delay.
    private var pending: Task<Void, Never>?
    /// The last export asked for; the next one waits for it.
    private var tail: Task<Void, Never>?

    private static let coalescing: Duration = .milliseconds(300)

    init(container: ModelContainer, profiles: ProfileManager) {
        self.container = container
        self.profiles = profiles
    }

    /// Asks for a new snapshot. `immediately` skips the coalescing delay —
    /// for backgrounding, when the app may be suspended before it ends.
    func refresh(immediately: Bool = false) {
        #if os(tvOS)
            pending?.cancel()
            guard !immediately else {
                pending = nil
                enqueue()
                return
            }
            pending = Task { [weak self] in
                try? await Task.sleep(for: Self.coalescing)
                guard !Task.isCancelled else { return }
                self?.enqueue()
            }
        #endif
    }

    /// Turns the Top Shelf off when the profile it follows is gone. An empty
    /// roster is a store still loading, not every profile deleted.
    func rosterChanged(_ ids: [UUID]) {
        guard let followed = TopShelfSettings.followedProfile(), !ids.isEmpty, !ids.contains(followed) else { return }
        TopShelfSettings.setFollowedProfile(nil)
        refresh()
    }

    #if os(tvOS)
        private func enqueue() {
            // Mid-switch the catalog and the active profile are changing; the
            // switch's end asks again (see `LumeApp`).
            guard profiles.isReady, !profiles.isSwitching else { return }
            let request = TopShelfExportRequest(
                profileID: profiles.activeProfileID,
                isChildProfile: profiles.activeProfileIsChild
            )
            let rows = WidgetSnapshotExporter.plan()
            let container = container
            let previous = tail
            tail = Task {
                await previous?.value
                await BackgroundActivity.perform("Top Shelf snapshot") {
                    await Task.detached(priority: .userInitiated) {
                        WidgetSnapshotExporter.export(container: container, rows: rows, request: request)
                    }.value
                }
            }
        }
    #endif
}

extension EnvironmentValues {
    /// The app's `TopShelfRefresher`; nil in previews and secondary windows,
    /// where asking for a refresh does nothing.
    @Entry var topShelfRefresher: TopShelfRefresher?
}
