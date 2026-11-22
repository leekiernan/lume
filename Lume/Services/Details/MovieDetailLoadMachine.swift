import Observation
import SwiftData

/// One per detail presentation. Models stay on the view's actor/context; layout,
/// focus, playback, and user mutations remain in the platform view.
@Observable
final class MovieDetailLoadMachine {
    struct Snapshot {
        var isLoadingTMDB: Bool
        var similar: [HomeMediaItem] = []
        var collectionMovies: [HomeMediaItem] = []
        var collectionOutcome: DetailLoadState.Outcome?
    }

    private(set) var contentID: String
    private var detail: DetailLoadState
    private var collection = DetailLoadState()
    private var restriction = ContentRestriction()
    private(set) var collectionID: Int?
    private(set) var similar: [HomeMediaItem] = []
    private(set) var collectionMovies: [HomeMediaItem] = []
    private var collectionPartIDs: [Int] = []
    @ObservationIgnored private let fetchCollection: (Int, ModelContainer) async throws -> [Int]

    var isLoadingTMDB: Bool {
        detail.isBlocking
    }

    init(movie: Movie, fetchCollection: @escaping (Int, ModelContainer) async throws -> [Int] = { id, container in
        try await ContentSyncManager(modelContainer: container).fetchTMDBCollectionMovieIDs(collectionId: id)
    }) {
        contentID = movie.id
        detail = Self.initialDetail(for: movie)
        self.fetchCollection = fetchCollection
    }

    /// Safe before the view's identity-keyed task prepares a replacement title.
    /// A changed collection also hides the old lane before its next load starts.
    func snapshot(for movie: Movie, restriction: ContentRestriction? = nil) -> Snapshot {
        guard contentID == movie.id else {
            return Snapshot(isLoadingTMDB: Self.initialDetail(for: movie).isBlocking)
        }
        let visible = restriction ?? self.restriction
        return Snapshot(
            isLoadingTMDB: isLoadingTMDB, similar: RelatedTitlesResolver.visible(similar, restriction: visible),
            collectionMovies: collectionID == movie.collectionId ? RelatedTitlesResolver.visible(collectionMovies, restriction: visible) : [],
            collectionOutcome: collectionID == movie.collectionId ? collection.outcome : nil
        )
    }

    func load(_ movie: Movie, restriction: ContentRestriction = ContentRestriction(), in context: ModelContext) async {
        self.restriction = restriction
        prepare(movie)
        let request = detail.begin()
        await enrichMovieDetailsIfNeeded(movie, context: context)
        guard !Task.isCancelled, detail.owns(request) else { return }
        await enrichMovieRatingsIfNeeded(movie, context: context)
        guard !Task.isCancelled, detail.owns(request) else { return }
        resolveSimilar(movie, in: context)
        detail.finish(request)
    }

    func resolveSimilar(_ movie: Movie, in context: ModelContext) {
        prepare(movie)
        similar = RelatedTitlesResolver.similar(to: movie, restriction: restriction, in: context)
    }

    /// Hidden or parental-restricted categories changed under an open detail
    /// page (a profile switch, a category hidden in Content Management):
    /// re-resolve the rail so a title that is no longer visible drops out.
    func restrict(_ restriction: ContentRestriction, movie: Movie, in context: ModelContext) {
        guard restriction != self.restriction else { return }
        self.restriction = restriction
        resolveSimilar(movie, in: context)
        collection.invalidate()
        collectionMovies = RelatedTitlesResolver.collectionParts(collectionPartIDs, of: movie, restriction: restriction, in: context)
    }

    func loadCollection(_ movie: Movie, restriction: ContentRestriction = ContentRestriction(), in context: ModelContext) async {
        prepare(movie)
        restrict(restriction, movie: movie, in: context)
        let request = collection.begin()
        if collectionID != movie.collectionId {
            collectionMovies = []
            collectionPartIDs = []
        }
        collectionID = movie.collectionId
        guard let id = movie.collectionId else {
            collectionMovies = []
            collection.finish(request)
            return
        }
        do {
            let ids = try await fetchCollection(id, context.container)
            guard collection.owns(request), movie.collectionId == id else { return }
            guard !Task.isCancelled else { collection.abandon(request); return }
            collectionPartIDs = ids
            collectionMovies = RelatedTitlesResolver.collectionParts(ids, of: movie, restriction: restriction, in: context)
            collection.finish(request)
        } catch {
            guard collection.owns(request), movie.collectionId == id else { return }
            if Task.isCancelled || error is CancellationError {
                collection.abandon(request)
            } else {
                collection.finish(request, outcome: .failed)
            }
        }
    }

    func invalidate() {
        detail.invalidate()
        collection.invalidate()
    }

    private func prepare(_ movie: Movie) {
        guard contentID != movie.id else { return }
        invalidate()
        contentID = movie.id
        similar = []
        collectionMovies = []
        collectionID = nil
        collectionPartIDs = []
        detail = Self.initialDetail(for: movie)
    }

    private static func initialDetail(for movie: Movie) -> DetailLoadState {
        DetailLoadState(isBlocking: detailNeedsTMDBFetch(tmdbId: movie.tmdbId, enrichedAt: movie.tmdbEnrichedAt))
    }
}
