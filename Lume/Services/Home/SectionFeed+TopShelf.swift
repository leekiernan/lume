extension SectionFeed {
    /// Record terminal outcomes, not transient emptiness during a reset or
    /// failure. The context owns the profile even if a late load finishes
    /// after that profile has left the screen.
    func recordTopShelfRows(for source: SectionFeedSource) {
        #if os(tvOS)
            var rows: [TopShelfSource: TopShelfRowContent] = [:]
            for (ref, collection) in collections where SectionFeedSource(row: ref) == source {
                rows[TopShelfSource(surface: surface, ref: ref)] = loads.failedRows.contains(ref)
                    ? .unavailable : .loaded(collection.preview.map(\.id))
            }
            if !rows.isEmpty { TopShelfSettings.record(rows, profile: context?.profileID) }
        #endif
    }
}
