import Foundation
import OSLog
import SwiftData

/// Retire legacy URL credentials once, without rebuilding the catalogue or
/// touching viewing state. Failed/interrupted passes are retried next launch.
nonisolated enum ProviderArtworkMaintenance {
    private static let checkpoint = "lume.providerArtwork.tokenFree.v1"

    @concurrent
    static func run(container: ModelContainer, defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: checkpoint) else { return }
        do {
            let context = ModelContext(container)
            context.autosaveEnabled = false
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
                try scrub(prefix: CatalogID.prefix(playlist.id, infix: infix), in: context)
            }
            defaults.set(true, forKey: checkpoint)
        } catch {
            Logger.database.warning("Legacy artwork credential cleanup deferred: \(LogRedaction.describe(error), privacy: .public)")
        }
    }

    static func scrub(prefix: String, in context: ModelContext) throws {
        try scrub(FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: prefix) }, sortBy: [SortDescriptor(\.id)]),
                  field: \.streamIcon, context: context)
        try scrub(FetchDescriptor<Series>(predicate: #Predicate { $0.id.starts(with: prefix) }, sortBy: [SortDescriptor(\.id)]),
                  field: \.cover, context: context)
        try scrub(FetchDescriptor<Episode>(predicate: #Predicate { $0.id.starts(with: prefix) }, sortBy: [SortDescriptor(\.id)]),
                  field: \.movieImage, context: context)
    }

    private static func scrub<Row: PersistentModel>(
        _ descriptor: FetchDescriptor<Row>, field: ReferenceWritableKeyPath<Row, String?>, context: ModelContext
    ) throws {
        var page = descriptor
        page.fetchLimit = 250
        while true {
            try Task.checkCancellation()
            let rows = try context.fetch(page)
            guard !rows.isEmpty else { return }
            for row in rows {
                guard let stored = row[keyPath: field], let url = URL(string: stored),
                      let clean = ProviderArtworkAccount.tokenFree(url)?.absoluteString, clean != stored else { continue }
                row[keyPath: field] = clean
            }
            if context.hasChanges { try context.save() }
            page.fetchOffset = (page.fetchOffset ?? 0) + rows.count
        }
    }
}
