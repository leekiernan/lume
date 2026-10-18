import Foundation
import OSLog
import SwiftData

/// Retire legacy URL credentials once, without rebuilding the catalogue or
/// touching viewing state. Failed/interrupted passes are retried next launch.
nonisolated enum ProviderArtworkMaintenance {
    private static let checkpoint = "lume.providerArtwork.tokenFree.v1"

    /// Detached from the launch sequence by its caller: on an upgraded device
    /// with a large library it can take a while, and nothing at launch needs
    /// it finished. Sync writes token-free routes itself meanwhile.
    @concurrent
    static func run(container: ModelContainer, defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: checkpoint) else { return }
        do {
            let context = ModelContext(container)
            let playlists = try context.fetch(FetchDescriptor<Playlist>())
            for playlist in playlists {
                let infix: String
                switch playlist.knownSourceType {
                case .plex?: infix = "plex"
                case .jellyfin?: infix = "jellyfin"
                case .emby?: infix = "emby"
                default: continue
                }
                try Task.checkCancellation()
                try scrub(prefix: CatalogID.prefix(playlist.id, infix: infix), container: container)
            }
            defaults.set(true, forKey: checkpoint)
        } catch {
            Logger.database.warning("Legacy artwork credential cleanup deferred: \(LogRedaction.describe(error), privacy: .public)")
        }
    }

    /// Keyset pages with a fresh context each (`CatalogMaintenance`): offset
    /// paging re-skipped every earlier row per page, and one long-lived
    /// context kept every row it had touched resident.
    static func scrub(prefix: String, container: ModelContainer) throws {
        try CatalogMaintenance.mutate(container: container, pageSize: pageSize, page: { cursor in
            FetchDescriptor<Movie>(predicate: #Predicate { $0.id > cursor && $0.id.starts(with: prefix) },
                                   sortBy: [SortDescriptor(\.id, comparator: .lexical)])
        }, mutate: { rows, _ in clean(rows, field: \.streamIcon) })
        try CatalogMaintenance.mutate(container: container, pageSize: pageSize, page: { cursor in
            FetchDescriptor<Series>(predicate: #Predicate { $0.id > cursor && $0.id.starts(with: prefix) },
                                    sortBy: [SortDescriptor(\.id, comparator: .lexical)])
        }, mutate: { rows, _ in clean(rows, field: \.cover) })
        try CatalogMaintenance.mutate(container: container, pageSize: pageSize, page: { cursor in
            FetchDescriptor<Episode>(predicate: #Predicate { $0.id > cursor && $0.id.starts(with: prefix) },
                                     sortBy: [SortDescriptor(\.id, comparator: .lexical)])
        }, mutate: { rows, _ in clean(rows, field: \.movieImage) })
    }

    private static let pageSize = 250

    private static func clean<Row>(_ rows: [Row], field: ReferenceWritableKeyPath<Row, String?>) {
        for row in rows {
            guard let stored = row[keyPath: field], let url = URL(string: stored),
                  let clean = ProviderArtworkAccount.tokenFree(url)?.absoluteString, clean != stored else { continue }
            row[keyPath: field] = clean
        }
    }
}
