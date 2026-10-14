//
//  TVTopShelfSettingsSection.swift
//  Lume
//
//  The Top Shelf block of the tvOS Library pane, above the areas: which profile
//  the Top Shelf follows, the rows promoted to it (in order, removable), and
//  its layout. Rows are promoted from the areas below — a row's ⭐ offers the
//  Top Shelf as well as the hero — and stay in their area; the Top Shelf shows
//  a copy, and the area's list marks it with a gold top edge. With no rows the
//  Top Shelf is off and tvOS shows the app's artwork. Stored per device (see
//  `TopShelfSettings`); every change rebuilds the snapshot straight away.
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

        private var profiles: [UserProfile] {
            profileManager?.profiles ?? []
        }

        private var followed: UserProfile? {
            let id = TopShelfSettings.profileID(among: profiles.map(\.id))
            return profiles.first { $0.id == id }
        }

        private var style: TopShelfConfiguration.Style {
            TopShelfConfiguration.Style(rawValue: styleRaw) ?? TopShelfConfiguration.default.style
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Top Shelf")

                if profiles.count > 1 {
                    TVOptionCycleRow(title: "Profile", valueLabel: followed?.name ?? "") {
                        guard let current = followed, let index = profiles.firstIndex(where: { $0.id == current.id }) else { return }
                        profileRaw = profiles[(index + 1) % profiles.count].id.uuidString
                    }
                }

                if sources.isEmpty {
                    Text("No rows yet. Press ⭐ on a row in an area below and choose Add to Top Shelf.")
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
                    if let followed, !TopShelfSettings.followsActiveProfile() {
                        Text("It follows \(followed.name): switch to that profile to change its rows or refresh it.")
                    }
                    if !sources.isEmpty, style == .carousel {
                        Text("The carousel shows movies and series. Channels have no wide artwork, so they appear only in Rows.")
                    }
                }
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.top, 6)
            }
            // Pin the default (the first profile) as a stored choice, so the
            // export and the areas' ⭐ can tell whether it is the active one.
            .onAppear(perform: storeDefaultProfile)
            .onChange(of: profiles.map(\.id)) { storeDefaultProfile() }
            .onChange(of: "\(sourcesRaw)|\(profileRaw)|\(styleRaw)|\(itemsPerSection)|\(activeProfileRaw)") {
                WidgetSnapshotExporter.refresh(container: modelContext.container, isChildProfile: profileManager?.activeProfileIsChild ?? false)
            }
        }

        private func storeDefaultProfile() {
            guard let id = TopShelfSettings.profileID(among: profiles.map(\.id)), profileRaw != id.uuidString else { return }
            TopShelfSettings.storeProfile(id)
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
