//
//  TopShelfSettings.swift
//  Lume
//
//  The user's Top Shelf choices (Settings › Library on tvOS): which rows of the
//  Home, Movies and Series layouts are promoted to it and in what order, which
//  profile it follows, the layout and how many items a row holds. Stored per
//  device in plain UserDefaults — each Apple TV has its own Top Shelf, so none
//  of this syncs.
//
//  A row's layout and its titles belong to a profile, so the Top Shelf follows
//  one: it is rebuilt only while that profile is active, and keeps its last
//  snapshot while another is in use.
//

import Foundation

/// A row promoted to the Top Shelf: one section of one surface's layout. The
/// row stays in its layout; the Top Shelf shows a copy of it.
nonisolated struct TopShelfSource: Hashable, Identifiable {
    let surface: SectionSurface
    let ref: HomeSectionRef

    /// `surface/sectionToken`, the stored form and the row's identity in the
    /// snapshot.
    var token: String {
        "\(surface.rawValue)/\(ref.token)"
    }

    var id: String {
        token
    }

    init(surface: SectionSurface, ref: HomeSectionRef) {
        self.surface = surface
        self.ref = ref
    }

    init?(token: String) {
        let parts = token.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let surface = SectionSurface(rawValue: parts[0]),
              let ref = HomeSectionRef(token: parts[1]) else { return nil }
        self.init(surface: surface, ref: ref)
    }
}

nonisolated enum TopShelfSettings {
    static let styleKey = "topShelf.style.v1"
    static let itemsPerSectionKey = "topShelf.itemsPerSection.v1"
    /// The promoted rows, top to bottom, as comma-separated `TopShelfSource`
    /// tokens. Empty is the default and means the Top Shelf is off.
    static let sourcesKey = "topShelf.sources.v1"
    /// The profile the Top Shelf follows. Unset means the first profile.
    static let profileKey = "topShelf.profile.v1"
    /// What each promoted list row last showed in the app — see `record`.
    private static let rowItemsKey = "topShelf.rowItems.v1"

    /// The layout choices as the configuration the Top Shelf reads.
    static func configuration(defaults: UserDefaults = .standard) -> TopShelfConfiguration {
        let fallback = TopShelfConfiguration.default
        let count = defaults.integer(forKey: itemsPerSectionKey)
        return TopShelfConfiguration(
            style: defaults.string(forKey: styleKey).flatMap(TopShelfConfiguration.Style.init) ?? fallback.style,
            itemsPerSection: TopShelfConfiguration.itemCountChoices.contains(count) ? count : fallback.itemsPerSection
        )
    }

    // MARK: - Promoted rows

    static func sources(defaults: UserDefaults = .standard) -> [TopShelfSource] {
        decode(defaults.string(forKey: sourcesKey) ?? "")
    }

    static func decode(_ raw: String) -> [TopShelfSource] {
        var seen = Set<TopShelfSource>()
        return raw.split(separator: ",").compactMap { TopShelfSource(token: String($0)) }.filter { seen.insert($0).inserted }
    }

    static func encode(_ sources: [TopShelfSource]) -> String {
        sources.map(\.token).joined(separator: ",")
    }

    /// Adds `source` at the bottom of the Top Shelf, or takes it off.
    static func toggled(_ source: TopShelfSource, in sources: [TopShelfSource]) -> [TopShelfSource] {
        sources.contains(source) ? sources.filter { $0 != source } : sources + [source]
    }

    // MARK: - Profile

    /// The profile the Top Shelf follows: the stored one while it still exists,
    /// otherwise the first.
    static func profileID(among profiles: [UUID], defaults: UserDefaults = .standard) -> UUID? {
        if let stored = defaults.string(forKey: profileKey).flatMap(UUID.init(uuidString:)), profiles.contains(stored) {
            return stored
        }
        return profiles.first
    }

    /// Records which profile the Top Shelf follows, resolving the default (the
    /// first profile) into a stored choice so the export and `record` can
    /// check it without the profile list.
    static func storeProfile(_ id: UUID, defaults: UserDefaults = .standard) {
        defaults.set(id.uuidString, forKey: profileKey)
    }

    /// Whether the active profile is the one the Top Shelf follows — the only
    /// time its rows are rebuilt or recorded.
    static func followsActiveProfile(defaults: UserDefaults = .standard) -> Bool {
        guard let followed = defaults.string(forKey: profileKey) else { return false }
        return ActiveProfileStore.current?.uuidString == followed
    }

    // MARK: - What list rows last showed

    /// The titles a promoted list row (trending, a watchlist, a custom list,
    /// For You) last showed, as `WidgetSnapshotExporter.itemKey`s. Those rows
    /// come from the network or the recommender, which the background export
    /// doesn't run; it shows what the app last loaded instead, and a row not
    /// opened since keeps what it had. Only promoted rows are kept.
    static func record(_ itemKeys: [String], for source: TopShelfSource, defaults: UserDefaults = .standard) {
        guard followsActiveProfile(defaults: defaults), sources(defaults: defaults).contains(source) else { return }
        var stored = defaults.dictionary(forKey: rowItemsKey) as? [String: [String]] ?? [:]
        let capped = Array(itemKeys.prefix(TopShelfConfiguration.maxItemsPerSection))
        guard stored[source.token] != capped else { return }
        stored[source.token] = capped
        defaults.set(stored, forKey: rowItemsKey)
    }

    static func recordedItems(for source: TopShelfSource, defaults: UserDefaults = .standard) -> [String] {
        (defaults.dictionary(forKey: rowItemsKey) as? [String: [String]])?[source.token] ?? []
    }
}
