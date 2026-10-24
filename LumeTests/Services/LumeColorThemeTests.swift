import Foundation
@testable import Lume
import Testing

@MainActor
struct LumeColorThemeTests {
    /// WCAG relative luminance of `0xRRGGBB`.
    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let component = Double(value & 0xFF) / 255
            return component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    private func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let (lighter, darker) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private let night: UInt32 = 0x0A0810
    private let ink: UInt32 = 0x14101F
    private let day: UInt32 = 0xF7F5FA

    @Test(arguments: LumeColorTheme.allCases)
    func `every theme is readable where the pink is`(theme: LumeColorTheme) {
        let (bright, deep, _) = theme.hex
        // The accent as text on the dark ground, and Ink text on an accent fill.
        #expect(contrast(bright, night) >= 4.5)
        #expect(contrast(ink, bright) >= 4.5)
        // Light appearance: the deep accent as text on Day and white, and
        // white text on a deep fill.
        #expect(contrast(deep, day) >= 4.5)
        #expect(contrast(0xFFFFFF, deep) >= 5.5)
    }

    @Test func `pink keeps the heritage values`() {
        let (bright, deep, glow) = LumeColorTheme.pink.hex
        #expect(bright == 0xFF88D7)
        #expect(deep == 0xB8237F)
        #expect(glow == 0x7000B4)
        #expect(LumeColorTheme.defaultValue == .pink)
    }

    @Test func `once Pro is known to be gone the theme goes back to pink`() throws {
        let defaults = try #require(UserDefaults(suiteName: "LumeColorThemeTests-\(UUID().uuidString)"))
        let store = LumeThemeStore(defaults: defaults)
        store.select(.coral)
        // Entitlements not read yet: a subscriber's colour stands.
        store.resetUnlessEntitled(resolved: false, isPremium: false)
        #expect(store.theme == .coral)
        store.resetUnlessEntitled(resolved: true, isPremium: true)
        #expect(store.theme == .coral)
        store.resetUnlessEntitled(resolved: true, isPremium: false)
        #expect(store.theme == .pink)
        #expect(LumeThemeStore(defaults: defaults).theme == .pink)
    }

    @Test func `once Pro is known to be gone the logo goes back to Afterglow`() throws {
        let defaults = try #require(UserDefaults(suiteName: "LumeColorThemeTests-\(UUID().uuidString)"))
        let store = LumeThemeStore(defaults: defaults)
        store.select(LumeLogo.floodlight)
        #expect(LumeThemeStore(defaults: defaults).logo == .floodlight)
        store.resetUnlessEntitled(resolved: true, isPremium: false)
        #expect(store.logo == .afterglow)
    }

    @Test func `each colour and logo has its own icon, Afterglow in pink the primary`() {
        let names = LumeColorTheme.allCases.flatMap { theme in
            LumeLogo.allCases.map { LumeIconChoice(theme: theme, logo: $0).iconName }
        }
        #expect(names.count(where: { $0 == nil }) == 1)
        #expect(LumeIconChoice(theme: .pink, logo: .afterglow).iconName == nil)
        #expect(Set(names.compactMap(\.self)).count == 7)
        #expect(LumeIconChoice(theme: .ice, logo: .floodlight).iconName == "LumeFloodlightIce")
    }

    @Test func `colour themes are on the Pro list`() {
        #expect(PremiumFeature.availableOnThisPlatform.contains(.colorThemes))
    }

    @Test func `the choice persists and an unknown one falls back to pink`() throws {
        let defaults = try #require(UserDefaults(suiteName: "LumeColorThemeTests-\(UUID().uuidString)"))
        let store = LumeThemeStore(defaults: defaults)
        #expect(store.theme == .pink)
        store.select(.ice)
        #expect(LumeThemeStore(defaults: defaults).theme == .ice)
        defaults.set("mauve", forKey: LumeColorTheme.storageKey)
        #expect(LumeThemeStore(defaults: defaults).theme == .pink)
    }
}
