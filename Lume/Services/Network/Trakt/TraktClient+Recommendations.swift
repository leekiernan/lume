import Foundation

nonisolated extension TraktClient {
    /// The web app's mixed and filtered feeds, in server order. Recommendations
    /// are a bounded daily set, not a paginated user list. A single request
    /// retains candidates for Show All while the rail resolves only 20 matches.
    func recommendations(scope: TraktRecommendationScope, accessToken: String) async throws -> HomeListPage {
        let response: (items: [TraktRecommendationItem], pageCount: Int) = try await collectionPage(
            scope.apiPath, number: 1, limit: 100, accessToken: accessToken,
            query: [URLQueryItem(name: "ignore_watched", value: "true"),
                    URLQueryItem(name: "ignore_collected", value: "true")]
        )
        return HomeListPage(entries: response.items.compactMap(\.entry), nextPage: nil)
    }
}

/// Keep only catalogue identities. Scores, reasons, plots and images aren't
/// needed to display titles already held in the local catalogue.
private nonisolated struct TraktRecommendationItem: Decodable {
    let movie: Media?
    let show: Media?

    struct Media: Decodable {
        let title: String?
        let ids: IDs
    }

    struct IDs: Decodable {
        let tmdb: Int?
    }

    var entry: HomeListEntry? {
        let media = movie ?? show
        guard let media, let id = media.ids.tmdb, id > 0 else { return nil }
        return HomeListEntry(tmdbId: id, mediaType: movie == nil ? .series : .movie, title: media.title ?? "")
    }
}
