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
//  one, chosen in the profile editor: it is rebuilt only while that profile is
//  active, and keeps its last snapshot while another is in use. No profile
//  means the Top Shelf is off.
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
    /// The profile the Top Shelf follows, turned on in that profile's editor.
    /// Unset means the Top Shelf is off and tvOS shows the app's artwork.
    static let profileKey = "topShelf.profile.v1"
    /// The profile `sourcesKey` belongs to, kept while the Top Shelf is off
    /// so turning it back on for the same profile restores its rows.
    private static let rowsProfileKey = "topShelf.rowsProfile.v1"
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

    /// The profile the Top Shelf follows, if it is on.
    static func followedProfile(defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: profileKey).flatMap(UUID.init(uuidString:))
    }

    /// Turns the Top Shelf on for `id`, which turns it off for every other
    /// profile, or off altogether with `nil`. A row belongs to one profile's
    /// layout, so another profile starts with no rows; turning it off keeps
    /// them for when the same profile turns it back on.
    static func setFollowedProfile(_ id: UUID?, defaults: UserDefaults = .standard) {
        guard let id else {
            defaults.removeObject(forKey: profileKey)
            return
        }
        // Rows stored before the owner was tracked belong to the followed profile.
        let owner = defaults.string(forKey: rowsProfileKey) ?? defaults.string(forKey: profileKey)
        if owner != id.uuidString {
            defaults.removeObject(forKey: sourcesKey)
            defaults.removeObject(forKey: rowItemsKey)
            defaults.set(id.uuidString, forKey: rowsProfileKey)
        }
        defaults.set(id.uuidString, forKey: profileKey)
    }

    /// Whether the active profile is the one the Top Shelf follows — the only
    /// time its rows are rebuilt, recorded or offered in the app.
    static func followsActiveProfile(defaults: UserDefaults = .standard) -> Bool {
        guard let followed = defaults.string(forKey: profileKey) else { return false }
        return ActiveProfileStore.current?.uuidString == followed
    }

    // MARK: - What list rows last showed

    /// The titles a list row (trending, a watchlist, a custom list, For You)
    /// last showed, as `WidgetSnapshotExporter.itemKey`s. Those rows come from
    /// the network or the recommender, which the background export doesn't
    /// run; it shows what the app last loaded instead, and a row not opened
    /// since keeps what it had. Every row of the followed profile is kept, not
    /// just the promoted ones, so a row promoted from Settings has titles
    /// straight away rather than only after its area is next opened.
    static func record(_ itemKeys: [String], for source: TopShelfSource, defaults: UserDefaults = .standard) {
        guard followsActiveProfile(defaults: defaults) else { return }
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
