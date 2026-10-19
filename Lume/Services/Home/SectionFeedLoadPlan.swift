import Foundation

/// Hero selection restarts the custom lane without invalidating its list
/// cache; a rename does neither. Source edits invalidate all catalogue lanes.
struct SectionFeedLoadKeys {
    let surface: SectionSurface
    let catalog: String
    let customCache: String
    let customTask: String

    init(surface: SectionSurface, catalog: String, sections: [CustomHomeSection], heroSelection: String, traktAccount: String?, proxySourceIdentity: String? = nil) {
        self.surface = surface
        self.catalog = proxySourceIdentity.map { "\(catalog)|sources:\($0)" } ?? catalog
        customCache = "custom-\(self.catalog)-\(CustomHomeSections.contentSignature(sections))"
            + CustomHomeSections.accountSignature(sections, traktUsername: traktAccount)
        customTask = "\(customCache)-hero-\(heroSelection)"
    }

    func watchlist(_ provider: WatchlistProvider, account: String?) -> String {
        "watchlist-\(provider)-\(surface.rawValue)-\(account ?? "disconnected")-\(catalog)"
    }
}

/// One plan derived from the same visibility/order preferences as rendering.
/// The hero leads, even when its original rail position is further down.
struct SectionFeedLoadPlan {
    let rows: [HomeSectionRef]
    let customSections: [CustomHomeSection]

    init(rows: [HomeSectionRef], hero: HomeSectionRef?, customSections: [CustomHomeSection]) {
        var seen = Set<HomeSectionRef>()
        self.rows = ([hero].compactMap(\.self) + rows).filter { seen.insert($0).inserted }
        self.customSections = self.rows.compactMap { ref in
            customSections.first { .custom($0.id) == ref }
        }
    }

    func requests(_ source: SectionFeedSource) -> Bool {
        rows.contains { SectionFeedSource(row: $0) == source }
    }

    /// Built-in feeds can supply multiple rows, but are fetched only once.
    var jobs: [HomeSectionRef] {
        var seen = Set<SectionFeedSource>()
        return rows.filter { ref in
            guard let source = SectionFeedSource(row: ref) else { return false }
            return source == .custom || seen.insert(source).inserted
        }
    }
}
