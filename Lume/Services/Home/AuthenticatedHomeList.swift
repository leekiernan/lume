import Foundation

/// Connected-account sources offered alongside the URL-based section editor.
/// Store their canonical API address in the existing custom-section format so
/// layout, caching, hero and collection behaviour remain shared.
nonisolated enum AuthenticatedHomeList: String, CaseIterable, Identifiable {
    case traktRecommendations

    var id: String {
        rawValue
    }

    var defaultTitle: String {
        switch self {
        case .traktRecommendations: String(localized: "Trakt Recommendations")
        }
    }

    func sourceURL(for surface: SectionSurface) -> String {
        "https://api.trakt.tv\(TraktRecommendationScope(surface: surface).apiPath)"
    }

    static func matching(_ sourceURL: String) -> Self? {
        guard let url = URL(string: sourceURL), TraktRecommendationScope(url: url) != nil else { return nil }
        return .traktRecommendations
    }

    func section(title: String, surface: SectionSurface) -> CustomHomeSection {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return CustomHomeSection(title: trimmed.isEmpty ? defaultTitle : trimmed, sourceURL: sourceURL(for: surface))
    }

    /// An opaque account identity for derived surfaces such as Top Shelf.
    func accountScope(_ account: String?) -> String? {
        account.map { HomeListCacheKey(source: sourceURL(for: .home), account: $0).digest.rawValue }
    }
}

enum AuthenticatedHomeLists {
    nonisolated static func baseTitlesKey(_ surface: SectionSurface) -> String {
        "\(surface.storagePrefix).authenticatedListTitles.v1"
    }

    static func titlesKey(_ surface: SectionSurface) -> String {
        ProfileScopedPreferences.key(baseTitlesKey(surface))
    }

    static func title(for source: AuthenticatedHomeList, raw: String) -> String {
        titles(raw)[source.rawValue] ?? source.defaultTitle
    }

    static func settingTitle(_ title: String, for source: AuthenticatedHomeList, raw: String) -> String {
        var values = titles(raw)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        values[source.rawValue] = trimmed.isEmpty ? nil : trimmed
        guard let data = try? JSONEncoder().encode(values) else { return raw }
        return String(data: data, encoding: .utf8) ?? raw
    }

    private static func titles(_ raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

nonisolated enum TraktRecommendationScope: CaseIterable {
    case all, movies, shows

    init(surface: SectionSurface) {
        switch surface {
        case .home: self = .all
        case .movies: self = .movies
        case .series: self = .shows
        }
    }

    init?(url: URL) {
        guard url.scheme == "https", url.host?.lowercased() == "api.trakt.tv",
              url.query == nil, url.fragment == nil,
              let scope = Self.allCases.first(where: { $0.apiPath == url.path })
        else { return nil }
        self = scope
    }

    var apiPath: String {
        switch self {
        case .all: "/media/recommendations"
        case .movies: "/movies/recommendations"
        case .shows: "/shows/recommendations"
        }
    }
}
