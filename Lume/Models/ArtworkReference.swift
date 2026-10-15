import Foundation

/// A TMDB raster filename is not an arbitrary URL or a path into a provider.
nonisolated struct TMDBImagePath: Hashable, Codable {
    let rawValue: String

    init?(_ rawValue: String?) {
        guard let path = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/"), !path.hasPrefix("//"), !path.dropFirst().contains("/"),
              !path.contains("?"), !path.contains("#"), !path.contains("\\"),
              ["jpg", "jpeg", "png", "webp"].contains((path as NSString).pathExtension.lowercased()) else { return nil }
        self.rawValue = path
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        guard let path = try Self(value.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid TMDB image path")
        }
        self = path
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
}

/// Only network images use this policy. Playback can legitimately use files
/// and portal placeholders and must not inherit an image-only allowlist.
nonisolated struct RemoteImageURL: Hashable {
    let url: URL

    init?(_ raw: String?) {
        guard let raw, let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    init?(url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        self.url = url
    }
}

nonisolated enum TMDBPosterSize: String, CaseIterable {
    case w92, w154, w185, w342, w500, w780, original
}

nonisolated enum TMDBBackdropSize: String, CaseIterable {
    case w300, w780, w1280, original
}

nonisolated enum TMDBProfileSize: String { case w45, w185, h632, original }
nonisolated enum TMDBLogoSize: String { case w45, w92, w154, w185, w300, w500, original }

nonisolated struct TitleArtwork: Equatable {
    var poster: TMDBImagePath?
    var backdrop: TMDBImagePath?
    var logo: TMDBImagePath?
}

nonisolated extension EnrichedTitle {
    var artwork: TitleArtwork {
        get { TitleArtwork(poster: TMDBImagePath(posterPath), backdrop: TMDBImagePath(backdropPath), logo: TMDBImagePath(logoPath)) }
        set {
            posterPath = newValue.poster?.rawValue
            backdropPath = newValue.backdrop?.rawValue
            logoPath = newValue.logo?.rawValue
        }
    }
}
