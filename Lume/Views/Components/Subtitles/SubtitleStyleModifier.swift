import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

extension SubtitleStyle {
    /// The point size `SubtitleTextSize.standard` renders at — KSPlayer's
    /// `SubtitleModel.Size.standard`, so the default style keeps the size
    /// subtitles always had.
    static var standardPointSize: CGFloat {
        #if os(tvOS) || os(visionOS)
            58
        #elseif os(macOS)
            26
        #else
            UIDevice.current.userInterfaceIdiom == .phone ? 16 : 26
        #endif
    }

    var pointSize: CGFloat {
        Self.standardPointSize * size.scale
    }

    var swiftUIFont: Font {
        .system(size: pointSize, weight: bold ? .bold : .regular, design: font.design)
    }
}

extension SubtitleColor {
    var color: Color {
        Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

extension SubtitleFontDesign {
    var design: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

extension View {
    /// Draws a subtitle cue's text in `style`: font, colour, edge and the box
    /// behind it. Shared by the engines that render subtitles in SwiftUI and the
    /// Settings preview, so the preview is exactly what the player draws.
    func subtitleStyle(_ style: SubtitleStyle) -> some View {
        modifier(SubtitleStyleModifier(style: style))
    }

    /// Raises a full-height subtitle layer by `position`'s share of its height.
    /// An offset rather than padding, so the cue layout inside stays untouched.
    func subtitleLift(_ position: SubtitlePosition) -> some View {
        let lift = position.lift
        return visualEffect { content, proxy in
            content.offset(y: -proxy.size.height * lift)
        }
    }
}

private struct SubtitleStyleModifier: ViewModifier {
    let style: SubtitleStyle

    func body(content: Content) -> some View {
        let size = style.pointSize
        let hasBox = style.background != .none
        content
            .font(style.swiftUIFont)
            .foregroundStyle(style.textColor.color)
            // The edge goes on before the box so it outlines the glyphs, not
            // the box.
            .modifier(SubtitleEdgeModifier(edge: style.edge, color: style.edgeColor.color, width: max(1, size / 18)))
            .padding(.horizontal, hasBox ? size * 0.3 : 0)
            .padding(.vertical, hasBox ? size * 0.08 : 0)
            .background {
                if hasBox {
                    RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                        .fill(style.backgroundColor.color.opacity(style.background.opacity))
                }
            }
    }
}

/// SwiftUI has no text stroke, so the outline is four stacked short-offset
/// shadows: each one shadows the text plus the shadows before it, which grows
/// into an even rim around every glyph.
private struct SubtitleEdgeModifier: ViewModifier {
    let edge: SubtitleEdge
    let color: Color
    let width: CGFloat

    func body(content: Content) -> some View {
        switch edge {
        case .none:
            content
        case .dropShadow:
            // KSPlayer's own shadow, unchanged, so the default looks as before.
            content.shadow(color: color.opacity(0.9), radius: 1, x: 1, y: 1)
        case .outline:
            content
                .shadow(color: color, radius: width * 0.25, x: width, y: 0)
                .shadow(color: color, radius: width * 0.25, x: -width, y: 0)
                .shadow(color: color, radius: width * 0.25, x: 0, y: width)
                .shadow(color: color, radius: width * 0.25, x: 0, y: -width)
        case .raised:
            content
                .shadow(color: .white.opacity(0.45), radius: 0, x: -width * 0.5, y: -width * 0.5)
                .shadow(color: color.opacity(0.9), radius: 0, x: width * 0.7, y: width * 0.7)
        }
    }
}
