import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct PersonFilmographyTests {
    private typealias Credit = TMDBPersonCredit

    private func credit(
        _ id: Int, _ type: String?, date: String? = nil, character: String? = nil,
        genres: [Int]? = nil, popularity: Double? = nil
    ) -> Credit {
        Credit(
            id: id, mediaType: type, title: type == "movie" ? "Film \(id)" : nil, name: type == "tv" ? "Show \(id)" : nil,
            releaseDate: type == "movie" ? date : nil, firstAirDate: type == "tv" ? date : nil,
            character: character, genreIds: genres, popularity: popularity
        )
    }

    @Test func `credits run newest first, undated last, then by popularity`() {
        let entries = TMDBPersonCredits.entries(from: [
            credit(1, "movie", date: "2010-05-01"),
            credit(2, "tv", date: "2021-09-12"),
            credit(3, "movie"),
            credit(4, "movie", date: "2010-05-01", popularity: 40),
            credit(5, "movie", popularity: 9)
        ])
        #expect(entries.map(\.tmdbId) == [2, 4, 1, 5, 3])
        #expect(entries.first?.mediaType == .series)
    }

    @Test func `talk shows, news and playing themselves on TV are not roles`() {
        let entries = TMDBPersonCredits.entries(from: [
            credit(1, "tv", character: "Self - Guest"),
            credit(2, "tv", character: "Himself"),
            credit(3, "tv", genres: [10767]),
            credit(4, "tv", genres: [18, 10763]),
            credit(5, "tv", character: "Selfridge"),
            credit(6, "movie", character: "Herself"),
            credit(7, "person")
        ])
        // A documentary film about them stays; "Selfridge" is a character.
        #expect(Set(entries.map(\.tmdbId)) == [5, 6])
    }

    @Test func `a title credited twice appears once, but a film and a series may share an id`() {
        let entries = TMDBPersonCredits.entries(from: [
            credit(1, "movie", character: "Young Bob"),
            credit(1, "movie", character: "Old Bob"),
            credit(1, "tv")
        ])
        #expect(entries.count == 2)
    }

    @Test func `combined credits decode from TMDB's shape`() throws {
        let json = #"{"cast":[{"id":27205,"media_type":"movie","title":"Inception","release_date":"2010-07-15","character":"Cobb","genre_ids":[28],"popularity":80.1}],"crew":[]}"#
        let decoded = try JSONDecoder().decode(TMDBPersonCredits.self, from: Data(json.utf8))
        #expect(TMDBPersonCredits.entries(from: decoded.cast) == [HomeListEntry(tmdbId: 27205, mediaType: .movie, title: "Inception")])
    }

    @Test func `credits are fetched once per person and failures retry`() async {
        let calls = Counter()
        let store = PersonCreditsStore(limit: 2) { id in
            await calls.increment(id)
            if id == 99 { throw URLError(.notConnectedToInternet) }
            return [HomeListEntry(tmdbId: id, mediaType: .movie, title: "")]
        }
        async let first = store.credits(for: 1)
        async let second = store.credits(for: 1)
        #expect(await first?.first?.tmdbId == 1)
        #expect(await second?.first?.tmdbId == 1)
        _ = await store.credits(for: 1)
        #expect(await calls.count(1) == 1)

        #expect(await store.credits(for: 99) == nil)
        #expect(await store.credits(for: 99) == nil)
        #expect(await calls.count(99) == 2)

        // Least recently used goes first once the limit is passed.
        _ = await store.credits(for: 2)
        _ = await store.credits(for: 1)
        _ = await store.credits(for: 3)
        _ = await store.credits(for: 1)
        _ = await store.credits(for: 2)
        #expect(await calls.count(1) == 1)
        #expect(await calls.count(2) == 2)
    }

    @Test func `a cast card matches in its title's playlist, and the catalogue's cast is the fallback`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlistID = UUID()
        let movie = Movie(id: "\(playlistID.uuidString)-movie-7", streamId: 7, name: "Heat")
        movie.tmdbId = 949
        let series = Series(id: "\(playlistID.uuidString)-series-3", seriesId: 3, name: "Ozark")
        series.tmdbId = 69740
        context.insert(movie)
        context.insert(series)
        let lead = CastMember(id: "a", tmdbPersonId: 1158, name: "Al Pacino", movie: movie)
        context.insert(lead)
        context.insert(CastMember(id: "b", tmdbPersonId: 1158, name: "Al Pacino", series: series))
        context.insert(CastMember(id: "c", tmdbPersonId: 380, name: "Robert De Niro", movie: movie))
        try context.save()

        let route = PersonRoute(member: lead)
        #expect(route.playlistPrefix == "\(playlistID.uuidString)-")
        #expect(route.personID == 1158 && route.name == "Al Pacino")

        let local = PersonFilmography.localEntries(personID: 1158, in: context)
        #expect(Set(local.map(\.tmdbId)) == [949, 69740])
    }
}

private actor Counter {
    private var counts: [Int: Int] = [:]
    func increment(_ id: Int) {
        counts[id, default: 0] += 1
    }

    func count(_ id: Int) -> Int {
        counts[id, default: 0]
    }
}
