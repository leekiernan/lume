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

extension TopShelfSource {
    /// The row's name in its layout, or nil for a custom row since deleted.
    func rowName(defaults: UserDefaults = .standard) -> String? {
        switch ref {
        case let .builtin(section):
            return section.displayName
        case let .custom(id):
            let raw = defaults.string(forKey: CustomHomeSections.storageKey(surface)) ?? ""
            return CustomHomeSections.decode(raw).first { $0.id == id }?.title
        }
    }

    /// "Area · Row", for where rows of the same name from different areas
    /// would otherwise read alike.
    func qualified(_ name: String) -> String {
        "\(surface.displayName) · \(name)"
    }
}

/// What an export does, given who the Top Shelf follows, who is active and
/// whose rows the snapshot on disk shows — see `TopShelfSettings.exportAction`.
nonisolated enum TopShelfExportAction: Equatable {
    /// The Top Shelf is off: write an empty snapshot, and tvOS shows the
    /// app's artwork.
    case clear
    /// The followed profile is active: build its rows.
    case build
    /// Another profile is active and the snapshot already shows the followed
    /// profile's rows: leave it, since the catalog now holds the active
    /// profile's watch state, not the followed one's.
    case keep
}

/// A resolved empty row clears its old titles; an unavailable row keeps them.
nonisolated enum TopShelfRowContent: Equatable {
    case loaded([String])
    case unavailable
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
    /// What each list row last showed in the app, per profile — see `record`.
    private static let rowItemsKey = "topShelf.rowItems.v2"
    /// v1 kept one profile's rows and only while it held the Top Shelf.
    private static let legacyRowItemsKey = "topShelf.rowItems.v1"
    /// The profile whose rows the snapshot on disk shows; unset while it is
    /// empty. Lets an export tell a snapshot worth keeping from one left
    /// over from a profile the Top Shelf no longer follows.
    private static let snapshotProfileKey = "topShelf.snapshotProfile.v1"

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
            defaults.set(id.uuidString, forKey: rowsProfileKey)
        }
        defaults.set(id.uuidString, forKey: profileKey)
    }

    /// Whether the active profile is the one the Top Shelf follows — the only
    /// time its rows are rebuilt, recorded or offered in the app. Takes the
    /// raw stored values so views can pass their `@AppStorage` copies and
    /// stay in step with it.
    static func isOn(followedRaw: String?, activeRaw: String?) -> Bool {
        guard let followedRaw, !followedRaw.isEmpty else { return false }
        return followedRaw == activeRaw
    }

    /// The export's decision — a pure function of the three profiles, so the
    /// states can't drift. A snapshot of a profile the Top Shelf no longer
    /// follows is cleared rather than kept: its rows belong to someone else.
    static func exportAction(followed: UUID?, active: UUID, snapshotProfile: UUID?) -> TopShelfExportAction {
        exportAction(followed: followed, active: active, snapshotProfile: snapshotProfile, snapshotAccount: nil, currentAccount: nil)
    }

    static func exportAction(followed: UUID?, active: UUID, snapshotProfile: UUID?, snapshotAccount: String?, currentAccount: String?) -> TopShelfExportAction {
        guard let followed else { return .clear }
        if followed == active { return .build }
        // The catalogue holds another profile, so rebuilding isn't possible.
        // Clear its old personal recommendations rather than retaining them
        // across a change to the app-wide tracker account.
        if let snapshotAccount, snapshotAccount != currentAccount { return .clear }
        return snapshotProfile == followed ? .keep : .clear
    }

    static func snapshotProfile(defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: snapshotProfileKey).flatMap(UUID.init(uuidString:))
    }

    /// Records whose rows were just written; nil for an empty snapshot.
    static func setSnapshotProfile(_ id: UUID?, defaults: UserDefaults = .standard) {
        defaults.set(id?.uuidString, forKey: snapshotProfileKey)
    }

    // MARK: - What list rows last showed

    /// The titles a list row (trending, a watchlist, a custom list, For You)
    /// last showed, as `MediaItemKey`s (`HomeMediaItem.id`). Those rows come
    /// from the network or the recommender, which the background export
    /// doesn't run; it shows what the app last loaded instead, and a row not
    /// opened since keeps what it had.
    ///
    /// Every row is kept for whichever profile is active, whether or not the
    /// Top Shelf is on: what the Top Shelf can show must not depend on the
    /// order things happened in. Kept only while the Top Shelf was on, a row
    /// loaded before it was turned on — or before the row was promoted —
    /// stayed empty until its titles next changed.
    ///
    /// Call only for resolved rows, including an empty list. A failed load
    /// must use `.unavailable` rather than pretending it resolved empty.
    static func record(
        _ itemKeys: [String],
        for source: TopShelfSource,
        profile: UUID? = ActiveProfileStore.current,
        defaults: UserDefaults = .standard
    ) {
        record([source: itemKeys], profile: profile, defaults: defaults)
    }

    /// Records several rows with one read and at most one write, so a page
    /// that resolves its rows one by one doesn't rewrite the whole store (and
    /// post a defaults change) per row.
    static func record(
        _ rows: [TopShelfSource: [String]],
        profile: UUID? = ActiveProfileStore.current,
        defaults: UserDefaults = .standard
    ) {
        record(rows.mapValues(TopShelfRowContent.loaded), profile: profile, defaults: defaults)
    }

    static func record(
        _ rows: [TopShelfSource: TopShelfRowContent],
        profile: UUID? = ActiveProfileStore.current,
        accountScopes: [TopShelfSource: String] = [:],
        defaults: UserDefaults = .standard
    ) {
        guard let profile else { return }
        var stored = storedRows(defaults)
        var rowsOfProfile = stored[profile.uuidString] ?? [:]
        var changed = false
        for (source, content) in rows {
            guard case let .loaded(itemKeys) = content else { continue }
            let capped = Array(itemKeys.prefix(TopShelfConfiguration.maxItemsPerSection))
            let token = recordToken(source, accountScope: accountScopes[source])
            guard rowsOfProfile[token] != capped else { continue }
            rowsOfProfile[token] = capped
            changed = true
        }
        guard changed else { return }
        stored[profile.uuidString] = rowsOfProfile
        defaults.set(stored, forKey: rowItemsKey)
        defaults.removeObject(forKey: legacyRowItemsKey)
    }

    /// What `source` last showed for `profile` — the followed one, for the
    /// export.
    static func recordedItems(for source: TopShelfSource, profile: UUID?, accountScope: String? = nil, defaults: UserDefaults = .standard) -> [String] {
        guard let profile else { return [] }
        return storedRows(defaults)[profile.uuidString]?[recordToken(source, accountScope: accountScope)] ?? []
    }

    private static func recordToken(_ source: TopShelfSource, accountScope: String?) -> String {
        source.token + (accountScope.map { "|account:\($0)" } ?? "")
    }

    /// Profile → row token → item keys.
    private static func storedRows(_ defaults: UserDefaults) -> [String: [String: [String]]] {
        defaults.dictionary(forKey: rowItemsKey) as? [String: [String: [String]]] ?? [:]
    }
}
