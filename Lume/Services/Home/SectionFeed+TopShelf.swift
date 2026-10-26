extension SectionFeed {
    /// Record terminal outcomes, not transient emptiness during a reset or
    /// failure. The context owns the profile even if a late load finishes
    /// after that profile has left the screen.
    func recordTopShelfRows(for source: SectionFeedSource) {
        #if os(tvOS)
            var rows: [TopShelfSource: TopShelfRowContent] = [:]
            var accounts: [TopShelfSource: String] = [:]
            for (ref, collection) in collections where SectionFeedSource(row: ref) == source {
                let shelfSource = TopShelfSource(surface: surface, ref: ref)
                if let section = requestedCustomSections.first(where: { .custom($0.id) == ref }), let authenticated = section.authenticatedList {
                    guard let account = authenticated.accountScope(TraktService.shared.username) else { continue }
                    accounts[shelfSource] = account
                }
                rows[shelfSource] = loads.failedRows.contains(ref)
                    ? .unavailable : .loaded(collection.preview.map(\.id))
            }
            if !rows.isEmpty { TopShelfSettings.record(rows, profile: context?.profileID, accountScopes: accounts) }
        #endif
    }
}
