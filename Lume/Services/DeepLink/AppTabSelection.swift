/// The shared navigation policy for both tab layouts. Native TabView must never
/// receive an absent selection: it may visually fall back without updating the
/// binding, leaving activeOnly/IdleUnmountingTab unable to mount that page.
nonisolated struct AppTabSelection: Equatable {
    let libraryAreas: [AppArea]
    let showsSports: Bool
    let showsSettings: Bool

    init(disabledAreas: DisabledAreas, showsSports: Bool, showsSettings: Bool) {
        libraryAreas = disabledAreas.enabledAreas
        self.showsSports = showsSports && libraryAreas.contains(.liveTV)
        self.showsSettings = showsSettings
    }

    /// Library order, not the platform's tab order (tvOS places Search first).
    /// enabledAreas guarantees a Library area, including its corrupt-data floor.
    var initialTab: AppTab {
        libraryAreas.first?.tab ?? .home
    }

    var availableTabs: [AppTab] {
        libraryAreas.map(\.tab) + (showsSports ? [.sports] : []) + [.search] + (showsSettings ? [.settings] : [])
    }

    /// User-selected Search and Settings remain valid where rendered, but are
    /// never candidates for a launch or unavailable-tab fallback.
    ///
    /// tvOS's sync tab is always valid once selected: it is rendered whenever
    /// it is the selection (`showsSyncTab`), and only while a sync runs, waits
    /// or has failed otherwise. Repairing it to the launch tab moved focus to
    /// Home the moment the viewer reached it, and left its page blank.
    func resolved(_ selection: AppTab) -> AppTab {
        selection == .sync || availableTabs.contains(selection) ? selection : initialTab
    }
}
