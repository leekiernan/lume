import Foundation
@testable import Lume
import Testing

struct AppAreaSettingsTests {
    // MARK: - Defaults

    @Test func `everything is on by default`() {
        #expect(DisabledAreas(rawValue: "").enabledAreas == AppArea.allCases)
        #expect(DisabledAreas(rawValue: "").enabledContentAreas == [.movies, .series, .liveTV])
        for area in AppArea.allCases {
            #expect(DisabledAreas(rawValue: "").isEnabled(area))
        }
    }

    // MARK: - encode / decode

    @Test func `encode is stably ordered`() {
        #expect(DisabledAreas([.series, .home]).rawValue == "home,series")
        #expect(DisabledAreas([.home, .series]).rawValue == "home,series")
    }

    @Test func `decode ignores unknown tokens`() {
        #expect(DisabledAreas(rawValue: "movies,bogus,liveTV").elements == [.movies, .liveTV])
    }

    @Test func `decode empty string`() {
        #expect(DisabledAreas(rawValue: "").elements.isEmpty)
    }

    @Test func `encode then decode round trip`() {
        let input: Set<AppArea> = [.movies, .liveTV]
        #expect(DisabledAreas(rawValue: DisabledAreas(input).rawValue).elements == input)
    }

    // MARK: - Toggling

    @Test func `switching an area off removes it from the list`() {
        let raw = AppAreaSettings.settingEnabled(false, for: .liveTV, in: DisabledAreas(rawValue: "")).rawValue
        #expect(!DisabledAreas(rawValue: raw).isEnabled(.liveTV))
        #expect(DisabledAreas(rawValue: raw).enabledAreas == [.home, .movies, .series])
        #expect(DisabledAreas(rawValue: raw).enabledContentAreas == [.movies, .series])
    }

    @Test func `switching an area back on restores its place`() {
        let off = AppAreaSettings.settingEnabled(false, for: .movies, in: DisabledAreas(rawValue: "")).rawValue
        let restored = AppAreaSettings.settingEnabled(true, for: .movies, in: DisabledAreas(rawValue: off)).rawValue
        #expect(restored.isEmpty)
        #expect(DisabledAreas(rawValue: restored).enabledAreas == AppArea.allCases)
    }

    /// The navigation has to keep something in it, so the last area standing
    /// can't be switched off.
    @Test func `the last area cannot be switched off`() {
        var raw = ""
        for area in [AppArea.movies, .series, .liveTV] {
            raw = AppAreaSettings.settingEnabled(false, for: area, in: DisabledAreas(rawValue: raw)).rawValue
        }
        #expect(DisabledAreas(rawValue: raw).enabledAreas == [.home])

        let attempt = AppAreaSettings.settingEnabled(false, for: .home, in: DisabledAreas(rawValue: raw)).rawValue
        #expect(attempt == raw)
        #expect(DisabledAreas(rawValue: raw).isEnabled(.home))
    }

    @Test func `canDisable reports the last area as locked`() {
        var raw = ""
        for area in [AppArea.movies, .series, .liveTV] {
            raw = AppAreaSettings.settingEnabled(false, for: area, in: DisabledAreas(rawValue: raw)).rawValue
        }
        #expect(!DisabledAreas(rawValue: raw).canDisable(.home))
        // An already-off area is always "disableable" — the control is the way
        // back on, so it must never be greyed out.
        #expect(DisabledAreas(rawValue: raw).canDisable(.movies))
    }

    /// A stored value that somehow disables everything (hand-edited defaults, a
    /// future area removed) must still leave the app navigable.
    @Test func `enabledAreas never returns empty`() {
        let all = DisabledAreas(Set(AppArea.allCases)).rawValue
        #expect(DisabledAreas(rawValue: all).enabledAreas == [.home])
    }

    // MARK: - Area mapping

    @Test func `areas map to the right surface and category type`() {
        #expect(AppArea.home.sectionSurface == .home)
        #expect(AppArea.home.categoryType == nil)

        #expect(AppArea.movies.sectionSurface == .movies)
        #expect(AppArea.movies.categoryType == .vod)

        #expect(AppArea.series.sectionSurface == .series)
        #expect(AppArea.series.categoryType == .series)

        // Live TV is browsed by category, so it has no configurable rows.
        #expect(AppArea.liveTV.sectionSurface == nil)
        #expect(AppArea.liveTV.categoryType == .live)
    }

    @Test func `every area maps to a distinct tab`() {
        let tabs = AppArea.allCases.map(\.tab)
        #expect(Set(tabs).count == tabs.count)
        #expect(!tabs.contains(.settings))
        #expect(!tabs.contains(.search))
    }

    @Test func `every area has a label and a symbol`() {
        for area in AppArea.allCases {
            #expect(!area.displayName.isEmpty)
            #expect(!area.systemImage.isEmpty)
        }
    }
}
