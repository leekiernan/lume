import Foundation
import Observation
import SwiftData

/// Public event artwork only, shared by every sports surface. No model writes,
/// score state, account URLs or new provider identities enter the catalogue.
@MainActor @Observable
final class SportsArtworkEnrichment {
    static let shared = SportsArtworkEnrichment()

    private var entries: [String: LumeSportsArtworkPublication] = [:]

    func images(for fixture: SportsFixture, now: Date = Date()) -> LumeSportsArtwork.Images? {
        guard let entry = entries[fixture.id], now < entry.expiresAt,
              entry.value.status == "matched", entry.value.fixture.matches(fixture, competition: fixture.artworkCompetition) else { return nil }
        return entry.value.artwork
    }

    func publish(_ values: [String: LumeSportsArtworkPublication], now: Date = Date()) {
        guard !Task.isCancelled else { return }
        var next = entries.filter { now < $0.value.expiresAt }
        for (id, value) in values where now < value.expiresAt {
            next[id] = value
        }
        if next.count > 256 {
            let oldest = next.sorted { $0.value.expiresAt < $1.value.expiresAt }.prefix(next.count - 256)
            for (id, _) in oldest {
                next.removeValue(forKey: id)
            }
        }
        if entries != next { entries = next }
    }

    /// Fetch alongside channel resolution, with its own cancellation lifetime.
    /// The context lives exclusively on this background executor, never in body.
    @concurrent static func refresh(container: ModelContainer, fixtures: [SportsFixture]) async {
        var remaining = fixtures.filter { $0.artworkCompetition != nil }
        guard !remaining.isEmpty else { return }
        let sources = LumeProxySource.snapshots(in: container)
        // Only public artwork is shared between playlist accounts. Use the
        // first supporting source per event, in stable playlist order.
        var answers: [(LumeProxySource, [String: LumeSportsArtworkPublication])] = []
        for source in sources.sorted(by: { $0.playlistID.uuidString < $1.playlistID.uuidString }).prefix(4) {
            guard !Task.isCancelled, !remaining.isEmpty else { break }
            let fetched = await (try? LumeSportsArtworkClient.shared.artwork(source: source, fixtures: remaining)) ?? [:]
            answers.append((source, fetched))
            remaining.removeAll { fetched[$0.id] != nil }
        }
        guard !Task.isCancelled else { return }
        // Recheck every retained source after the last network await: an earlier
        // account may have changed while a later source was still answering.
        let current = Set(LumeProxySource.snapshots(in: container))
        let values = merged(answers, currentSources: current)
        await shared.publish(values)
    }

    nonisolated static func merged(
        _ answers: [(LumeProxySource, [String: LumeSportsArtworkPublication])], currentSources: Set<LumeProxySource>
    ) -> [String: LumeSportsArtworkPublication] {
        var values: [String: LumeSportsArtworkPublication] = [:]
        for (source, fetched) in answers where currentSources.contains(source) {
            values.merge(fetched) { old, _ in old }
        }
        return values
    }
}
