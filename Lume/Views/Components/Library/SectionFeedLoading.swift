import SwiftUI

/// Page-level task ownership; loading order follows the same layout as rendering.
struct SectionFeedLoadConfiguration {
    let context: SectionFeed.Context
    let catalogKey: String
    let heroRef: HomeSectionRef?
    let heroSelection: String
    let customSections: [CustomHomeSection]
    let orderedRows: [HomeSectionRef]
    let traktAccount: String?
    let prepareCustomSections: () -> Void
}

/// What restarts a page's layout-ordered load: its catalogue, its custom
/// lists (and hero choice), or the rows it shows.
private struct FeedLoadID: Hashable {
    let catalog: String
    let customTask: String
    let rows: [HomeSectionRef]
}

/// What restarts one watchlist's load: its account (in the cache key) or the
/// rows the page shows.
private struct WatchlistLoadID: Hashable {
    let cacheKey: String
    let rows: [HomeSectionRef]
}

private struct SectionFeedLoading: ViewModifier {
    let feed: SectionFeed
    let configuration: SectionFeedLoadConfiguration

    func body(content: Content) -> some View {
        let plan = SectionFeedLoadPlan(rows: configuration.orderedRows, hero: configuration.heroRef, customSections: configuration.customSections)
        let keys = SectionFeedLoadKeys(surface: feed.surface, catalog: configuration.catalogKey, sections: plan.customSections,
                                       heroSelection: configuration.heroSelection, traktAccount: configuration.traktAccount,
                                       proxySourceIdentity: configuration.context.proxySourceIdentity)
        let traktKey = keys.watchlist(.trakt, account: WatchlistProvider.trakt.account)
        let simklKey = keys.watchlist(.simkl, account: WatchlistProvider.simkl.account)
        content
            .task(id: FeedLoadID(catalog: keys.catalog, customTask: keys.customTask, rows: plan.rows)) {
                guard !Task.isCancelled else { return }
                configuration.prepareCustomSections()
                feed.heroRef = configuration.heroRef
                feed.configure(plan: plan, context: configuration.context)
                await feed.load(plan: plan, keys: keys)
            }
            // Keyed by account: Trakt connects a moment after launch, which
            // must reload its watchlist, not the page's whole cold load.
            .task(id: WatchlistLoadID(cacheKey: traktKey, rows: plan.rows)) {
                // Either task may run first; a watchlist can be the hero.
                feed.heroRef = configuration.heroRef
                await feed.loadWatchlistIfPlanned(.trakt, cacheKey: traktKey, plan: plan, context: configuration.context)
            }
            .task(id: WatchlistLoadID(cacheKey: simklKey, rows: plan.rows)) {
                // Either task may run first; a watchlist can be the hero.
                feed.heroRef = configuration.heroRef
                await feed.loadWatchlistIfPlanned(.simkl, cacheKey: simklKey, plan: plan, context: configuration.context)
            }
    }
}

extension View {
    /// Keep tasks outside lazy rows: reserving a cold hero can move those rows
    /// off-screen and cancel the very work needed to populate the hero.
    func sectionFeedLoads(feed: SectionFeed, configuration: SectionFeedLoadConfiguration) -> some View {
        modifier(SectionFeedLoading(feed: feed, configuration: configuration))
    }
}
