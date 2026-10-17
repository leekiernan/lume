import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct ProviderArtworkMaintenanceTests {
    @Test func `cleanup pages legacy art without changing history or another source`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let prefix = CatalogID.prefix(UUID(), infix: "plex")
        for index in 0 ..< 251 {
            let movie = Movie(id: prefix + String(index), streamId: index, name: "Movie",
                              streamIcon: "https://server.test/thumb/\(index)?X-Plex-Token=secret&width=600")
            movie.isFavorite = true
            movie.watchProgress = 50
            context.insert(movie)
        }
        let show = Series(id: prefix + "show", seriesId: 1, name: "Show", cover: "https://server.test/Items/1/Images/Primary?ApiKey=secret&tag=a")
        context.insert(show)
        let episode = Episode(id: prefix + "episode-1", episodeId: "1", title: "Episode", containerExtension: "mkv", seasonNum: 1, episodeNum: 1)
        episode.movieImage = "https://server.test/Items/2/Images/Primary?api_key=secret&tag=b"
        context.insert(episode)
        let other = Movie(id: "other-movie", streamId: 999, name: "Other", streamIcon: "https://other.test/art?token=provider")
        context.insert(other)
        try context.save()
        try ProviderArtworkMaintenance.scrub(prefix: prefix, in: context)
        let movies = try context.fetch(FetchDescriptor<Movie>()).filter { $0.id.hasPrefix(prefix) }
        #expect(movies.count == 251)
        #expect(movies.allSatisfy { $0.streamIcon?.contains("secret") == false && $0.isFavorite && $0.watchProgress == 50 })
        #expect(show.cover == "https://server.test/Items/1/Images/Primary?tag=a")
        #expect(episode.movieImage == "https://server.test/Items/2/Images/Primary?tag=b")
        #expect(other.streamIcon == "https://other.test/art?token=provider")
        try ProviderArtworkMaintenance.scrub(prefix: prefix, in: context)
        #expect(!context.hasChanges)
    }
}
