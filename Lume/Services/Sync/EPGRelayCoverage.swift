import Foundation
import SwiftData

/// Which supplement feeds each enabled guide source's relay already applied
/// (`EPGSource.relaySupplements`). A feed is skipped per source, never
/// globally: a manual or ordinary provider guide still gets the device's
/// enrichment beside a relay's.
nonisolated struct EPGRelayCoverage {
    private var feedsBySource: [UUID: Set<EPGEnrichmentFeed.Identifier>] = [:]

    init() {}

    init(sources: [EPGSource]) {
        for source in sources where source.isEnabled {
            let names = Set(source.relaySupplements)
            feedsBySource[source.id] = Set(EPGEnrichmentFeed.Identifier.allCases.filter { names.contains($0.relayID) })
        }
    }

    static func load(in context: ModelContext) throws -> Self {
        try Self(sources: context.fetch(FetchDescriptor<EPGSource>(predicate: #Predicate { $0.isEnabled })))
    }

    func feeds(for sourceID: UUID?) -> Set<EPGEnrichmentFeed.Identifier> {
        sourceID.flatMap { feedsBySource[$0] } ?? []
    }

    /// With no enabled source there is nothing to cover; the device path keeps
    /// its existing behaviour.
    func coversEverySource(_ feed: EPGEnrichmentFeed.Identifier) -> Bool {
        !feedsBySource.isEmpty && feedsBySource.values.allSatisfy { $0.contains(feed) }
    }
}
