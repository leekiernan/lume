import Foundation
@testable import Lume
import SwiftData
import Testing

/// A crash or kill mid-playback used to lose every position since the last
/// boundary: the buffer that a launch recovers from had been switched off.
@MainActor
@Suite(.trackerIdentity(.trakt), .trackerIdentity(.simkl))
struct PlaybackRecoveryTests {
    private let profile = UUID()
    private let other = UUID()

    private func defaults() -> UserDefaults {
        let suite = "PlaybackRecoveryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Buffer

    @Test func `the buffer keeps each profile's positions apart`() {
        let defaults = defaults()
        let sampled = Date(timeIntervalSince1970: 1_800_000_000)
        WatchProgressBuffer.record(ref: .movie("p-movie:1"), progress: 600, duration: 6000, profileID: profile,
                                   recordedAt: sampled, waitUntilWritten: true, defaults: defaults)
        WatchProgressBuffer.record(ref: .episode("p-ep-2"), progress: 300, duration: 1200, profileID: other,
                                   waitUntilWritten: true, defaults: defaults)
        WatchProgressBuffer.record(ref: .live("p-live-3"), progress: 50, duration: 0, profileID: profile,
                                   waitUntilWritten: true, defaults: defaults)

        let drained = WatchProgressBuffer.drain(profileID: profile, defaults: defaults)
        #expect(drained == [WatchProgressBuffer.Entry(profile: profile.uuidString, kind: .movie, id: "p-movie:1",
                                                      progress: 600, duration: 6000, recordedAt: sampled)])
        #expect(WatchProgressBuffer.drain(profileID: profile, defaults: defaults).isEmpty)
        #expect(WatchProgressBuffer.drain(profileID: other, defaults: defaults).map(\.id) == ["p-ep-2"])
    }

    @Test func `a saved position leaves nothing to recover`() {
        let defaults = defaults()
        WatchProgressBuffer.record(ref: .movie("m"), progress: 600, duration: 6000, profileID: profile,
                                   waitUntilWritten: true, defaults: defaults)
        WatchProgressBuffer.remove(ref: .movie("m"), profileID: profile, defaults: defaults)
        #expect(WatchProgressBuffer.drain(profileID: profile, defaults: defaults).isEmpty)
    }

    // MARK: - Launch

    @Test func `a launch commits what a killed session buffered`() async throws {
        let defaults = defaults()
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let movie = Movie(id: "p-movie-1", streamId: 1, name: "A Film")
        movie.durationSecs = 6000
        context.insert(movie)
        try context.save()
        let scope = ProfileScope.current
        WatchProgressBuffer.record(ref: .movie(movie.id), progress: 1800, duration: 6000, profileID: scope.profileID,
                                   waitUntilWritten: true, defaults: defaults)
        WatchProgressBuffer.record(ref: .movie(movie.id), progress: 900, duration: 6000, profileID: other,
                                   waitUntilWritten: true, defaults: defaults)

        let recovered = await WatchProgressWriter.reconcilePending(container: container, scope: scope, defaults: defaults)

        #expect(recovered.map(\.progress) == [1800])
        let saved = try #require(ModelContext(container).fetch(FetchDescriptor<Movie>()).first)
        #expect(saved.watchProgress == 1800)
        // Another profile's position waits for that profile.
        #expect(WatchProgressBuffer.drain(profileID: other, defaults: defaults).map(\.progress) == [900])
    }

    // MARK: - Trackers

    @Test func `recovered positions go to trackers as pauses, or as watched once finished`() throws {
        let context = try ModelContext(makeTestContainer())
        let partial = Movie(id: "m-1", streamId: 1, name: "Partial")
        partial.tmdbId = 1
        let finished = Movie(id: "m-2", streamId: 2, name: "Finished")
        finished.tmdbId = 2
        let barely = Movie(id: "m-3", streamId: 3, name: "Barely")
        barely.tmdbId = 3
        [partial, finished, barely].forEach(context.insert)
        let sampledAt = Date(timeIntervalSince1970: 1_800_000_000)
        let recovered = [
            WatchProgressWriter.Recovered(ref: .movie("m-1"), progress: 1500, duration: 6000, recordedAt: sampledAt, change: nil),
            WatchProgressWriter.Recovered(ref: .movie("m-2"), progress: 5800, duration: 6000, recordedAt: sampledAt,
                                          change: WatchProgressWriter.WatchedChange(ref: .movie("m-2"), isWatched: true)),
            WatchProgressWriter.Recovered(ref: .movie("m-3"), progress: 30, duration: 6000, recordedAt: sampledAt, change: nil)
        ]
        let tracker = RecoverySpy()

        PlaybackRecovery.report(recovered, to: [tracker], in: context)

        #expect(tracker.events == ["Partial paused 25.0 at \(sampledAt)", "Finished watched"])
    }

    // MARK: - Queue

    /// Queues written before positions were carried still decode.
    @Test func `an older queued change decodes without a position`() throws {
        let old = TrackerMutation(kind: .playback, target: .movie(tmdbID: 1), isPresent: false)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["progress"] = nil
        json["pausedAt"] = nil
        let decoded = try JSONDecoder().decode(TrackerMutation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.progress == nil && decoded.pausedAt == nil)

        let set = TrackerMutation(kind: .playback, target: .movie(tmdbID: 1), isPresent: true, progress: 42, pausedAt: .now)
        #expect(try JSONDecoder().decode(TrackerMutation.self, from: JSONEncoder().encode(set)) == set)
    }

    private final class RecoverySpy: TrackerHistorySynchronizing {
        var events: [String] = []
        func syncWatched(movie: Movie, watched: Bool) {
            events.append("\(movie.name) watched")
            _ = watched
        }

        func syncWatched(episode _: Episode, watched _: Bool) {}
        func clearPausedProgress(movie _: Movie) {}
        func clearPausedProgress(episode _: Episode) {}
        func recordPausedProgress(movie: Movie, progress: Double, pausedAt: Date) {
            events.append("\(movie.name) paused \(progress) at \(pausedAt)")
        }

        func recordPausedProgress(episode _: Episode, progress _: Double, pausedAt _: Date) {}
        func retryPendingMutations() {}
    }
}
