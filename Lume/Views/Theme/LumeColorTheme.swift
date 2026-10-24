//
//  LumeColorTheme.swift
//  Lume
//
//  The brand colour the app is drawn in: heritage pink, or one of the design
//  artefacts' other colourways — ice #62DEFF, live coral #FF6247 and lume
//  green #CCFF4D — named as the design names them; and the logo, Afterglow or
//  Floodlight (`LumeLogo`). A theme is three colours, and every brand role
//  derives from them the way the pink's always have (`LumeTheme.swift` has
//  the roles):
//
//  - bright — the accent on dark and on tvOS, and Ink text on an accent fill;
//  - deep — the accent in light appearance, fills carrying a white glyph,
//    and white text on an accent fill there;
//  - glow — the depth hue in the ambient background (Lume violet for pink).
//
//  The bright shades are the design's; the deep ones are the same hue darkened
//  to the pink deep's contrast with white (5.9:1), and the glows a darker,
//  cooler neighbour, as Lume violet is to pink. Every set clears AA both ways
//  (`LumeColorThemeTests`); coral is the lowest, at 6.3:1 under Ink. The
//  neutrals — Night, Ink, Day and the text greys — stay as they are.
//
//  The choices are per device, like the appearance override. On iPhone, iPad
//  and Apple TV the app icon follows them (`LumeAppIcon`), from alternates
//  made by `Scripts/generate-icon-colourways.py`; the Mac's Dock icon follows
//  while lume runs. The launch screen is plain Ink, as it is drawn before any
//  code runs and could show only one of them.
//

import OSLog
import SwiftUI
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

enum LumeColorTheme: String, CaseIterable, Identifiable {
    case pink, ice, coral, green

    static let storageKey = "app.colorTheme"
    static let defaultValue: LumeColorTheme = .pink

    var id: String {
        rawValue
    }

    var title: LocalizedStringKey {
        switch self {
        case .pink: "Heritage pink"
        case .ice: "Ice"
        case .coral: "Live coral"
        case .green: "lume green"
        }
    }

    /// bright, deep, glow — sRGB, as `0xRRGGBB`.
    var hex: (bright: UInt32, deep: UInt32, glow: UInt32) {
        switch self {
        case .pink: (0xFF88D7, 0xB8237F, 0x7000B4)
        case .ice: (0x62DEFF, 0x006D8A, 0x0B3FA8)
        case .coral: (0xFF6247, 0xC41D00, 0x8A1240)
        case .green: (0xCCFF4D, 0x4E6E00, 0x0A6B4F)
        }
    }

    /// The colour's part of an alternate icon's name.
    var iconSuffix: String {
        switch self {
        case .pink: "Pink"
        case .ice: "Ice"
        case .coral: "Coral"
        case .green: "Green"
        }
    }

    static func resolve(_ raw: String) -> LumeColorTheme {
        LumeColorTheme(rawValue: raw) ?? defaultValue
    }
}

/// The mark the app is drawn with: the Afterglow triangle in its rings, or
/// Floodlight's six lights. Every motion has a form in each (`LumeMark`).
enum LumeLogo: String, CaseIterable, Identifiable {
    case afterglow, floodlight

    static let storageKey = "app.logo"
    static let defaultValue: LumeLogo = .afterglow

    var id: String {
        rawValue
    }

    /// The design's names, which are the marks' names.
    var title: String {
        switch self {
        case .afterglow: "Afterglow"
        case .floodlight: "Floodlight"
        }
    }

    static func resolve(_ raw: String) -> LumeLogo {
        LumeLogo(rawValue: raw) ?? defaultValue
    }
}

/// A colour and a logo: what the app icon shows.
struct LumeIconChoice: Equatable {
    var theme: LumeColorTheme
    var logo: LumeLogo

    /// The alternate app icon for this pair; nil for the primary, Afterglow
    /// in pink. Registered in `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`:
    /// an Icon Composer file on iPhone and iPad, a `…TV` image stack on Apple
    /// TV.
    var iconName: String? {
        let name: String? = switch (logo, theme) {
        case (.afterglow, .pink): nil
        case (.afterglow, _): "Lume" + theme.iconSuffix
        case (.floodlight, _): "LumeFloodlight" + theme.iconSuffix
        }
        #if os(tvOS)
            return name.map { $0 + "TV" }
        #else
            return name
        #endif
    }
}

/// The brand roles for one theme, built once per theme.
struct LumePalette {
    let accent: Color
    let deep: Color
    let onAccent: Color
    let selection: Color
    let glow: Color
    /// The bright shade whatever the appearance: the ambient background's
    /// warm glow, which is the bright colour faintly on Day too.
    let bright: Color

    init(_ theme: LumeColorTheme) {
        let (bright, deep, glow) = theme.hex
        let ink: UInt32 = 0x14101F
        accent = .lumeAdaptive(light: deep, dark: bright)
        self.deep = .lumeRGB(deep)
        onAccent = .lumeAdaptive(light: 0xFFFFFF, dark: ink)
        selection = .lumeAdaptive(light: deep, lightOpacity: 0.10, dark: bright, darkOpacity: 0.18)
        self.glow = .lumeRGB(glow)
        self.bright = .lumeRGB(bright)
    }
}

