//
//  TVTopShelfSettingsSection.swift
//  Lume
//
//  The Top Shelf block of the tvOS Library pane, above the areas: the rows
//  promoted to it (in order, removable) and its layout. Shown only while the
//  active profile has the Top Shelf on (in its profile editor). Rows are
//  promoted from the areas below with a row's 📺 button, which shows gold
//  while the row is on the Top Shelf, and stay in their area; the Top Shelf
//  shows a copy. With no rows tvOS shows the app's artwork. Stored per device
//  (see `TopShelfSettings`); every change rebuilds the snapshot straight away.
//

import SwiftData
import SwiftUI

#if os(tvOS)

    struct TVTopShelfSettingsSection: View {
        /// A promoted row as a row of the shared reorderable list.
        private struct Row: ReorderableRowItem {
            let source: TopShelfSource
            var id: String {
                source.token
            }
        }

        /// The settings pane's scroll view, so a lifted row stays in view.
        let proxy: ScrollViewProxy

        @AppStorage(TopShelfSettings.sourcesKey) private var sourcesRaw = ""
        @AppStorage(TopShelfSettings.profileKey) private var profileRaw = ""
        @AppStorage(TopShelfSettings.styleKey) private var styleRaw = TopShelfConfiguration.default.style.rawValue
        @AppStorage(TopShelfSettings.itemsPerSectionKey) private var itemsPerSection = TopShelfConfiguration.default.itemsPerSection
        @AppStorage(ActiveProfileStore.key) private var activeProfileRaw = ""
        @Environment(\.topShelfRefresher) private var topShelf
        @State private var isReordering = false

        private var sources: [TopShelfSource] {
            TopShelfSettings.decode(sourcesRaw)
        }

        private var style: TopShelfConfiguration.Style {
            TopShelfConfiguration.Style(rawValue: styleRaw) ?? TopShelfConfiguration.default.style
        }

        /// Reads both stored keys, so the block appears and goes as the
        /// profile or the Top Shelf's owner changes.
        private var isOn: Bool {
            TopShelfSettings.isOn(followedRaw: profileRaw, activeRaw: activeProfileRaw)
        }

        var body: some View {
            if isOn {
                content
            }
        }

        private var content: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Top Shelf")

                if sources.isEmpty {
                    Text("No rows yet. Press \(Image(systemName: "tv")) on a row in an area below to add it.")
                        .tvSettingsFooter()
                        .padding(.top, 6)
                } else {
                    TVReorderableContentList(
                        items: sources.map(Row.init),
                        title: { title(for: $0.source) },
                        isHidden: { _ in false },
                        onToggleHidden: nil,
                        onCommitOrder: { rows in sourcesRaw = TopShelfSettings.encode(rows.map(\.source)) },
                        isReordering: $isReordering,
                        scrollProxy: proxy,
                        icon: { icon(for: $0.source) },
                        actions: { row in AnyView(removeButton(row.source)) }
                    )

                    TVOptionCycleRow(title: "Layout", valueLabel: style.label) {
                        styleRaw = TopShelfConfiguration.Style.allCases.element(after: style).rawValue
                    }
                    .padding(.top, 8)

                    TVOptionCycleRow(title: "Items per Section", valueLabel: "\(itemsPerSection)") {
                        itemsPerSection = TopShelfConfiguration.itemCountChoices.element(after: itemsPerSection)
                    }
                }

                Group {
                    Text("What lume shows above its icon on the Apple TV Home Screen, refreshed when you leave lume. A row appears only when it has something to show.")
                    if !sources.isEmpty, style == .carousel {
                        Text("The carousel shows movies and series. Channels have no wide artwork, so they appear only in Rows.")
                    }
                }
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.top, 6)
            }
            .onChange(of: Settings(sources: sourcesRaw, style: styleRaw, itemsPerSection: itemsPerSection)) {
                topShelf?.refresh()
            }
        }

        private func removeButton(_ source: TopShelfSource) -> some View {
            Button {
                sourcesRaw = TopShelfSettings.encode(sources.filter { $0 != source })
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(TVContentIconButtonStyle())
            .accessibilityLabel("Remove \(title(for: source)) from the Top Shelf")
        }

        /// "Area · Row", since rows of the same name come from different areas.
        private func title(for source: TopShelfSource) -> String {
            source.qualified(source.rowName() ?? String(localized: "Removed Row"))
        }

        private func icon(for source: TopShelfSource) -> String? {
            source.ref.builtin?.systemImage ?? "list.bullet.rectangle"
        }

        /// What the Top Shelf is rebuilt on when it changes.
        private struct Settings: Equatable {
            let sources: String
            let style: String
            let itemsPerSection: Int
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

#endif
