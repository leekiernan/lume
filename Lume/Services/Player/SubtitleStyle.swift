import Foundation

/// How subtitles look, chosen in Settings › Player › Subtitle Style and applied by
/// every engine that lets Lume style its subtitles: KSPlayer draws
/// them in SwiftUI (`SubtitleStyleModifier`), AVPlayer through
/// `AVPlayerItem.textStyleRules`, and VLC honours the size only. Device-local, in
/// `UserDefaults` like every other player setting. The default reproduces
/// KSPlayer's look from before the setting existed.
nonisolated struct SubtitleStyle: Equatable {
    var size: SubtitleTextSize = .standard
    var font: SubtitleFontDesign = .system
    var bold = false
    var textColor: SubtitleColor = .white
    var background: SubtitleBackground = .none
    var backgroundColor: SubtitleColor = .black
    var edge: SubtitleEdge = .dropShadow
    var position: SubtitlePosition = .bottom

    static let `default` = SubtitleStyle()

    static let storageKey = "player.subtitleStyle"

    /// The stored style, read off `UserDefaults` directly for the engines that
    /// apply it once per stream rather than observing it.
    static func current(in defaults: UserDefaults = .standard) -> SubtitleStyle {
        defaults.string(forKey: storageKey).flatMap(SubtitleStyle.init(rawValue:)) ?? .default
    }

    /// The colour the outline and raised edges are drawn in: black, unless the
    /// text itself is black, where a black edge would vanish.
    var edgeColor: SubtitleColor {
        textColor == .black ? .white : .black
    }

    // swiftformat:disable redundantEquatable
    /// Spelled out: the standard library's `RawRepresentable` `==` already
    /// satisfies `Equatable`, so none is synthesised, and that one would compare
    /// encoded JSON instead of the fields. SwiftFormat can't see that and would
    /// delete this as redundant.
    static func == (lhs: SubtitleStyle, rhs: SubtitleStyle) -> Bool {
        lhs.size == rhs.size && lhs.font == rhs.font && lhs.bold == rhs.bold
            && lhs.textColor == rhs.textColor && lhs.background == rhs.background
            && lhs.backgroundColor == rhs.backgroundColor && lhs.edge == rhs.edge
            && lhs.position == rhs.position
    }
    // swiftformat:enable redundantEquatable
}

// MARK: - Persistence

/// Stored as one JSON string so `@AppStorage` can bind the whole style. The
/// Codable shape lives on a separate DTO: a type that is both `RawRepresentable`
/// and `Codable` picks up the standard library's raw-value coding, which would
/// recurse back into `rawValue`.
nonisolated extension SubtitleStyle: RawRepresentable {
    init?(rawValue: String) {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: Data(rawValue.utf8)) else {
            return nil
        }
        self = stored.style
    }

    var rawValue: String {
        let encoder = JSONEncoder()
        // Sorted so an unchanged style always encodes to the same string.
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(Stored(self)) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Every field decodes on its own and falls back to its default, so a value
    /// written by a newer build (an option this build doesn't know) keeps the
    /// rest of the style instead of resetting all of it.
    private struct Stored: Codable {
        var size: String?
        var font: String?
        var bold: Bool?
        var textColor: String?
        var background: String?
        var backgroundColor: String?
        var edge: String?
        var position: String?

        init(_ style: SubtitleStyle) {
            size = style.size.rawValue
            font = style.font.rawValue
            bold = style.bold
            textColor = style.textColor.rawValue
            background = style.background.rawValue
            backgroundColor = style.backgroundColor.rawValue
            edge = style.edge.rawValue
            position = style.position.rawValue
        }

        var style: SubtitleStyle {
            let fallback = SubtitleStyle.default
            return SubtitleStyle(
                size: size.flatMap(SubtitleTextSize.init(rawValue:)) ?? fallback.size,
                font: font.flatMap(SubtitleFontDesign.init(rawValue:)) ?? fallback.font,
                bold: bold ?? fallback.bold,
                textColor: textColor.flatMap(SubtitleColor.init(rawValue:)) ?? fallback.textColor,
                background: background.flatMap(SubtitleBackground.init(rawValue:)) ?? fallback.background,
                backgroundColor: backgroundColor.flatMap(SubtitleColor.init(rawValue:)) ?? fallback.backgroundColor,
                edge: edge.flatMap(SubtitleEdge.init(rawValue:)) ?? fallback.edge,
                position: position.flatMap(SubtitlePosition.init(rawValue:)) ?? fallback.position
            )
        }
    }
}

