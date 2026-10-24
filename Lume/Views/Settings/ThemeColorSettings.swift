//
//  ThemeColorSettings.swift
//  Lume
//
//  Picking the brand colour (`LumeColorTheme`): a row of swatches under
//  Appearance on iPhone, iPad and Mac, and a list of choices in its own
//  category on tvOS. Every screen redraws in the new colour as it is picked.
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

#else
    /// tvOS: the themes as choices, each with its swatch. Its category is
    /// shown with lume Pro only.
    struct TVThemeColorSettings: View {
        @State private var store = LumeThemeStore.shared

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
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
                Text("The color lume uses for progress, selection and highlights, and for its app icon.")
                    .tvSettingsFooter()
                    .padding(.top, 6)
            }
        }
    }
#endif
