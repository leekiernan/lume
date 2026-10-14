import Foundation
@testable import Lume
import Testing

/// Writes `ActiveProfileStore` for the profile test, so it takes the
/// process-wide lock (see `GlobalStateTrait`).
@Suite(.globalState)
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

    /// Every row is recorded, promoted or not, so a row promoted later has
    /// titles straight away — but only while the followed profile is the
    /// active one, since another profile's rows would be the wrong titles.
    @Test func `list rows are recorded only for the followed profile`() throws {
        let defaults = try makeDefaults()
        let previous = ActiveProfileStore.current
        defer { ActiveProfileStore.current = previous }
        let followed = UUID()
        ActiveProfileStore.current = followed

        TopShelfSettings.record(["movie-a"], for: homeTrending, defaults: defaults)
        #expect(TopShelfSettings.recordedItems(for: homeTrending, defaults: defaults).isEmpty)

        TopShelfSettings.setFollowedProfile(followed, defaults: defaults)
        TopShelfSettings.record(["movie-a", "movie-b"], for: homeTrending, defaults: defaults)
        TopShelfSettings.record(["movie-c"], for: moviesFavorites, defaults: defaults)
        #expect(TopShelfSettings.recordedItems(for: homeTrending, defaults: defaults) == ["movie-a", "movie-b"])
        #expect(TopShelfSettings.recordedItems(for: moviesFavorites, defaults: defaults) == ["movie-c"])

        ActiveProfileStore.current = UUID()
        TopShelfSettings.record(["movie-z"], for: homeTrending, defaults: defaults)
        #expect(TopShelfSettings.recordedItems(for: homeTrending, defaults: defaults) == ["movie-a", "movie-b"])
    }
}
