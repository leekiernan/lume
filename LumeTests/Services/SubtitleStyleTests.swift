import CoreMedia
import Foundation
@testable import Lume
import Testing

struct SubtitleStyleTests {
    private let custom = SubtitleStyle(
        size: .largest,
        font: .serif,
        bold: true,
        textColor: .yellow,
        background: .semiOpaque,
        backgroundColor: .blue,
        edge: .outline,
        position: .highest
    )

    // MARK: - Persistence

    @Test func `a custom style survives the raw-value round trip`() throws {
        let decoded = try #require(SubtitleStyle(rawValue: custom.rawValue))
        #expect(decoded == custom)
    }

    @Test func `garbage decodes to nil so AppStorage keeps the default`() {
        #expect(SubtitleStyle(rawValue: "not json") == nil)
    }

    @Test func `an unknown option keeps the rest of the stored style`() throws {
        let raw = #"{"size":"gigantic","textColor":"yellow","edge":"outline"}"#
        let decoded = try #require(SubtitleStyle(rawValue: raw))
        #expect(decoded.size == .standard)
        #expect(decoded.textColor == .yellow)
        #expect(decoded.edge == .outline)
        #expect(decoded.position == .bottom)
    }

    @Test func `current reads the stored style and falls back to the default`() throws {
        let suiteName = "subtitle-style.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(SubtitleStyle.current(in: defaults) == .default)

        defaults.set(custom.rawValue, forKey: SubtitleStyle.storageKey)
        #expect(SubtitleStyle.current(in: defaults) == custom)
    }

    // MARK: - Defaults

    @Test func `the default reproduces KSPlayer's previous look`() {
        let style = SubtitleStyle.default
        #expect(style.size.scale == 1)
        #expect(style.textColor == .white)
        #expect(style.background == .none)
        #expect(style.edge == .dropShadow)
        #expect(style.position.lift == 0)
    }

    @Test func `black text gets a white edge`() {
        #expect(SubtitleStyle(textColor: .black).edgeColor == .white)
        #expect(SubtitleStyle(textColor: .yellow).edgeColor == .black)
    }

    // MARK: - AVPlayer

    @Test func `the default style leaves AVPlayer unstyled`() {
        #expect(SubtitleStyle.default.avTextStyleRules == nil)
    }

    @Test func `a custom style maps onto CoreMedia text markup`() throws {
        let attributes = custom.avTextMarkupAttributes

        #expect(attributes[kCMTextMarkupAttribute_ForegroundColorARGB as String] as? [Double] == [1, 1, 0.9, 0])
        #expect(attributes[kCMTextMarkupAttribute_RelativeFontSize as String] as? Double == 150)
        #expect(attributes[kCMTextMarkupAttribute_BoldStyle as String] as? Bool == true)
        #expect(
            attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] as? String
                == kCMTextMarkupCharacterEdgeStyle_Uniform as String
        )
        #expect(
            attributes[kCMTextMarkupAttribute_GenericFontFamilyName as String] as? String
                == kCMTextMarkupGenericFontName_ProportionalSerif as String
        )
        let box = try #require(attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] as? [Double])
        #expect(box.first == SubtitleBackground.semiOpaque.opacity)
        #expect(attributes[kCMTextMarkupAttribute_BackgroundColorARGB as String] as? [Double] == box)
        let line = try #require(
            attributes[kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String] as? Double
        )
        #expect(abs(line - 68) < 0.001)
        #expect(custom.avTextStyleRules?.count == 1)
    }

    @Test func `no box, bottom position and system font add no markup`() {
        let attributes = SubtitleStyle(size: .large).avTextMarkupAttributes
        #expect(attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] == nil)
        #expect(attributes[kCMTextMarkupAttribute_BackgroundColorARGB as String] == nil)
        #expect(attributes[kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String] == nil)
        #expect(attributes[kCMTextMarkupAttribute_GenericFontFamilyName as String] == nil)
        #expect(attributes[kCMTextMarkupAttribute_BoldStyle as String] == nil)
    }
}
