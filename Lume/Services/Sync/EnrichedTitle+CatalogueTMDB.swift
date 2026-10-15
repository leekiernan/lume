import Foundation

nonisolated extension EnrichedTitle {
    /// Applies the TMDB ID a catalogue row carries (`raw`), given the value
    /// the previous catalogue import stored (`previous`).
    ///
    /// - A valid ID replaces the current one. When that changes an ID the
    ///   title was already enriched under, discard identity-owned metadata
    ///   and re-queue indexing, without erasing provider or user state.
    /// - A catalogue that stops sending the ID it supplied before withdraws it
    ///   (a corrected or withdrawn match, which an enriching proxy can do).
    /// - An ID the device resolved itself, where the catalogue never sent
    ///   one, is kept.
    func applyCatalogueTMDB(_ raw: String?, previous: String?) {
        if let supplied = Self.catalogueTMDB(raw) {
            guard let identity = TMDBTitleReference(kind: self is Movie ? .movie : .series, rawValue: supplied) else { return }
            assignTMDB(identity, origin: .catalogue)
            return
        }
        // Legacy movie IDs were catalogue-only. Legacy series IDs are ambiguous:
        // retain them until a fresh response establishes their source.
        let knownCatalogue = tmdbAssignment?.origin == .catalogue
        let legacyMovieCatalogue = self is Movie && tmdbAssignment == nil && Self.catalogueTMDB(previous) == tmdbId && tmdbId != nil
        guard knownCatalogue || legacyMovieCatalogue else { return }
        tmdbId = nil
        tmdbAssignmentData = nil
        forgetTMDBEnrichment()
    }

    /// A catalogue `tmdb` value as an ID: positive integers only, since
    /// panels send `""`, `"0"` or nothing for "none".
    static func catalogueTMDB(_ raw: String?) -> Int? {
        guard let raw, let id = Int(raw.trimmingCharacters(in: .whitespaces)), id > 0 else { return nil }
        return id
    }

    func forgetTMDBEnrichment() {
        restoreTMDBFallbacks()
        proxyMetadataData = nil
        tmdbEnrichedAt = nil
        tmdbArtworkEnrichedAt = nil
        ratingsEnrichedAt = nil
        backdropPath = nil
        posterPath = nil
        posterCheckedAt = nil
        logoPath = nil
        tagline = nil
        contentRating = nil
        certificationData = nil
        genresData = nil
        imdbId = nil
        similarTMDBIds = nil
        trailersData = nil
        externalRatingsData = nil
        indexedAt = nil
        embeddingData = nil
        // Background catalogue sync must not delete cast faults held by an
        // open detail screen. Hide them now; the detail-owned apply replaces
        // and deletes the old rows safely, including when the new cast is empty.
        tmdbCastInvalidated = true
        if let movie = self as? Movie {
            movie.collectionId = nil
            movie.collectionName = nil
            movie.collectionPosterPath = nil
            movie.collectionBackdropPath = nil
        }
    }
}
