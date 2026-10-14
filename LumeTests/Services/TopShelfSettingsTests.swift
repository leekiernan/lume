import Foundation
@testable import Lume
import Testing

/// Every test takes its own defaults domain and passes profiles explicitly,
/// so the suite touches no process-wide state.
struct TopShelfSettingsTests {
    /// A throwaway defaults domain per test, so nothing leaks into
    /// `UserDefaults.standard` or across tests.
    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "TopShelfSettingsTests-\(UUID().uuidString)"))
    }

    private let homeTrending = TopShelfSource(surface: .home, ref: .builtin(.trendingMovies))
    private let moviesFavorites = TopShelfSource(surface: .movies, ref: .builtin(.favorites))

    @Test func `nothing stored resolves to the default configuration`() throws {
        let defaults = try makeDefaults()
        #expect(TopShelfSettings.configuration(defaults: defaults) == .default)
        // No rows promoted: the Top Shelf is off.
        #expect(TopShelfSettings.sources(defaults: defaults).isEmpty)
    }

    @Test func `stored choices come back as the configuration`() throws {
        let defaults = try makeDefaults()
        defaults.set("carousel", forKey: TopShelfSettings.styleKey)
        defaults.set(20, forKey: TopShelfSettings.itemsPerSectionKey)
        let configuration = TopShelfSettings.configuration(defaults: defaults)
        #expect(configuration.style == .carousel)
        #expect(configuration.itemsPerSection == 20)
    }

    @Test func `unknown stored values fall back`() throws {
        let defaults = try makeDefaults()
        defaults.set("mosaic", forKey: TopShelfSettings.styleKey)
        defaults.set(7, forKey: TopShelfSettings.itemsPerSectionKey)
        let configuration = TopShelfSettings.configuration(defaults: defaults)
        #expect(configuration.style == .sectioned)
        #expect(configuration.itemsPerSection == TopShelfConfiguration.default.itemsPerSection)
    }

    @Test func `the snapshot carries enough items for the largest section`() {
        #expect(TopShelfConfiguration.maxItemsPerSection >= TopShelfConfiguration.itemCountChoices.max() ?? 0)
        #expect(TopShelfConfiguration.itemCountChoices.contains(TopShelfConfiguration.default.itemsPerSection))
    }

    /// A source names its surface and its row, custom rows included, and
    /// round-trips through storage.
    @Test func `promoted rows round-trip, unknown and repeated ones dropped`() {
        let custom = TopShelfSource(surface: .series, ref: .custom(UUID()))
        let raw = TopShelfSettings.encode([homeTrending, moviesFavorites, custom])
        #expect(TopShelfSettings.decode(raw) == [homeTrending, moviesFavorites, custom])
        #expect(TopShelfSettings.decode("\(raw),bogus,cinema/favorites,\(homeTrending.token)") == [homeTrending, moviesFavorites, custom])
    }

    /// Adding puts a row at the bottom; adding it again takes it off.
    @Test func `toggling adds at the bottom and removes`() {
        let added = TopShelfSettings.toggled(moviesFavorites, in: [homeTrending])
        #expect(added == [homeTrending, moviesFavorites])
        #expect(TopShelfSettings.toggled(homeTrending, in: added) == [moviesFavorites])
    }

    /// Off until a profile turns it on; turning it on for one profile turns
    /// it off for the rest.
    @Test func `the Top Shelf follows at most one profile`() throws {
        let defaults = try makeDefaults()
        let first = UUID(), second = UUID()
        #expect(TopShelfSettings.followedProfile(defaults: defaults) == nil)
        TopShelfSettings.setFollowedProfile(first, defaults: defaults)
        #expect(TopShelfSettings.followedProfile(defaults: defaults) == first)
        TopShelfSettings.setFollowedProfile(second, defaults: defaults)
        #expect(TopShelfSettings.followedProfile(defaults: defaults) == second)
        TopShelfSettings.setFollowedProfile(nil, defaults: defaults)
        #expect(TopShelfSettings.followedProfile(defaults: defaults) == nil)
    }

    /// Turning it off and on for the same profile keeps its rows; another
    /// profile starts with none, since rows belong to one profile's layout.
    @Test func `rows survive off and on, not a change of profile`() throws {
        let defaults = try makeDefaults()
        let first = UUID(), second = UUID()
        TopShelfSettings.setFollowedProfile(first, defaults: defaults)
        defaults.set(TopShelfSettings.encode([homeTrending]), forKey: TopShelfSettings.sourcesKey)

        TopShelfSettings.setFollowedProfile(nil, defaults: defaults)
        TopShelfSettings.setFollowedProfile(first, defaults: defaults)
        #expect(TopShelfSettings.sources(defaults: defaults) == [homeTrending])

        TopShelfSettings.setFollowedProfile(second, defaults: defaults)
        #expect(TopShelfSettings.sources(defaults: defaults).isEmpty)
    }

    /// Every row is recorded for the active profile, Top Shelf on or not, so
    /// turning it on or promoting a row later finds titles already there;
    /// each profile keeps its own.
    @Test func `list rows are recorded for each profile, Top Shelf on or not`() throws {
        let defaults = try makeDefaults()
        let first = UUID(), second = UUID()

        TopShelfSettings.record(["movie-a", "movie-b"], for: homeTrending, profile: first, defaults: defaults)
        TopShelfSettings.record(["movie-c"], for: moviesFavorites, profile: first, defaults: defaults)
        TopShelfSettings.record(["movie-z"], for: homeTrending, profile: second, defaults: defaults)

        #expect(TopShelfSettings.recordedItems(for: homeTrending, profile: first, defaults: defaults) == ["movie-a", "movie-b"])
        #expect(TopShelfSettings.recordedItems(for: moviesFavorites, profile: first, defaults: defaults) == ["movie-c"])
        #expect(TopShelfSettings.recordedItems(for: homeTrending, profile: second, defaults: defaults) == ["movie-z"])
        #expect(TopShelfSettings.recordedItems(for: homeTrending, profile: nil, defaults: defaults).isEmpty)
    }

    /// Turning the Top Shelf on for a profile keeps what its rows recorded
    /// before — the order a new Apple TV is set up in.
    @Test func `turning the Top Shelf on keeps what rows recorded before`() throws {
        let defaults = try makeDefaults()
        let profile = UUID()
        TopShelfSettings.record(["movie-a"], for: homeTrending, profile: profile, defaults: defaults)
        TopShelfSettings.setFollowedProfile(profile, defaults: defaults)
        #expect(TopShelfSettings.recordedItems(for: homeTrending, profile: profile, defaults: defaults) == ["movie-a"])
    }

    /// The export's one decision, for every combination that matters.
    @Test func `the export builds, keeps or clears by who follows, who is active and whose rows it shows`() {
        let followed = UUID(), other = UUID()
        #expect(TopShelfSettings.exportAction(followed: nil, active: followed, snapshotProfile: followed) == .clear)
        #expect(TopShelfSettings.exportAction(followed: followed, active: followed, snapshotProfile: nil) == .build)
        #expect(TopShelfSettings.exportAction(followed: followed, active: other, snapshotProfile: followed) == .keep)
        // It moved to a profile that isn't active: the old profile's rows go.
        #expect(TopShelfSettings.exportAction(followed: followed, active: other, snapshotProfile: other) == .clear)
        #expect(TopShelfSettings.exportAction(followed: followed, active: other, snapshotProfile: nil) == .clear)
    }

    @Test func `the Top Shelf is on only for the profile it follows`() {
        let id = UUID().uuidString
        #expect(TopShelfSettings.isOn(followedRaw: id, activeRaw: id))
        #expect(!TopShelfSettings.isOn(followedRaw: id, activeRaw: UUID().uuidString))
        #expect(!TopShelfSettings.isOn(followedRaw: "", activeRaw: ""))
        #expect(!TopShelfSettings.isOn(followedRaw: nil, activeRaw: id))
    }

    /// A failed or offline load must not wipe what a row last showed, and a
    /// batch writes every changed row.
    @Test func `an empty load keeps a row's titles, and a batch records every row`() throws {
        let defaults = try makeDefaults()
        let profile = UUID()
        TopShelfSettings.record([homeTrending: ["movie-a"], moviesFavorites: ["movie-b"]], profile: profile, defaults: defaults)
        TopShelfSettings.record([homeTrending: []], profile: profile, defaults: defaults)
        #expect(TopShelfSettings.recordedItems(for: homeTrending, profile: profile, defaults: defaults) == ["movie-a"])
        #expect(TopShelfSettings.recordedItems(for: moviesFavorites, profile: profile, defaults: defaults) == ["movie-b"])
    }
}
