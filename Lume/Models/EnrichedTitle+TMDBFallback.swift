import Foundation

nonisolated struct TMDBReplacement<Value: Codable & Equatable>: Codable {
    let previous: Value?
    let applied: Value
}

/// Field types are fixed here: a runtime cannot accidentally record a score
/// or a display label. Scalars remain in their native storage units.
nonisolated struct TMDBFallbacks: Codable {
    var plot: TMDBReplacement<String>?
    var genre: TMDBReplacement<String>?
    var runtime: TMDBReplacement<Int>?
    var movieRating: TMDBReplacement<Double>?
    var seriesRating: TMDBReplacement<String>?
    var cast: TMDBReplacement<String>?
}

nonisolated extension EnrichedTitle {
    func recordTMDBFallback<Value>(_ field: WritableKeyPath<TMDBFallbacks, TMDBReplacement<Value>?>, previous: Value?, applied: Value) {
        guard previous != applied else { return }
        var changes = tmdbFallbackChanges
        // Retain the original provider value through repeated enrichment. A
        // provider edit since our last write becomes the new restore point.
        let retained = changes[keyPath: field]
        let original = retained?.applied == previous ? retained?.previous : previous
        changes[keyPath: field] = TMDBReplacement(previous: original, applied: applied)
        tmdbFallbackData = try? JSONEncoder().encode(changes)
    }

    /// Restore only fields which still hold the value we wrote. Later provider
    /// edits, watch state, downloads and episode caches are never touched.
    func restoreTMDBFallbacks() {
        let changes = tmdbFallbackChanges
        if let change = changes.plot, plot == change.applied { plot = change.previous }
        if let change = changes.genre, genre == change.applied { genre = change.previous }
        if let movie = self as? Movie {
            if let change = changes.runtime, movie.durationSecs == change.applied { movie.durationSecs = change.previous }
            if let change = changes.movieRating, movie.rating == change.applied { movie.rating = change.previous ?? 0 }
        }
        if let series = self as? Series {
            if let change = changes.cast, series.cast == change.applied { series.cast = change.previous }
            if let change = changes.seriesRating, series.rating == change.applied { series.rating = change.previous }
        }
        tmdbFallbackData = nil
    }

    fileprivate var tmdbFallbackChanges: TMDBFallbacks {
        guard let tmdbFallbackData else { return TMDBFallbacks() }
        let decoder = JSONDecoder()
        let legacy = try? decoder.decode([String: LegacyTMDBReplacement].self, from: tmdbFallbackData)
        if let typed = try? decoder.decode(TMDBFallbacks.self, from: tmdbFallbackData), legacy?["rating"] == nil { return typed }
        var values = TMDBFallbacks()
        values.plot = legacy?["plot"].map { TMDBReplacement(previous: $0.previous, applied: $0.applied) }
        values.genre = legacy?["genre"].map { TMDBReplacement(previous: $0.previous, applied: $0.applied) }
        values.cast = legacy?["cast"].map { TMDBReplacement(previous: $0.previous, applied: $0.applied) }
        if let value = legacy?["runtime"], let applied = Int(value.applied) {
            values.runtime = TMDBReplacement(previous: value.previous.flatMap(Int.init), applied: applied)
        }
        if let value = legacy?["rating"] {
            if self is Movie, let applied = Double(value.applied), applied.isFinite {
                values.movieRating = TMDBReplacement(previous: value.previous.flatMap(Double.init), applied: applied)
            } else if self is Series {
                values.seriesRating = TMDBReplacement(previous: value.previous, applied: value.applied)
            }
        }
        return values
    }
}

nonisolated extension Movie {
    /// A title-level TMDB estimate is useful in the library, but cannot prove
    /// that two files have the same cut. Provider edits supersede the recorded
    /// fallback; an equal value stays conservative until provenance changes.
    var streamRuntime: MediaRuntime? {
        guard let runtime, tmdbFallbackChanges.runtime?.applied != runtime.seconds else { return nil }
        return runtime
    }
}

private nonisolated struct LegacyTMDBReplacement: Decodable {
    let previous: String?
    let applied: String
}
