//
//  TVTopShelfSettingsSection.swift
//  Lume
//
//  The Top Shelf block of the tvOS Library pane, above the areas: the rows
//  promoted to it (in order, removable) and its layout. Shown only while the
//  active profile has the Top Shelf on (in its profile editor). Rows are
//  promoted from the areas below — a long press on a row's ⭐ — and stay in
//  their area; the Top Shelf shows a copy, and the area's list marks it with a
//  gold top edge. With no rows tvOS shows the app's artwork. Stored per device
//  (see `TopShelfSettings`); every change rebuilds the snapshot straight away.
//

import SwiftData
import SwiftUI

#if os(tvOS)

    extension Color {
        /// Marks a row that is on the Top Shelf, in its area's list.
        static let topShelfGold = Color(red: 0.96, green: 0.77, blue: 0.29)
    }

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
        @Environment(\.modelContext) private var modelContext
        @Environment(ProfileManager.self) private var profileManager: ProfileManager?
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
            !profileRaw.isEmpty && profileRaw == activeProfileRaw
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
                    Text("No rows yet. Press and hold ⭐ on a row in an area below to add it.")
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
                        styleRaw = style == .sectioned
                            ? TopShelfConfiguration.Style.carousel.rawValue
                            : TopShelfConfiguration.Style.sectioned.rawValue
                    }
                    .padding(.top, 8)

                    TVOptionCycleRow(title: "Items per Section", valueLabel: "\(itemsPerSection)") {
                        itemsPerSection = Self.nextItemCount(after: itemsPerSection)
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
            .onChange(of: "\(sourcesRaw)|\(styleRaw)|\(itemsPerSection)") {
                WidgetSnapshotExporter.refresh(container: modelContext.container, isChildProfile: profileManager?.activeProfileIsChild ?? false)
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
            let name: String = switch source.ref {
            case let .builtin(section):
                section.displayName
            case let .custom(id):
                CustomHomeSections.decode(UserDefaults.standard.string(forKey: CustomHomeSections.storageKey(source.surface)) ?? "")
                    .first { $0.id == id }?.title ?? String(localized: "Removed Row")
            }
            return "\(source.surface.displayName) · \(name)"
        }

        private func icon(for source: TopShelfSource) -> String? {
            source.ref.builtin?.systemImage ?? "list.bullet.rectangle"
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

#endif
