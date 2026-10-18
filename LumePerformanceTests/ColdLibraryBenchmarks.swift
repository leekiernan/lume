import Foundation
@testable import Lume
import SwiftData
import XCTest

/// Cold model contexts over an enriched SQLite catalogue, not an in-memory
/// store or a network benchmark. Reopening the container also clears Core Data's
/// row cache; the OS filesystem cache is not flushed. These are attribution
/// probes, not a claim about Apple TV flash or end-to-end SwiftUI frame time.
final class ColdLibraryBenchmarks: XCTestCase {
    private var store: (container: ModelContainer, directory: URL)!
    private let prefix = UUID().uuidString + "-"
    private let movieCount = 40000
    private let railCount = 9 // One hero source and eight 20-title rails.
    private let rowSize = 20

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try PerfStore.makeOnDiskContainer()
        try seed()
    }

    override func tearDownWithError() throws {
        if let store { PerfStore.destroy(directory: store.directory) }
        store = nil
        try super.tearDownWithError()
    }

    private var titleIDs: [Int] {
        (0 ..< railCount * rowSize).map { $0 * 211 + 1 }
    }

    /// The real list-to-catalogue path, including reading the fields the rails
    /// and hero render. The heartbeat records the longest main-actor gap while
    /// background matching and foreground materialisation run.
    @MainActor
    func testColdRemotePreviews() async throws {
        var durations: [Double] = []
        var longestGaps: [Double] = []
        for _ in 0 ..< 5 {
            let container = try reopen()
            let scope = SectionFeed.Context(modelContext: container.mainContext, restriction: ContentRestriction(), playlistPrefix: prefix)
            var longestGap = Duration.zero
            let pulse = Task { @MainActor in
                var previous = ContinuousClock.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                    let now = ContinuousClock.now
                    longestGap = max(longestGap, previous.duration(to: now))
                    previous = now
                }
            }
            let started = ContinuousClock.now
            var shown = 0
            for start in stride(from: 0, to: titleIDs.count, by: rowSize) {
                let entries = titleIDs[start ..< start + rowSize].map { HomeListEntry(tmdbId: $0, mediaType: .movie, title: "Remote") }
                let snapshot = await SectionCollectionResolver.snapshot(entries: entries, mediaType: .movie, context: scope, previewLimit: rowSize)
                XCTAssertEqual(snapshot.preview.count, rowSize)
                for case let .movie(movie) in snapshot.preview {
                    XCTAssertGreaterThan(Self.displaySignature(movie), 0)
                    shown += 1
                }
            }
            durations.append(Self.seconds(started.duration(to: .now)))
            // Let the heartbeat observe the final synchronous publication too.
            try await Task.sleep(for: .milliseconds(10))
            pulse.cancel()
            await pulse.value
            longestGaps.append(Self.seconds(longestGap))
            XCTAssertEqual(shown, railCount * rowSize)
        }
        record("remote-preview-seconds", durations)
        record("main-actor-gap-seconds", longestGaps)
    }

    @MainActor
    func testIndividualModelFaults() throws {
        try measureHydration { context, _, identifiers in
            identifiers.compactMap { context.model(for: $0) as? Movie }
        }
    }

    @MainActor
    func testBatchedModelHydration() throws {
        try measureHydration { context, ids, _ in
            try context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) }))
        }
    }

    @MainActor
    func testProjectedModelHydration() throws {
        try measureHydration { context, ids, _ in
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) })
            descriptor.propertiesToFetch = [\.id, \.name, \.streamIcon, \.posterPath, \.backdropPath, \.logoPath,
                                            \.plot, \.genre, \.releaseDate, \.durationSecs]
            return try context.fetch(descriptor)
        }
    }

    @MainActor
    func testColdLocalRailsWithHiddenCategories() {
        measureLocalRails()
    }

    @MainActor
    func testColdLocalRailsWithTiedTimestamps() throws {
        // Providers often bulk-publish thousands of titles at one timestamp.
        // A LIMIT alone does not bound the work of sorting that tied group.
        for start in stride(from: 0, to: movieCount, by: 500) {
            let context = ModelContext(store.container)
            context.autosaveEnabled = false
            let ids = Set((start ..< min(start + 500, movieCount)).map { prefix + "movie-\($0 + 1)" })
            for movie in try context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) })) {
                movie.added = "1700000000"
            }
            try context.save()
        }
        measureLocalRails()
    }

    @MainActor
    private func measureLocalRails() {
        // Leave one of 100 categories visible, rather than the easy dense case.
        let hidden = Set((1 ..< 100).map { prefix + "category-\($0)" })
        let kinds: [LibraryCollection.Kind] = [.recentlyAdded, .favorites, .continueWatching, .recentlyWatched]
        let descriptors = kinds.map {
            MovieCollectionQuery.rowDescriptor(for: $0, playlistPrefix: prefix, excludedCategoryIDs: hidden)
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric()], options: options) {
            do {
                let container = try reopen()
                let context = container.mainContext
                startMeasuring()
                for descriptor in descriptors {
                    let movies = try context.fetch(descriptor)
                    for movie in movies {
                        XCTAssertGreaterThan(Self.displaySignature(movie), 0)
                    }
                    XCTAssertFalse(movies.isEmpty)
                    XCTAssertLessThanOrEqual(movies.count, collectionRowFetchLimit)
                    XCTAssertTrue(movies.allSatisfy { $0.categoryId == prefix + "category-0" })
                }
                stopMeasuring()
            } catch {
                XCTFail("Cold local rails failed: \(error)")
            }
        }
    }

    @MainActor
    private func measureHydration(_ fetch: (ModelContext, Set<String>, [PersistentIdentifier]) throws -> [Movie]) throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric()], options: options) {
            do {
                let container = try reopen()
                let context = ModelContext(container)
                let windows = try stride(from: 0, to: titleIDs.count, by: rowSize).map { start in
                    let ids = Set(titleIDs[start ..< start + rowSize].map { prefix + "movie-\($0)" })
                    let descriptor = FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) })
                    // IDs only: don't prewarm the very attributes being timed.
                    return try (ids, context.fetchIdentifiers(descriptor))
                }
                startMeasuring()
                var count = 0
                for (ids, identifiers) in windows {
                    let movies = try fetch(context, ids, identifiers)
                    count += movies.count
                    for movie in movies {
                        XCTAssertGreaterThan(Self.displaySignature(movie), 0)
                    }
                }
                stopMeasuring()
                XCTAssertEqual(count, railCount * rowSize)
            } catch {
                XCTFail("Cold hydration failed: \(error)")
            }
        }
    }

    private func reopen() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: PerfStore.catalogSchema,
                                               url: store.directory.appendingPathComponent("perf.store"), cloudKitDatabase: .none)
        return try ModelContainer(for: PerfStore.catalogSchema, configurations: configuration)
    }

    private static func displaySignature(_ movie: Movie) -> Int {
        movie.id.count + movie.name.count + (movie.streamIcon?.count ?? 0) + (movie.posterPath?.count ?? 0)
            + (movie.backdropPath?.count ?? 0) + (movie.logoPath?.count ?? 0) + (movie.plot?.count ?? 0)
            + (movie.genre?.count ?? 0) + (movie.releaseDate?.count ?? 0) + (movie.durationSecs ?? 0)
    }

    private func seed() throws {
        let payload = Data(repeating: 42, count: 2048)
        let plot = String(repeating: "Synthetic overview — ", count: 32)
        for start in stride(from: 0, to: movieCount, by: 500) {
            try autoreleasepool {
                let context = ModelContext(store.container)
                context.autosaveEnabled = false
                for index in start ..< min(start + 500, movieCount) {
                    let id = index + 1
                    let movie = Movie(id: prefix + "movie-\(id)", streamId: id, name: "Movie \(id)",
                                      streamIcon: "https://example.invalid/poster/\(id).jpg", added: String(1_700_000_000 + index),
                                      categoryId: prefix + "category-\(index % 100)")
                    movie.tmdbId = id
                    movie.posterPath = "/poster-\(id).jpg"
                    movie.backdropPath = "/backdrop-\(id).jpg"
                    movie.logoPath = "/logo-\(id).png"
                    movie.plot = plot
                    movie.genre = "Drama / Comedy"
                    movie.releaseDate = "2020-01-01"
                    movie.durationSecs = 6000
                    movie.embeddingData = payload
                    movie.isFavorite = index.isMultiple(of: 500)
                    if index.isMultiple(of: 200) {
                        movie.lastWatchedDate = Date(timeIntervalSince1970: Double(1_700_000_000 + index))
                        movie.isWatched = index.isMultiple(of: 400)
                        movie.watchProgress = movie.isWatched ? 6000 : 100
                    }
                    context.insert(movie)
                }
                try context.save()
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func record(_ name: String, _ values: [Double]) {
        print("COLD_LIBRARY \(name): \(values)")
        let attachment = XCTAttachment(string: "\(values)")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
