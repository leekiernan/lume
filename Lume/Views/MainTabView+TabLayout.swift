//
//  MainTabView+TabLayout.swift
//  Lume
//
//  Which tabs the bar shows, and the tvOS hold that keeps that layout steady
//  while Settings is selected. Split out of MainTabView for its size limit.
//

import SwiftUI

extension MainTabView {
    func isOn(_ area: AppArea) -> Bool {
        displayedTabSelection.libraryAreas.contains(area)
    }

    /// The tabs the bar shows. On tvOS, switching an area in Settings inserts
    /// or removes a tab, and tvOS answers a changed tab set by rebuilding the
    /// bar and moving focus onto it — out of Settings › Library after every
    /// switch. So while Settings is selected the bar keeps the layout it had:
    /// the switches still apply at once, and the bar catches up on leaving
    /// (or on a deep link or profile change, which select elsewhere).
    var displayedTabSelection: AppTabSelection {
        #if os(tvOS)
            heldTabSelection ?? tabSelection
        #else
            tabSelection
        #endif
    }

    func holdTabLayout(for tab: AppTab) {
        #if os(tvOS)
            if tab != .settings {
                heldTabSelection = nil
            } else if heldTabSelection == nil {
                heldTabSelection = tabSelection
            }
        #endif
    }

    var showsSportsTab: Bool {
        sportsEnabled && SportsSyncService.showsTab && SportsSyncService.isEnabled
    }

    var tabSelection: AppTabSelection {
        #if os(tvOS)
            let showsSettings = true
        #else
            let showsSettings = false
        #endif
        return AppTabSelection(disabledAreasRaw: disabledAreasRaw, showsSports: showsSportsTab, showsSettings: showsSettings)
    }

    #if os(macOS)
        /// AppKit can retain a removed conditional tab's title for the final
        /// role-based Search tab. Include the complete visible layout so its
        /// native tab host is recreated once profile preferences have bound.
        var tabLayoutIdentity: String {
            "\(activeProfileToken)|\(disabledAreasRaw)|\(showsSportsTab)"
        }
    #endif

    /// Keep router state in step with the resolved binding, on launch and when
    /// a profile or layout changes. Never change a valid user-selected tab.
    func repairSelectionIfNeeded() {
        let resolved = displayedTabSelection.resolved(router.selectedTab)
        if router.selectedTab != resolved { router.selectedTab = resolved }
    }
}
