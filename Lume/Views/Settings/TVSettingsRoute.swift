//
//  TVSettingsRoute.swift
//  Lume
//
//  Where tvOS Settings is, held by `DeepLinkRouter` rather than the view.
//
//  Switching an area (or Sports) adds or removes a tab, and tvOS keeps a
//  separate Settings for each arrangement of tabs: a device trace showed a new
//  instance appear on every switch, the outgoing one lingering ~1 s through the
//  bar's transition, and an earlier instance return with its old state when
//  the tabs went back. Explicit tab identity (one keyed `ForEach`) changed
//  none of that, so the rebuild is the native control's behaviour, and this is
//  built around it rather than against it.
//
//  Kept as view state, Settings fell back to Premium after every switch. The
//  router sits outside the tab view, so each instance finds its place, and the
//  switch that changed the tabs is handed focus once, by the instance now on
//  screen (`visibleInstance`). `MainTabView` resets the route on leaving
//  Settings, which still opens fresh.
//

import Foundation

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
        /// The Settings instance on screen. The outgoing copy lingers through the
        /// bar's transition; only this one may move focus. When both tried, they
        /// traded focus every ~40 ms for a second — the flashing.
        var visibleInstance: UUID?
    }
#endif
