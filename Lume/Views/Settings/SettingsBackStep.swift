//
//  SettingsBackStep.swift
//  Lume
//
//  What the Menu button does from inside the tvOS Settings detail pane. It
//  retraces the way in: out of a drilled-in pane one level at a time, then to
//  the category in the sidebar. From the sidebar the button is left to the
//  system, which moves focus to the tab bar.
//
//  Platform-neutral so it is unit-tested on every platform the suite runs on.
//

nonisolated enum SettingsBackStep: Equatable {
    /// Leave a drilled-in playlist for the playlist list.
    case closePlaylist
    /// Leave the TV Guide sources for the playlist list.
    case closeEPGSources
    /// Leave an engine's options for the player settings.
    case closeEngineOptions
    /// Leave the preferred-language add picker for the language list.
    case closeLanguagePicker
    /// Leave the preferred-language list for the player settings.
    case closeLanguageList
    /// Leave Subtitle Style for the player settings.
    case closeSubtitleStyle
    /// Leave a Library area's categories for the area list.
    case closeAreaCategories
    /// Move focus to the current category in the sidebar.
    case toSidebar

    /// Where Menu leads from the detail pane's current state. Only one
    /// drill-in is ever open (each belongs to one category, and returning to
    /// the sidebar clears them all); the order only matters as a tie-break.
    static func next(
        hasPlaylist: Bool,
        showingEPGSources: Bool,
        playerRoute: PlayerSettingsRoute = .overview,
        showingAreaCategories: Bool
    ) -> SettingsBackStep {
        if hasPlaylist { return .closePlaylist }
        if showingEPGSources { return .closeEPGSources }
        switch playerRoute {
        case .engine: return .closeEngineOptions
        case .languages(.add): return .closeLanguagePicker
        case .languages(.list): return .closeLanguageList
        case .subtitleStyle: return .closeSubtitleStyle
        case .overview: break
        }
        if showingAreaCategories { return .closeAreaCategories }
        return .toSidebar
    }
}
