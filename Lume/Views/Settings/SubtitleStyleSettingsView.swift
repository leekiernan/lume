//
//  SubtitleStyleSettingsView.swift
//  Lume
//
//  Settings › Player › Subtitle Style on iOS / macOS / visionOS: the live
//  preview pinned above the options, so it stays in view while any of them
//  changes. tvOS builds its own pane in TVSubtitleStyleSettingsView.
//

#if !os(tvOS)

    import SwiftUI

    struct SubtitleStyleSettingsView: View {
        @AppStorage(SubtitleStyle.storageKey) private var style = SubtitleStyle.default

        var body: some View {
            VStack(spacing: 0) {
                SubtitleStylePreview(style: style)
                    .frame(maxWidth: 640)
                    .padding(.horizontal)
                    .padding(.vertical, 12)

                List {
                    Section {
                        Picker("Size", selection: $style.size) {
                            ForEach(SubtitleTextSize.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Font", selection: $style.font) {
                            ForEach(SubtitleFontDesign.allCases) { Text($0.title).tag($0) }
                        }
                        Toggle("Bold", isOn: $style.bold)
                        SubtitleColorSwatches(title: "Text Color", selection: $style.textColor)
                    } header: {
                        Text("Text")
                    }

                    Section {
                        Picker("Box", selection: $style.background) {
                            ForEach(SubtitleBackground.allCases) { Text($0.title).tag($0) }
                        }
                        if style.background != .none {
                            SubtitleColorSwatches(title: "Box Color", selection: $style.backgroundColor)
                        }
                    } header: {
                        Text("Background")
                    }

                    Section {
                        Picker("Edge", selection: $style.edge) {
                            ForEach(SubtitleEdge.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Position", selection: $style.position) {
                            ForEach(SubtitlePosition.allCases) { Text($0.title).tag($0) }
                        }
                    } header: {
                        Text("Edge & Position")
                    }

                    Section {
                        Button("Reset to Default") { style = .default }
                            .disabled(style == .default)
                    } footer: {
                        Text("Applies to KSPlayer and AVPlayer; VLCKit follows the size only. Image-based subtitles, such as those on Blu-ray rips, can be moved but not restyled.")
                    }
                }
                .pickerStyle(.menu)
            }
            .groupedListBackground()
            .platformNavigationTitle("Subtitle Style")
        }
    }

    /// A row of colour swatches — a menu can't show the colours themselves. The
    /// selected swatch carries a checkmark, not just a ring, so the choice reads
    /// without relying on colour.
    private struct SubtitleColorSwatches: View {
        let title: LocalizedStringKey
        @Binding var selection: SubtitleColor

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                HStack(spacing: 6) {
                    ForEach(SubtitleColor.allCases) { color in
                        swatch(color)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(title))
            }
            .padding(.vertical, 4)
        }

        private func swatch(_ color: SubtitleColor) -> some View {
            let isSelected = color == selection
            return Button {
                selection = color
            } label: {
                Circle()
                    .fill(color.color)
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 1))
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(color.isLight ? .black : .white)
                        }
                    }
                    .frame(width: 26, height: 26)
                    .padding(3)
                    .overlay {
                        if isSelected {
                            Circle().strokeBorder(.tint, lineWidth: 2)
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(color.title))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private extension View {
        /// Fills the strip around the pinned preview with the grouped list's
        /// own background, so preview and list read as one surface.
        func groupedListBackground() -> some View {
            #if os(iOS)
                background(Color(uiColor: .systemGroupedBackground))
            #else
                self
            #endif
        }
    }

    private extension SubtitleColor {
        var isLight: Bool {
            switch self {
            case .white, .yellow, .cyan, .green: true
            case .magenta, .red, .blue, .black: false
            }
        }
    }

    #Preview {
        NavigationStack {
            SubtitleStyleSettingsView()
        }
    }

#endif
