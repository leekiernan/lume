//
//  SettingsView+TVRoute.swift
//  Lume
//
//  tvOS Settings' place, read through the router's `TVSettingsRoute` so it
//  survives the Settings tab being rebuilt when an area or Sports switch
//  changes the tab set. Split from SettingsView.swift for its size limit.
//

import SwiftUI

#if os(tvOS)
    extension SettingsView {
        var route: TVSettingsRoute {
            get { router?.settingsRoute ?? fallbackRoute }
            nonmutating set {
                if let router { router.settingsRoute = newValue } else { fallbackRoute = newValue }
            }
        }

        /// The category whose content is shown in the right pane. Follows focus
        /// in the sidebar (Apple TV Settings behaviour) and persists once focus
        /// moves into the detail pane.
        var selectedCategory: SettingsCategory {
            get { route.category }
            nonmutating set { route.category = newValue }
        }

        /// Which area the Library category is configuring. The rows pane is
        /// `TVSectionLayoutDetail`, which owns that surface's stored order,
        /// hidden set and custom rows.
        var layoutArea: AppArea {
            get { route.layoutArea }
            nonmutating set { route.layoutArea = newValue }
        }

        /// Sports is a Library sibling, not an `AppArea`: it has no catalog of
        /// its own and remains unavailable while the parent Live TV area is off.
        var showingSportsSettings: Bool {
            get { route.showingSportsSettings }
            nonmutating set { route.showingSportsSettings = newValue }
        }

        /// A switch just changed the tab set and is taking focus back. The
        /// focus engine can nominate a sidebar item while the screen rebuilds;
        /// that transient focus is not the viewer navigating.
        var isReclaimingFocus: Bool {
            route.reclaim != nil
        }
    }

    extension View {
        /// Hands focus to `target` in the Settings instance on screen, once the
        /// rebuild lands, and stops when it has held for a moment (a bounded
        /// window otherwise). An outgoing instance yields at once. On device the
        /// handoff is one assertion, a second at most while the new instance is
        /// still appearing.
        func reclaimsFocus(
            _ target: TVSettingsRoute.Reclaim,
            in route: Binding<TVSettingsRoute>,
            instance: UUID,
            focused: FocusState<Bool>.Binding
        ) -> some View {
            task(id: route.wrappedValue.reclaim) {
                guard route.wrappedValue.reclaim == target else { return }
                var held = 0
                for _ in 0 ..< 20 {
                    // An outgoing copy hands the reclaim to the one on screen.
                    guard route.wrappedValue.visibleInstance == instance else {
                        return
                    }
                    if focused.wrappedValue { held += 1 } else {
                        held = 0
                        focused.wrappedValue = true
                    }
                    if held >= 3 { break }
                    try? await Task.sleep(for: .milliseconds(75))
                    if Task.isCancelled { return }
                }
                if route.wrappedValue.reclaim == target { route.wrappedValue.reclaim = nil }
            }
        }
    }
#endif
