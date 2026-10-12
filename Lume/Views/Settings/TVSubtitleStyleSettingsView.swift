//
//  TVSubtitleStyleSettingsView.swift
//  Lume
//
//  Settings › Player › Subtitle Style on tvOS, drilled into in place inside the
//  Player pane. The options sit in a two-column grid under the preview so the
//  whole pane fits on screen and the preview never scrolls away. Focus: entry
//  lands on Size; left/right switch columns, up/down move within one, left from
//  the left column returns to the sidebar.
//

#if os(tvOS)

    import SwiftUI

    struct TVSubtitleStyleSettingsView: View {
        @AppStorage(SubtitleStyle.storageKey) private var style = SubtitleStyle.default
        @FocusState private var sizeFocused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 28) {
                TVSettingsSectionLabel("Subtitle Style")

                SubtitleStylePreview(style: style)
                    .frame(maxWidth: 760)

                Grid(horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        cycleRow("Size", style.size.title) { style.size = style.size.cycledNext() }
                            .focused($sizeFocused)
                        cycleRow("Font", style.font.title) { style.font = style.font.cycledNext() }
                    }
                    GridRow {
                        TVOptionToggleRow(title: "Bold", isOn: $style.bold)
                        cycleRow("Text Color", style.textColor.title) { style.textColor = style.textColor.cycledNext() }
                    }
                    GridRow {
                        cycleRow("Box", style.background.title) { style.background = style.background.cycledNext() }
                        cycleRow("Box Color", style.backgroundColor.title) {
                            style.backgroundColor = style.backgroundColor.cycledNext()
                        }
                    }
                    GridRow {
                        cycleRow("Edge", style.edge.title) { style.edge = style.edge.cycledNext() }
                        cycleRow("Position", style.position.title) { style.position = style.position.cycledNext() }
                    }
                    GridRow {
                        // Always enabled: a disabled row would leave a hole that
                        // down from the grid's last row couldn't land in.
                        Button("Reset to Default") { style = .default }
                            .buttonStyle(TVSettingsRowButtonStyle())
                            .gridCellColumns(2)
                    }
                }

                Text("Applies to KSPlayer and AVPlayer; VLCKit follows the size only. Image-based subtitles, such as those on Blu-ray rips, can be moved but not restyled.")
                    .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            }
            // Deferred: the drill-in row that opened this pane is still being
            // torn down on the first render.
            .onAppear { Task { @MainActor in sizeFocused = true } }
        }

        private func cycleRow(
            _ title: LocalizedStringKey,
            _ value: LocalizedStringResource,
            action: @escaping () -> Void
        ) -> some View {
            TVOptionCycleRow(title: title, valueLabel: String(localized: value), onAdvance: action)
        }
    }

    private extension CaseIterable where Self: Equatable, AllCases: BidirectionalCollection {
        /// The next case, wrapping to the first — what a cycle row advances to.
        func cycledNext() -> Self {
            let all = Self.allCases
            guard let index = all.firstIndex(of: self) else { return self }
            let next = all.index(after: index)
            return next == all.endIndex ? all[all.startIndex] : all[next]
        }
    }

#endif
