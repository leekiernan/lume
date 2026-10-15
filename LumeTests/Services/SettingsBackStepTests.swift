@testable import Lume
import Testing

struct SettingsBackStepTests {
    private func step(
        playlist: Bool = false,
        epg: Bool = false,
        player: PlayerSettingsRoute = .overview,
        areas: Bool = false
    ) -> SettingsBackStep {
        SettingsBackStep.next(
            hasPlaylist: playlist,
            showingEPGSources: epg,
            playerRoute: player,
            showingAreaCategories: areas
        )
    }

    @Test func `a top-level panel goes back to the sidebar`() {
        #expect(step() == .toSidebar)
    }

    @Test func `each drill-in closes before reaching the sidebar`() {
        #expect(step(playlist: true) == .closePlaylist)
        #expect(step(epg: true) == .closeEPGSources)
        #expect(step(player: .engine(.ksPlayer)) == .closeEngineOptions)
        #expect(step(player: .subtitleStyle) == .closeSubtitleStyle)
        #expect(step(areas: true) == .closeAreaCategories)
    }

    @Test func `the language picker steps back to the list, then to the player`() {
        #expect(step(player: .languages(.add)) == .closeLanguagePicker)
        #expect(step(player: .languages(.list)) == .closeLanguageList)
    }

    @Test func `player drill-ins have a single parent route`() {
        var route = PlayerSettingsRoute.languages(.add)
        #expect(route.goBack())
        #expect(route == .languages(.list))
        #expect(route.goBack())
        #expect(route == .overview)
        #expect(!route.goBack())
        route = .engine(.ksPlayer)
        #expect(route.goBack() && route == .overview)
        route = .subtitleStyle
        #expect(route.goBack() && route == .overview)
    }
}
