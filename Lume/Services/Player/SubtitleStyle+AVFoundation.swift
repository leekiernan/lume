import AVFoundation
import CoreMedia

nonisolated extension SubtitleStyle {
    /// The style as one `AVTextStyleRule` for `AVPlayerItem.textStyleRules`,
    /// which AVPlayerLayer applies to the text subtitles it renders (WebVTT,
    /// TTML, tx3g) — not to CEA-608 captions. The system's Subtitles & Captioning
    /// style can still override it. `nil` for the default style, which leaves
    /// AVPlayer drawing subtitles exactly as it always has.
    var avTextStyleRules: [AVTextStyleRule]? {
        guard self != .default else { return nil }
        return AVTextStyleRule(textMarkupAttributes: avTextMarkupAttributes).map { [$0] }
    }

    /// Typed as `[String: Any]` because that's what `AVTextStyleRule` takes.
    var avTextMarkupAttributes: [String: Any] {
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_ForegroundColorARGB as String: textColor.argb(alpha: 1),
            kCMTextMarkupAttribute_RelativeFontSize as String: size.scale * 100,
            kCMTextMarkupAttribute_CharacterEdgeStyle as String: edge.cmEdgeStyle
        ]
        if bold {
            attributes[kCMTextMarkupAttribute_BoldStyle as String] = true
        }
        if let family = font.cmGenericFontFamily {
            attributes[kCMTextMarkupAttribute_GenericFontFamilyName as String] = family
        }
        if background != .none {
            // Both: the character background alone leaves AVPlayerLayer's own
            // dark cue box drawn over it.
            let box = backgroundColor.argb(alpha: background.opacity)
            attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] = box
            attributes[kCMTextMarkupAttribute_BackgroundColorARGB as String] = box
        }
        if position != .bottom {
            // Percent of the picture's height, from the top, where the cue's
            // line sits; AVPlayer places bottom cues at about 90.
            attributes[kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String] =
                (0.9 - position.lift) * 100
        }
        return attributes
    }
}

private nonisolated extension SubtitleColor {
    func argb(alpha: Double) -> [Double] {
        [alpha, rgb.red, rgb.green, rgb.blue]
    }
}

private nonisolated extension SubtitleEdge {
    var cmEdgeStyle: String {
        switch self {
        case .none: kCMTextMarkupCharacterEdgeStyle_None as String
        case .dropShadow: kCMTextMarkupCharacterEdgeStyle_DropShadow as String
        case .outline: kCMTextMarkupCharacterEdgeStyle_Uniform as String
        case .raised: kCMTextMarkupCharacterEdgeStyle_Raised as String
        }
    }
}

private nonisolated extension SubtitleFontDesign {
    /// CoreMedia has no rounded family, so Rounded keeps AVPlayer's default.
    var cmGenericFontFamily: String? {
        switch self {
        case .system, .rounded: nil
        case .serif: kCMTextMarkupGenericFontName_ProportionalSerif as String
        case .monospaced: kCMTextMarkupGenericFontName_MonospaceSansSerif as String
        }
    }
}
