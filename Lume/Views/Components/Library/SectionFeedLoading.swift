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

private struct SectionFeedLoading: ViewModifier {
    let feed: SectionFeed
    let configuration: SectionFeedLoadConfiguration

    func body(content: Content) -> some View {
        let plan = SectionFeedLoadPlan(rows: configuration.orderedRows, hero: configuration.heroRef, customSections: configuration.customSections)
        let keys = SectionFeedLoadKeys(surface: feed.surface, catalog: configuration.catalogKey, sections: plan.customSections,
                                       heroSelection: configuration.heroSelection, traktAccount: configuration.traktAccount)
        let traktKey = keys.watchlist(.trakt, account: WatchlistProvider.trakt.account)
        let simklKey = keys.watchlist(.simkl, account: WatchlistProvider.simkl.account)
        let identity = [keys.catalog, keys.customTask, traktKey, simklKey, plan.identity].joined(separator: "|")
        content.task(id: identity) {
            guard !Task.isCancelled else { return }
            configuration.prepareCustomSections()
            feed.heroRef = configuration.heroRef
            feed.configure(plan: plan, context: configuration.context)
            await feed.load(plan: plan, keys: keys, traktKey: traktKey, simklKey: simklKey)
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
