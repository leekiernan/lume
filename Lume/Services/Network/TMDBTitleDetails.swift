import Foundation

nonisolated struct TMDBCollection: Equatable {
    let id: TMDBCollectionID
    let name: String?
    let poster: TMDBImagePath?
    let backdrop: TMDBImagePath?
}

/// The wire response is normalized once. These immutable fields cannot carry
/// invalid scores, runtime units, image paths, or unqualified title IDs.
nonisolated struct TMDBTitleDetails {
    let identity: TMDBTitleReference
    let artwork: TitleArtwork
    let tagline: String?
    let overview: String?
    /// `release_date` for movies, `first_air_date` for series ("2010-07-16").
    let releaseDate: String?
    let score: RatingScore?
    let runtime: MediaRuntime?
    let genres: [TitleGenre]
    let certification: TitleCertification?
    let cast: [TMDBCastMember]
    let similarTitles: [TMDBTitleReference]
    let videos: [TitleVideo]
    let imdbIdentifier: IMDbTitleID?
    /// A collection is one value, present only for movie identities.
    let collection: TMDBCollection?
    var proxyReceipt: LumeMetadataReceipt?
    var proxyRatings: LumeTitleRatings?

    init(
        identity: TMDBTitleReference, proxyReceipt: LumeMetadataReceipt? = nil,
        posterPath: String? = nil, backdropPath: String? = nil, tagline: String? = nil, overview: String? = nil,
        voteAverage: Double? = nil, releaseDate: String? = nil, runtimeMinutes: Int? = nil, genreNames: [String] = [], contentRating: String? = nil,
        cast: [TMDBCastMember] = [], similarIDs: [Int] = [], videos: [TitleVideo] = [], logoPath: String? = nil,
        imdbId: String? = nil, collectionId: Int? = nil, collectionName: String? = nil,
        collectionPosterPath: String? = nil, collectionBackdropPath: String? = nil,
        genres: [TitleGenre]? = nil, certification: TitleCertification? = nil
    ) {
        self.identity = identity
        self.proxyReceipt = proxyReceipt
        artwork = TitleArtwork(poster: TMDBImagePath(posterPath), backdrop: TMDBImagePath(backdropPath), logo: TMDBImagePath(logoPath))
        self.tagline = tagline?.isEmpty == false ? tagline : nil
        self.overview = overview?.isEmpty == false ? overview : nil
        self.releaseDate = releaseDate?.isEmpty == false ? releaseDate : nil
        score = RatingScore(voteAverage, scale: .ten)
        runtime = MediaRuntime(minutes: runtimeMinutes)
        self.genres = genres ?? genreNames.compactMap { TitleGenre(name: $0) }
        self.certification = certification ?? TitleCertification(label: contentRating)
        self.cast = cast
        similarTitles = similarIDs.compactMap { TMDBTitleReference(kind: identity.kind, rawValue: $0) }
        self.videos = videos
        imdbIdentifier = IMDbTitleID(imdbId)
        if case .movie = identity, let id = TMDBCollectionID(collectionId) {
            collection = TMDBCollection(id: id, name: collectionName, poster: TMDBImagePath(collectionPosterPath), backdrop: TMDBImagePath(collectionBackdropPath))
        } else {
            collection = nil
        }
    }

    /// Scalar projections for store adapters and rendering contracts. The source
    /// values above remain typed; these never parse provider data again.
    var posterPath: String? {
        artwork.poster?.rawValue
    }

    var backdropPath: String? {
        artwork.backdrop?.rawValue
    }

    var logoPath: String? {
        artwork.logo?.rawValue
    }

    var voteAverage: Double? {
        score?.value
    }

    var runtimeMinutes: Int? {
        runtime?.minutes
    }

    var genreNames: [String] {
        genres.map(\.name)
    }

    var contentRating: String? {
        certification?.label
    }

    var similarIDs: [Int] {
        similarTitles.map(\.rawValue)
    }

    var imdbId: String? {
        imdbIdentifier?.rawValue
    }

    var collectionId: Int? {
        collection?.id.rawValue
    }

    var collectionName: String? {
        collection?.name
    }

    var collectionPosterPath: String? {
        collection?.poster?.rawValue
    }

    var collectionBackdropPath: String? {
        collection?.backdrop?.rawValue
    }
}

nonisolated struct TMDBCastMember: Hashable {
    let personID: TMDBPersonID
    let name: String
    let character: String?
    let profile: TMDBImagePath?
    let order: Int

    init(personID: TMDBPersonID, name: String, character: String?, profilePath: String?, order: Int) {
        self.personID = personID
        self.name = name
        self.character = character
        profile = TMDBImagePath(profilePath)
        self.order = order
    }

    var tmdbPersonId: Int {
        personID.rawValue
    }

    var profilePath: String? {
        profile?.rawValue
    }
}
