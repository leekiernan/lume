//
//  TVDetailButtons.swift
//  Lume
//
//  Focus-aware button styles and button components for the tvOS movie and
//  series detail screens. Split out from TVDetailComponents to keep each file
//  focused: this file owns the interactive controls (primary / glass / card
//  styles and the Play and secondary action buttons), while TVDetailComponents
//  owns the static layout pieces.
//
//  Everything here is tuned for the focus engine: cards and buttons lift and
//  gain a shadow when focused, mirroring tvOS system controls.
//

#if os(tvOS)

    import SwiftUI

    /// A translucent surface for secondary hero actions (Favorite, Watched). Fills
    /// the available width so a row of these matches the Play button above, and
    /// tints solid white when focused.
    struct TVGlassButtonStyle: ButtonStyle {
        var action: TVDetailMetrics.Action = .standard

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, action: action)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let action: TVDetailMetrics.Action
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                let foreground: Color = isFocused ? .lumeNight : .white
                // At rest, translucent Night over the backdrop (the detail
                // boards); focused, the system's white lift.
                let background: AnyShapeStyle = isFocused
                    ? AnyShapeStyle(.white)
                    : AnyShapeStyle(Color.lumeNight.opacity(0.6))
                let shadowOpacity: Double = isFocused ? 0.4 : 0
                return configuration.label
                    .foregroundStyle(foreground)
                    .frame(maxWidth: .infinity)
                    .frame(height: action.height)
                    .background(
                        RoundedRectangle(cornerRadius: action.cornerRadius, style: .continuous)
                            .fill(background)
                    )
                    .scaleEffect(isFocused ? 1.06 : 1.0)
                    .shadow(color: .black.opacity(shadowOpacity), radius: 18, y: 10)
                    .animation(.easeOut(duration: 0.18), value: isFocused)
            }
        }
    }

    /// Generic card lift used by episode, poster and cast cards.
    struct TVCardButtonStyle: ButtonStyle {
        var focusScale: CGFloat = 1.08
        /// Hides the focus lift while keeping real focus — used by the
        /// category rail to mask the engine's transient landing before it
        /// snaps focus to the selected category.
        var suppressFocusEffects = false
        /// Rings the whole card in focus (`cardFocusRing`), for cards that are
        /// artwork edge to edge with this corner radius: posters in rails and
        /// grids. A card captioned underneath rings its artwork itself.
        var focusRingCornerRadius: CGFloat?
        /// No shadow from the style at all: a card with a caption under its
        /// artwork, where a shadow would wrap the caption's text too.
        var castsShadow = true

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(
                configuration: configuration, focusScale: focusScale, suppressFocusEffects: suppressFocusEffects,
                focusRingCornerRadius: focusRingCornerRadius, castsShadow: castsShadow
            )
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let focusScale: CGFloat
            var suppressFocusEffects = false
            var focusRingCornerRadius: CGFloat?
            var castsShadow = true
            @Environment(\.isFocused) private var isFocusedRaw

            private var isFocused: Bool {
                isFocusedRaw && !suppressFocusEffects
            }

            var body: some View {
                let pressed = configuration.isPressed
                let scale: CGFloat = pressed ? focusScale * 0.97 : (isFocused ? focusScale : 1.0)
                let lifted = isFocused && castsShadow
                return configuration.label
                    .overlay {
                        if let focusRingCornerRadius {
                            CardFocusRing(cornerRadius: focusRingCornerRadius, isFocused: isFocused)
                        }
                    }
                    // The shadow is applied *before* the scale transform so it is
                    // rasterised once and then scaled as a bitmap, rather than the
                    // GPU re-blurring it on every frame of the focus animation
                    // (which happens when scaleEffect precedes shadow). A smaller
                    // radius further cuts the per-frame blur cost while still
                    // reading as a clear focus lift on the 10-foot UI.
                    .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: 12, y: 8)
                    .scaleEffect(scale)
                    .animation(.easeOut(duration: 0.18), value: isFocused)
                    .animation(.easeOut(duration: 0.1), value: pressed)
            }
        }
    }

    /// The one focus highlight every tvOS card shares: a white ring that
    /// follows the card's corners, at full strength and 4 pt in focus. A ring
    /// rather than the system's white fill, which would paint over artwork
    /// and team gradients, and rather than a glow, which washed out on the
    /// dark screens. Posters get it from `TVCardButtonStyle`; a card with a
    /// caption rings its artwork with `cardFocusRing(cornerRadius:)`.
    struct CardFocusRing: View {
        static let lineWidth: CGFloat = 4

        let cornerRadius: CGFloat
        let isFocused: Bool
        /// A hairline at rest, for cards whose surface needs an edge (the
        /// sports cards' gradients); none by default.
        var restingOpacity: Double = 0

        var body: some View {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(isFocused ? 1 : restingOpacity), lineWidth: isFocused ? Self.lineWidth : 1)
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .allowsHitTesting(false)
        }
    }

    extension View {
        /// Rings this view in focus — a captioned card's artwork, inside a
        /// button styled `TVCardButtonStyle(castsShadow: false)`. `isFocused`
        /// reads the nearest focusable ancestor, the card's button.
        func cardFocusRing(cornerRadius: CGFloat, restingOpacity: Double = 0) -> some View {
            modifier(CardFocusRingModifier(cornerRadius: cornerRadius, restingOpacity: restingOpacity))
        }
    }

    private struct CardFocusRingModifier: ViewModifier {
        let cornerRadius: CGFloat
        let restingOpacity: Double
        @Environment(\.isFocused) private var isFocused

        func body(content: Content) -> some View {
            content.overlay {
                CardFocusRing(cornerRadius: cornerRadius, isFocused: isFocused, restingOpacity: restingOpacity)
            }
        }
    }

    // MARK: - Buttons

    struct TVPlayButton: View {
        let title: LocalizedStringKey
        var systemImage: String = "play.fill"
        var isEnabled: Bool = true
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(TVGlassButtonStyle(action: .play))
            .disabled(!isEnabled)
        }
    }

    /// An icon-only secondary action (Favorite / Watched) shown below the Play
    /// button. The `title` is used as the accessibility label since no text is
    /// rendered.
    struct TVSecondaryActionButton: View {
        let title: LocalizedStringKey
        let systemImage: String
        var action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: systemImage)
                    .symbolReplaceTransition(value: systemImage)
                    .font(.system(size: 30, weight: .semibold))
            }
            .buttonStyle(TVGlassButtonStyle(action: .secondary))
            .accessibilityLabel(title)
        }
    }

#endif
