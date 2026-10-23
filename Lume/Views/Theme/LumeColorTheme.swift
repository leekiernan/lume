//
//  LumeColorTheme.swift
//  Lume
//
//  The brand colour the app is drawn in: heritage pink, or one of the design
//  artefacts' other colourways — ice #62DEFF, live coral #FF6247 and lume
//  green #CCFF4D — named as the design names them. A theme is three colours, and every brand role derives from
//  them the way the pink's always have (`LumeTheme.swift` has the roles):
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
//  The choice is per device, like the appearance override, and the app icon
//  and launch screen stay pink: neither can change while the app runs.
//

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

    static func resolve(_ raw: String) -> LumeColorTheme {
        LumeColorTheme(rawValue: raw) ?? defaultValue
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

/// The theme in use, observed: a view that draws a brand colour reads it
/// through `Color.lumeAccent` and its siblings, so it redraws on a change.
@Observable
final class LumeThemeStore {
    static let shared = LumeThemeStore()

    private(set) var theme: LumeColorTheme
    private(set) var palette: LumePalette
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let theme = LumeColorTheme.resolve(defaults.string(forKey: LumeColorTheme.storageKey) ?? "")
        self.theme = theme
        palette = LumePalette(theme)
    }

    func select(_ theme: LumeColorTheme) {
        guard theme != self.theme else { return }
        defaults.set(theme.rawValue, forKey: LumeColorTheme.storageKey)
        self.theme = theme
        palette = LumePalette(theme)
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