// MARK: - Options

nonisolated enum SubtitleTextSize: String, CaseIterable, Identifiable {
    case smallest
    case small
    case standard
    case large
    case largest

    var id: String {
        rawValue
    }

    /// Multiplier on the platform's standard subtitle point size.
    var scale: Double {
        switch self {
        case .smallest: 0.7
        case .small: 0.85
        case .standard: 1
        case .large: 1.25
        case .largest: 1.5
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .smallest: "Smallest"
        case .small: "Small"
        case .standard: "Standard"
        case .large: "Large"
        case .largest: "Largest"
        }
    }
}

nonisolated enum SubtitleFontDesign: String, CaseIterable, Identifiable {
    case system
    case rounded
    case serif
    case monospaced

    var id: String {
        rawValue
    }

    var title: LocalizedStringResource {
        switch self {
        case .system: "Default"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .monospaced: "Monospaced"
        }
    }
}

nonisolated enum SubtitleColor: String, CaseIterable, Identifiable {
    case white
    case yellow
    case cyan
    case green
    case magenta
    case red
    case blue
    case black

    var id: String {
        rawValue
    }

    /// sRGB components in `0...1`.
    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .white: (1, 1, 1)
        case .yellow: (1, 0.9, 0)
        case .cyan: (0, 0.9, 1)
        case .green: (0.2, 0.9, 0.3)
        case .magenta: (1, 0.25, 0.85)
        case .red: (1, 0.25, 0.2)
        case .blue: (0.25, 0.45, 1)
        case .black: (0, 0, 0)
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .white: "White"
        case .yellow: "Yellow"
        case .cyan: "Cyan"
        case .green: "Green"
        case .magenta: "Magenta"
        case .red: "Red"
        case .blue: "Blue"
        case .black: "Black"
        }
    }
}

nonisolated enum SubtitleBackground: String, CaseIterable, Identifiable {
    case none
    case translucent
    case semiOpaque
    case opaque

    var id: String {
        rawValue
    }

    /// Opacity of the box behind the text; `0` draws no box at all.
    var opacity: Double {
        switch self {
        case .none: 0
        case .translucent: 0.4
        case .semiOpaque: 0.7
        case .opaque: 1
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .none: "None"
        case .translucent: "Translucent"
        case .semiOpaque: "Semi-Opaque"
        case .opaque: "Opaque"
        }
    }
}

nonisolated enum SubtitleEdge: String, CaseIterable, Identifiable {
    case none
    case dropShadow
    case outline
    case raised

    var id: String {
        rawValue
    }

    var title: LocalizedStringResource {
        switch self {
        case .none: "None"
        case .dropShadow: "Drop Shadow"
        case .outline: "Outline"
        case .raised: "Raised"
        }
    }
}

/// How far above the bottom edge the subtitles sit — for burned-in captions or
/// a TV that overscans the bottom of the picture.
nonisolated enum SubtitlePosition: String, CaseIterable, Identifiable {
    case bottom
    case slightlyHigher
    case higher
    case highest

    var id: String {
        rawValue
    }

    /// Lift above the default position, as a fraction of the video's height.
    var lift: Double {
        switch self {
        case .bottom: 0
        case .slightlyHigher: 0.06
        case .higher: 0.12
        case .highest: 0.22
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .bottom: "Bottom"
        case .slightlyHigher: "Slightly Higher"
        case .higher: "Higher"
        case .highest: "Highest"
        }
    }
}
