import Foundation

nonisolated struct TitleGenre: Codable, Hashable {
    /// Nil for provider/legacy name-only data; known TMDB IDs survive language
    /// changes without making the localized label the identity.
    let id: TMDBGenreID?
    let name: String

    init?(id: TMDBGenreID? = nil, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        self.id = id
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case id, name }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decodeIfPresent(TMDBGenreID.self, forKey: .id)
        let name = try values.decode(String.self, forKey: .name)
        guard let genre = Self(id: id, name: name) else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: values, debugDescription: "Missing genre name")
        }
        self = genre
    }
}

nonisolated struct CountryCode: Codable, Hashable {
    let rawValue: String

    init?(_ rawValue: String?) {
        guard let rawValue else { return nil }
        let normalized = rawValue.uppercased()
        guard normalized.utf8.count == 2, normalized.utf8.allSatisfy({ (65 ... 90).contains($0) }) else { return nil }
        self.rawValue = normalized
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        guard let code = try Self(value.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid country code")
        }
        self = code
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
}

nonisolated struct TitleCertification: Codable, Equatable {
    /// Nil only for provider/legacy labels whose country was never known.
    let country: CountryCode?
    let label: String

    init?(country: CountryCode? = nil, label: String?) {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        self.country = country
        self.label = label
    }

    private enum CodingKeys: String, CodingKey { case country, label }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let country = try values.decodeIfPresent(CountryCode.self, forKey: .country)
        let label = try values.decode(String.self, forKey: .label)
        guard let certification = Self(country: country, label: label) else {
            throw DecodingError.dataCorruptedError(forKey: .label, in: values, debugDescription: "Missing certification label")
        }
        self = certification
    }
}

nonisolated extension EnrichedTitle {
    var genres: [TitleGenre] {
        get {
            if let genresData, let values = try? JSONDecoder().decode([TitleGenre].self, from: genresData),
               values.map(\.name).joined(separator: ", ") == genre { return values }
            return GenreParser.tokens(from: genre).compactMap { TitleGenre(name: $0) }
        }
        set {
            genresData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
            genre = newValue.isEmpty ? nil : newValue.map(\.name).joined(separator: ", ")
        }
    }

    var certification: TitleCertification? {
        get {
            if let certificationData, let value = try? JSONDecoder().decode(TitleCertification.self, from: certificationData),
               value.label == contentRating { return value }
            return TitleCertification(label: contentRating)
        }
        set {
            certificationData = newValue.flatMap { try? JSONEncoder().encode($0) }
            contentRating = newValue?.label
        }
    }
}
