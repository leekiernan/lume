//
//  TVSettingsRoute.swift
//  Lume
//
//  Where tvOS Settings is, held by `DeepLinkRouter` rather than the view.
//
//  Switching an area (or Sports) adds or removes a tab, and tvOS rebuilds the
//  Settings tab's content whenever the tab set changes. Kept as view state,
//  Settings fell back to Premium with focus in the tab bar after every switch,
//  and turning off several areas meant finding Library again each time. The
//  router sits outside the tab view, so the rebuilt screen finds its place, and
//  the switch that changed the tabs takes focus back. `MainTabView` resets the
//  route on leaving Settings, which still opens fresh.
//

#if os(tvOS)

    struct TVSettingsRoute: Equatable {
        /// A switch that changed the tab set and should hold focus once the
        /// rebuilt screen settles.
        enum Reclaim: Equatable {
            case areaToggle
            case sportsToggle
        }

        var category: SettingsCategory = .premium
        var layoutArea: AppArea = .home
        var showingSportsSettings = false
        /// Set just before the switch is applied, cleared once focus has held
        /// on it. While set, focus brushing the sidebar is not navigation.
        var reclaim: Reclaim?
    }
#endif
