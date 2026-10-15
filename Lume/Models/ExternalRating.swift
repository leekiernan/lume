//
//  ExternalRating.swift
//  Lume
//
//  A critic/audience score for a title from an external aggregator (IMDb,
//  Rotten Tomatoes, Metacritic, Trakt, Letterboxd, TMDB), sourced from the
//  MDBList API's `ratings` array. Stored on the SwiftData models as a Codable
//  value (in a `Data` blob, like `TitleVideo`) so the detail screens can
//  render a ratings row without a refetch.
//

import Foundation
import SwiftUI

/// A single external rating with the metadata the detail screens need to render
/// it (display name, brand tint, formatted value).
///
/// `nonisolated` because it is decoded and mapped inside the `nonisolated`
/// ``MDBListClient`` — under this project's default-MainActor isolation a plain
/// type would otherwise pick up a main-actor-isolated `Equatable`/`Hashable`
/// conformance that can't be used off the main actor.
nonisolated struct ExternalRating: Codable, Hashable, Identifiable {
    /// The aggregators we recognise. MDBList reports more (e.g. Roger Ebert,
    /// MyAnimeList), but these are the ones worth surfacing. Raw values are
    /// persisted inside `externalRatingsData` blobs — never change them.
    nonisolated enum Source: String, Codable, CaseIterable {
        case imdb
        case rottenTomatoes
        case rtAudience
        case metacritic
        case trakt
        case letterboxd
        case tmdb

        /// Maps MDBList's `source` identifier to a known source, or nil for
        /// ones we don't display (e.g. `metacriticuser`, `rogerebert`,
        /// `myanimelist`).
        init?(mdbListSource: String) {
            switch mdbListSource {
            case "imdb": self = .imdb
            case "tomatoes": self = .rottenTomatoes
            case "popcorn": self = .rtAudience
            case "metacritic": self = .metacritic
            case "trakt": self = .trakt
            case "letterboxd": self = .letterboxd
            case "tmdb": self = .tmdb
            default: return nil
            }
        }
    }

    let source: Source
    let score: RatingScore

    init?(source: Source, value: Double?) {
        guard let score = RatingScore(value, scale: source.scoreScale) else { return nil }
        self.source = source
        self.score = score
    }

    /// Formatting is derived, never used as the stored numeric representation.
    var value: String {
        switch source {
        case .imdb: String(format: "%.1f/10", score.value)
        case .metacritic: "\(Int(score.value))/100"
        case .letterboxd: String(format: "%.1f/5", score.value)
        case .rottenTomatoes, .rtAudience, .trakt, .tmdb: "\(Int(score.value))%"
        }
    }

    private enum CodingKeys: String, CodingKey { case source, score, value }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let source = try values.decode(Source.self, forKey: .source)
        if values.contains(.score) {
            let score = try values.decode(RatingScore.self, forKey: .score)
            guard score.scale == source.scoreScale, let rating = Self(source: source, value: score.value) else {
                throw DecodingError.dataCorruptedError(forKey: .score, in: values, debugDescription: "Rating scale does not match source")
            }
            self = rating
        } else {
            // Map the former formatted representation once when reading a
            // cached blob; every subsequent write stores the numeric score.
            let legacy = try values.decode(String.self, forKey: .value)
            let number = legacy.split(separator: "/").first.map(String.init)?.replacingOccurrences(of: "%", with: "")
            guard let rating = Self(source: source, value: number.flatMap(Double.init)) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: values, debugDescription: "Invalid stored rating")
            }
            self = rating
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(source, forKey: .source)
        try values.encode(score, forKey: .score)
    }

    var id: String {
        source.rawValue
    }
}

nonisolated extension ExternalRating.Source {
    var scoreScale: RatingScore.Scale {
        switch self {
        case .imdb: .ten
        case .letterboxd: .five
        case .rottenTomatoes, .rtAudience, .metacritic, .trakt, .tmdb: .percentage
        }
    }

    /// Short label shown beneath the value.
    var displayName: String {
        switch self {
        case .imdb: "IMDb"
        case .rottenTomatoes: "Rotten Tomatoes"
        case .rtAudience: "RT Audience"
        case .metacritic: "Metacritic"
        case .trakt: "Trakt"
        case .letterboxd: "Letterboxd"
        case .tmdb: "TMDB"
        }
    }

    /// Row order for the ratings chips — the best-known aggregators lead, so
    /// truncated layouts (the tvOS 10-foot row) keep the most recognisable ones.
    var displayPriority: Int {
        switch self {
        case .imdb: 0
        case .rottenTomatoes: 1
        case .rtAudience: 2
        case .metacritic: 3
        case .trakt: 4
        case .letterboxd: 5
        case .tmdb: 6
        }
    }
}

nonisolated extension ExternalRating {
    /// A compact value for the chip, dropping the denominator
    /// (e.g. `7.6/10` → `7.6`, `67/100` → `67`). Percentages keep their sign.
    var compactValue: String {
        switch source {
        case .imdb, .letterboxd: String(format: "%.1f", score.value)
        case .metacritic: String(Int(score.value))
        case .rottenTomatoes, .rtAudience, .trakt, .tmdb: value
        }
    }

    /// Brand-ish tint for the chip. Rotten Tomatoes (critic + audience) and
    /// Metacritic are colour-coded by score (fresh/rotten · good/mixed/bad);
    /// the others use their brand colour.
    var tint: Color {
        switch source {
        case .imdb:
            Color(red: 0.96, green: 0.77, blue: 0.13) // IMDb gold
        case .rottenTomatoes:
            // "Fresh" at 60%+.
            if score.percentage >= 60 {
                Color(red: 0.98, green: 0.36, blue: 0.22)
            } else {
                Color(red: 0.45, green: 0.62, blue: 0.86)
            }
        case .rtAudience:
            // Upright popcorn at 60%+.
            if score.percentage >= 60 {
                Color(red: 0.98, green: 0.83, blue: 0.16)
            } else {
                Color(red: 0.45, green: 0.62, blue: 0.86)
            }
        case .metacritic:
            switch score.percentage {
            case 61...: Color(red: 0.40, green: 0.73, blue: 0.30) // green
            case 40 ..< 61: Color(red: 0.98, green: 0.79, blue: 0.20) // yellow
            default: Color(red: 0.90, green: 0.30, blue: 0.27) // red
            }
        case .trakt:
            Color(red: 0.93, green: 0.11, blue: 0.14) // Trakt red
        case .letterboxd:
            Color(red: 0.00, green: 0.88, blue: 0.33) // Letterboxd green
        case .tmdb:
            Color(red: 0.01, green: 0.71, blue: 0.89) // TMDB blue
        }
    }
}
