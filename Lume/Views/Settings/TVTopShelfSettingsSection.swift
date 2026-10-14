//
//  TVTopShelfSettingsSection.swift
//  Lume
//
//  The Top Shelf block of the tvOS Home settings pane: switch Lume's Top Shelf
//  off, pick rows or the backdrop carousel, choose how many items a section
//  holds, and turn sections on or off and reorder them like the Home rows.
//  Stored per device (see `TopShelfSettings`); every change is written into
//  the snapshot straight away so the Top Shelf follows without a re-export.
//

import SwiftUI

#if os(tvOS)

    struct TVTopShelfSettingsSection: View {
        /// A Top Shelf section as a row of the shared reorderable list — the
        /// same lift-to-move row as the Home sections above it.
        private struct Row: ReorderableRowItem {
            let section: TopShelfSettings.Section
            var id: String {
                section.rawValue
            }
        }

        /// The settings pane's scroll view, so a lifted row stays in view.
        let proxy: ScrollViewProxy

        @AppStorage(TopShelfSettings.enabledKey) private var isEnabled = TopShelfConfiguration.default.isEnabled
        @AppStorage(TopShelfSettings.styleKey) private var styleRaw = TopShelfConfiguration.default.style.rawValue
        @AppStorage(TopShelfSettings.itemsPerSectionKey) private var itemsPerSection = TopShelfConfiguration.default.itemsPerSection
        @AppStorage(TopShelfSettings.sectionOrderKey) private var sectionOrderRaw = ""
        @AppStorage(TopShelfSettings.disabledSectionsKey) private var disabledSectionsRaw = ""
        @State private var isReordering = false

        private var sections: [TopShelfSettings.Section] {
            TopShelfSettings.resolve(orderRaw: sectionOrderRaw)
        }

        private var disabledSections: Set<TopShelfSettings.Section> {
            Set(TopShelfSettings.decode(disabledSectionsRaw))
        }

        private var style: TopShelfConfiguration.Style {
            TopShelfConfiguration.Style(rawValue: styleRaw) ?? TopShelfConfiguration.default.style
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Top Shelf")

                TVOptionToggleRow(title: "Show in Top Shelf", isOn: $isEnabled)

                if isEnabled {
                    TVOptionCycleRow(title: "Layout", valueLabel: style.label) {
                        styleRaw = style == .sectioned
                            ? TopShelfConfiguration.Style.carousel.rawValue
                            : TopShelfConfiguration.Style.sectioned.rawValue
                    }

                    TVOptionCycleRow(title: "Items per Section", valueLabel: "\(itemsPerSection)") {
                        itemsPerSection = Self.nextItemCount(after: itemsPerSection)
                    }

                    TVReorderableContentList(
                        items: sections.map(Row.init),
                        title: { $0.section.displayName },
                        isHidden: { disabledSections.contains($0.section) },
                        onToggleHidden: { toggle($0.section) },
                        onCommitOrder: { rows in sectionOrderRaw = TopShelfSettings.encode(rows.map(\.section)) },
                        isReordering: $isReordering,
                        scrollProxy: proxy,
                        icon: { $0.section.systemImage }
                    )
                    .padding(.top, 8)
                }

                Group {
                    Text("What lume shows above its icon on the Apple TV Home Screen. A section appears only when it has something to show. When switched off, the Top Shelf shows the lume artwork.")
                    if isEnabled, style == .carousel {
                        Text("The carousel shows movies and series. Channels have no wide artwork, so they appear only in Rows.")
                    }
                }
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.top, 6)
            }
            .onChange(of: TopShelfSettings.configuration()) {
                TopShelfSettings.apply()
            }
        }

        private func toggle(_ section: TopShelfSettings.Section) {
            var disabled = disabledSections
            if disabled.contains(section) { disabled.remove(section) } else { disabled.insert(section) }
            disabledSectionsRaw = TopShelfSettings.encode(disabled, sorted: true)
        }

        /// The next item-count choice, wrapping around after the largest.
        static func nextItemCount(after current: Int) -> Int {
            let choices = TopShelfConfiguration.itemCountChoices
            guard let index = choices.firstIndex(of: current) else { return choices[0] }
            return choices[(index + 1) % choices.count]
        }
    }

    private extension TopShelfConfiguration.Style {
        var label: String {
            switch self {
            case .sectioned: String(localized: "Rows", comment: "Top Shelf layout: rows of posters under section titles")
            case .carousel: String(localized: "Carousel", comment: "Top Shelf layout: full-width backdrop carousel")
            }
        }
    }

    private extension TopShelfConfiguration.Section {
        var displayName: String {
            switch self {
            case .continueWatching: String(localized: "Continue Watching")
            case .favorites: String(localized: "Favorites")
            }
        }

        var systemImage: String {
            switch self {
            case .continueWatching: "clock.arrow.circlepath"
            case .favorites: "star"
            }
        }
    }

#endif
