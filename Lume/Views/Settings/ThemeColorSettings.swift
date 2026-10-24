//
//  ThemeColorSettings.swift
//  Lume
//
//  Picking the brand colour (`LumeColorTheme`) and logo (`LumeLogo`): a row
//  of swatches and a row of logo tiles under Appearance on iPhone, iPad and
//  Mac, and in its own category on tvOS, logo tiles above a list of colours.
//  Every screen redraws in the new colour and logo as they are picked.
//

import SwiftUI

/// One theme's colour: its accent, in this appearance.
struct ThemeSwatch: View {
    let theme: LumeColorTheme
    var size: CGFloat = 30

    var body: some View {
        Circle()
            .fill(LumePalette.of(theme).accent)
            .frame(width: size, height: size)
    }
}

#if !os(tvOS)
    /// The swatches, the one in use ringed and ticked. Shown with lume Pro only.
    struct ThemeColorPicker: View {
        @State private var store = LumeThemeStore.shared

        var body: some View {
            HStack(spacing: 12) {
                ForEach(LumeColorTheme.allCases) { theme in
                    let isSelected = store.theme == theme
                    Button { store.select(theme) } label: {
                        ThemeSwatch(theme: theme)
                            .overlay {
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(LumePalette.of(theme).onAccent)
                                }
                            }
                            .padding(3)
                            .overlay(Circle().strokeBorder(isSelected ? Color.lumeAccent : .clear, lineWidth: 2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(theme.title))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// The logos side by side, each mark large above its name; the one in use
    /// tinted and ringed, as the swatches are.
    struct ThemeLogoPicker: View {
        @State private var store = LumeThemeStore.shared

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Logo")
                HStack(spacing: 12) {
                    ForEach(LumeLogo.allCases) { logo in
                        let isSelected = store.logo == logo
                        Button { store.select(logo) } label: {
                            VStack(spacing: 8) {
                                LumeMark(logo: logo)
                                    .frame(width: 56, height: 56)
                                Text(verbatim: logo.title)
                                    .font(.footnote.weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(isSelected ? Color.lumeSelection : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(isSelected ? Color.lumeAccent : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1))
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: logo.title))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

#else
    /// tvOS: the themes as choices, each with its swatch. Its category is
    /// shown with lume Pro only.
    struct TVThemeColorSettings: View {
        @State private var store = LumeThemeStore.shared

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Logo")
                HStack(spacing: 20) {
                    ForEach(LumeLogo.allCases) { logo in
                        Button { store.select(logo) } label: {
                            TVLogoTile(logo: logo, isSelected: store.logo == logo)
                        }
                        .buttonStyle(TVSettingsRowButtonStyle())
                    }
                }
                .focusSection()
                TVSettingsSectionLabel("Color")
                    .padding(.top, 20)
                ForEach(LumeColorTheme.allCases) { theme in
                    Button { store.select(theme) } label: {
                        TVSettingsChoiceLabel(isSelected: store.theme == theme) {
                            HStack(spacing: 20) {
                                ThemeSwatch(theme: theme, size: 34)
                                Text(theme.title)
                            }
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                }
                Text("The logo and color lume uses for progress, selection and highlights, and for its app icon.")
                    .tvSettingsFooter()
                    .padding(.top, 6)
            }
        }
    }

    /// One logo as a tile: its mark large above its name, ticked when in use.
    /// The mark takes the theme's deep shade once focus turns the tile white,
    /// where the bright shades (lume green 1.2:1) all but vanish.
    private struct TVLogoTile: View {
        let logo: LumeLogo
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            VStack(spacing: 14) {
                LumeMark(color: .lumeFocusAwareAccent(isFocused: isFocused), logo: logo)
                    .frame(width: 120, height: 120)
                HStack(spacing: 10) {
                    Text(verbatim: logo.title)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(TVSettingsAccentStyle())
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
#endif
