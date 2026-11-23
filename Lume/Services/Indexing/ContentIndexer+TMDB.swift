//
//  ContentIndexer+TMDB.swift
//  Lume
//
//  The indexer's TMDB lookups: title searches that retry without the
//  provider's (often wrong) year, and the split between permanent failures,
//  which skip an item, and transient ones, which end the run.
//

import Foundation

extension ContentIndexer {
    /// Provider year tags are often wrong, so a year-constrained search that
    /// finds nothing is retried without the year. When the year was a bare
    /// number in the name, the first retry puts it back into the title
    /// ("Blade Runner 2049"): retrying the shortened title first would match
    /// the wrong film. Extra requests are spent only on misses.
    func searchMovieID(query: String, year: Int?, titleKeepingYear: String? = nil) async throws -> Int? {
        try await search(query: query, year: year, titleKeepingYear: titleKeepingYear) {
            try await self.tmdbClient.searchMovieID(query: $0, year: $1)?.rawValue
        }
    }

    func searchTVID(query: String, year: Int?, titleKeepingYear: String? = nil) async throws -> Int? {
        try await search(query: query, year: year, titleKeepingYear: titleKeepingYear) {
            try await self.tmdbClient.searchTVID(query: $0, year: $1)?.rawValue
        }
    }

    struct SearchAttempt: Equatable {
        let title: String
        let year: Int?
    }

    /// The searches to try, in order, until one matches.
    nonisolated static func searchAttempts(query: String, year: Int?, titleKeepingYear: String?) -> [SearchAttempt] {
        guard year != nil else { return [SearchAttempt(title: query, year: nil)] }
        var attempts = [SearchAttempt(title: query, year: year)]
        if let titleKeepingYear { attempts.append(SearchAttempt(title: titleKeepingYear, year: nil)) }
        attempts.append(SearchAttempt(title: query, year: nil))
        return attempts
    }

    private func search(
        query: String, year: Int?, titleKeepingYear: String?,
        _ lookUp: (String, Int?) async throws -> Int?
    ) async throws -> Int? {
        for attempt in Self.searchAttempts(query: query, year: year, titleKeepingYear: titleKeepingYear) {
            if let id = try await lookUp(attempt.title, attempt.year) { return id }
        }
        return nil
    }

    /// Runs a TMDB request, converting *permanent* failures (no match, bad
    /// payload) into nil so the item proceeds without TMDB data. Transient
    /// failures (offline, 5xx, rate limit) rethrow and end the run — the next
    /// kick retries those items.
    func skippingPermanentFailures<T>(_ request: () async throws -> T?) async throws -> T? {
        do {
            return try await request()
        } catch let error as TMDBError {
            switch error {
            case let .serverError(code) where code == 404:
                return nil
            case .decodingError, .invalidURL, .missingToken:
                return nil
            case .serverError, .invalidResponse:
                throw error
            }
        }
    }
}
