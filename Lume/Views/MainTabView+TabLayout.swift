//
//  MainTabView+TabLayout.swift
//  Lume
//
//  Which tabs the bar shows, and keeping the selection on one of them. Split
//  out of MainTabView for its size limit.
//

import SwiftUI

extension MainTabView {
    func isOn(_ area: AppArea) -> Bool {
        tabSelection.libraryAreas.contains(area)
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
        let resolved = tabSelection.resolved(router.selectedTab)
        if router.selectedTab != resolved { router.selectedTab = resolved }
    }
}