extension LumePalette {
    /// Each theme's roles, built once: for the theme in use and every swatch.
    static let all: [LumeColorTheme: LumePalette] = Dictionary(
        uniqueKeysWithValues: LumeColorTheme.allCases.map { ($0, LumePalette($0)) }
    )

    static func of(_ theme: LumeColorTheme) -> LumePalette {
        all[theme] ?? LumePalette(theme)
    }
}

/// The theme in use, observed: a view that draws a brand colour reads it
/// through `Color.lumeAccent` and its siblings, so it redraws on a change.
///
/// Colour themes are a lume Pro feature (`PremiumFeature.colorThemes`), and
/// only Pro shows the picker, so a free viewer's theme is simply pink. The app
/// draws what is saved, with no entitlement check in the way: nothing to wait
/// for at launch, so a subscriber's colour never blinks. Pro lapsing resets
/// the saved theme to pink once (`resetUnlessEntitled`).
@Observable
final class LumeThemeStore {
    static let shared = LumeThemeStore()

    private(set) var theme: LumeColorTheme
    private(set) var logo: LumeLogo
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = LumeColorTheme.resolve(defaults.string(forKey: LumeColorTheme.storageKey) ?? "")
        logo = LumeLogo.resolve(defaults.string(forKey: LumeLogo.storageKey) ?? "")
    }

    var iconChoice: LumeIconChoice {
        LumeIconChoice(theme: theme, logo: logo)
    }

    var palette: LumePalette {
        .of(theme)
    }

    func select(_ theme: LumeColorTheme) {
        guard theme != self.theme else { return }
        defaults.set(theme.rawValue, forKey: LumeColorTheme.storageKey)
        self.theme = theme
    }

    func select(_ logo: LumeLogo) {
        guard logo != self.logo else { return }
        defaults.set(logo.rawValue, forKey: LumeLogo.storageKey)
        self.logo = logo
    }

    /// Back to Afterglow in pink once the entitlements are known not to
    /// include Pro. Until they are known, nothing changes.
    func resetUnlessEntitled(resolved: Bool, isPremium: Bool) {
        guard resolved, !isPremium else { return }
        select(LumeColorTheme.pink)
        select(LumeLogo.afterglow)
    }
}

/// The app icon in the theme's colour, kept in step with the theme from the
/// app root (`followsColorTheme()`). On iPhone, iPad and Apple TV the system
/// switches to a bundled alternate and confirms it with an alert of its own,
/// which no app can suppress. The Mac has no alternate icons: its Dock icon is
/// redrawn while lume runs, and Finder keeps the bundle's pink one.
///
/// Out of reach: tvOS's app switcher keeps the primary icon whatever the
/// alternate (checked on device, through a restart), and iOS's confirmation
/// alert previews an icon of its own choosing. Both are the system's.
enum LumeAppIcon {
    static func apply(_ choice: LumeIconChoice) {
        #if os(iOS) || os(tvOS)
            let app = UIApplication.shared
            let name = choice.iconName
            guard app.supportsAlternateIcons, app.alternateIconName != name else { return }
            app.setAlternateIconName(name) { error in
                if let error {
                    Logger.app.error("App icon: couldn't switch to \(name ?? "primary", privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        #elseif os(macOS)
            // nil restores the bundle's own icon.
            NSApplication.shared.applicationIconImage = choice.iconName == nil ? nil : MacDockIcon.image(for: choice)
        #endif
    }
}

extension View {
    /// Keeps the app icon on the theme, and the theme on what the viewer's
    /// plan allows.
    func followsColorTheme() -> some View {
        modifier(ColorThemeFollower())
    }
}

private struct ColorThemeFollower: ViewModifier {
    @State private var store = LumeThemeStore.shared
    @State private var premium = PremiumManager.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: store.iconChoice, initial: true) { _, choice in
                LumeAppIcon.apply(choice)
            }
            .onChange(of: [premium.hasResolvedEntitlements, premium.isPremium], initial: true) { _, state in
                store.resetUnlessEntitled(resolved: state[0], isPremium: state[1])
            }
    }
}

extension Color {
    static func lumeRGB(_ hex: UInt32, opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    /// One colour in light appearance, another in dark. tvOS is always drawn
    /// dark — its screens are, even on a TV set to light — as the asset
    /// catalogue's `tv` entries were.
    static func lumeAdaptive(light: UInt32, lightOpacity: Double = 1, dark: UInt32, darkOpacity: Double = 1) -> Color {
        #if os(tvOS)
            return lumeRGB(dark, opacity: darkOpacity)
        #elseif canImport(UIKit)
            let lightColor = UIColor(lumeRGB(light, opacity: lightOpacity))
            let darkColor = UIColor(lumeRGB(dark, opacity: darkOpacity))
            return Color(UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
        #else
            let lightColor = NSColor(lumeRGB(light, opacity: lightOpacity))
            let darkColor = NSColor(lumeRGB(dark, opacity: darkOpacity))
            return Color(NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
            })
        #endif
    }
}
