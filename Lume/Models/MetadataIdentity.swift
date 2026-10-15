import Foundation

nonisolated enum TMDBNamespace {
    enum Movie {}
    enum Series {}
    enum Person {}
    enum Collection {}
    enum Genre {}
}

/// The namespace is part of the Swift type, not a convention on an Int.
/// Raw integers remain the on-disk/query representation.
nonisolated struct TMDBID<Namespace>: Hashable, Codable, CustomStringConvertible {
    let rawValue: Int

    init?(_ rawValue: Int?) {
        guard let rawValue, rawValue > 0 else { return nil }
        self.rawValue = rawValue
    }

    var description: String {
        String(rawValue)
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        guard let id = try Self(value.decode(Int.self)) else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "TMDB IDs must be positive")
        }
        self = id
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
}

typealias TMDBMovieID = TMDBID<TMDBNamespace.Movie>
typealias TMDBSeriesID = TMDBID<TMDBNamespace.Series>
typealias TMDBPersonID = TMDBID<TMDBNamespace.Person>
typealias TMDBCollectionID = TMDBID<TMDBNamespace.Collection>
typealias TMDBGenreID = TMDBID<TMDBNamespace.Genre>

nonisolated enum TMDBTitleReference: Hashable, Codable {
    case movie(TMDBMovieID)
    case series(TMDBSeriesID)

    init?(kind: LumeMetadataKind, rawValue: Int?) {
        switch kind {
        case .movie:
            guard let id = TMDBMovieID(rawValue) else { return nil }
            self = .movie(id)
        case .series:
            guard let id = TMDBSeriesID(rawValue) else { return nil }
            self = .series(id)
        }
    }

    var kind: LumeMetadataKind {
        switch self {
        case .movie: .movie
        case .series: .series
        }
    }

    var rawValue: Int {
        switch self {
        case let .movie(id): id.rawValue
        case let .series(id): id.rawValue
        }
    }
}

nonisolated struct IMDbTitleID: Hashable, Codable, CustomStringConvertible {
    let rawValue: String

    init?(_ rawValue: String?) {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              value.hasPrefix("tt"), value.count > 2,
              value.dropFirst(2).utf8.allSatisfy({ (48 ... 57).contains($0) }) else { return nil }
        self.rawValue = value
    }

    var description: String {
        rawValue
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        guard let id = try Self(value.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid IMDb title ID")
        }
        self = id
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
}

nonisolated extension Movie {
    var tmdbIdentifier: TMDBMovieID? {
        TMDBMovieID(tmdbId)
    }
}

nonisolated extension Series {
    var tmdbIdentifier: TMDBSeriesID? {
        TMDBSeriesID(tmdbId)
    }
}

nonisolated extension EnrichedTitle {
    var imdbIdentifier: IMDbTitleID? {
        IMDbTitleID(imdbId)
    }

    var metadataIdentity: TMDBTitleReference? {
        if let movie = self as? Movie { return movie.tmdbIdentifier.map(TMDBTitleReference.movie) }
        if let series = self as? Series { return series.tmdbIdentifier.map(TMDBTitleReference.series) }
        return nil
    }
}
