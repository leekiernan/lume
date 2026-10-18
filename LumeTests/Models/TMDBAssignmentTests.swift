import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct TMDBAssignmentTests {
    @Test func `a sparse Xtream series row keeps the catalogue match after detail hydration`() throws {
        let catalogue = try JSONDecoder().decode(XtreamSeries.self, from: Data(#"{"series_id":1,"tmdb":"1399"}"#.utf8))
        let sparse = try JSONDecoder().decode(XtreamSeries.self, from: Data(#"{"series_id":1}"#.utf8))
        let info = try JSONDecoder().decode(XtreamSeriesInfo.self, from: Data(#"{"tmdb":"1399"}"#.utf8))
        let series = Series(id: "series", seriesId: 1, name: "Show")
        series.applyProviderMetadata(info, fillMissing: true)
        series.applyProviderMetadata(sparse, fillMissing: false)
        #expect(series.tmdbIdentifier == TMDBSeriesID(1399) && series.tmdbAssignment?.origin == .providerDetails)
        series.applyProviderMetadata(catalogue, fillMissing: false)
        #expect(series.tmdbAssignment?.origin == .catalogue)
        series.applyProviderMetadata(sparse, fillMissing: false)
        #expect(series.tmdbId == 1399 && series.tmdb == "1399" && series.tmdbAssignment?.origin == .catalogue)
    }

    @Test func `search and ambiguous legacy IDs survive sparse catalogues`() throws {
        let series = Series(id: "series", seriesId: 1, name: "Show", tmdb: "1399")
        series.tmdbId = 1399
        series.applyCatalogueTMDB(nil, previous: "1399")
        #expect(series.tmdbId == 1399 && series.tmdbAssignment == nil)
        try series.assignTMDB(.series(#require(TMDBSeriesID(1399))), origin: .deviceSearch)
        series.applyCatalogueTMDB(nil, previous: "1399")
        #expect(series.tmdbId == 1399 && series.tmdbAssignment?.origin == .deviceSearch)
        try series.assignTMDB(.movie(#require(TMDBMovieID(603))), origin: .catalogue)
        #expect(series.tmdbId == 1399)
    }

    @Test func `assignment survives storage and a changed ID invalidates only metadata`() throws {
        let container = try FieldFixtures.makeContainer()
        let series = Series(id: "series", seriesId: 1, name: "Show")
        container.mainContext.insert(series)
        try series.assignTMDB(.series(#require(TMDBSeriesID(1399))), origin: .catalogue)
        series.isFavorite = true
        series.tmdbEnrichedAt = Date()
        try container.mainContext.save()
        let reader = ModelContext(container)
        let stored = try #require(reader.fetch(FetchDescriptor<Series>()).first)
        #expect(try stored.tmdbAssignment?.identity == .series(#require(TMDBSeriesID(1399))))
        try stored.assignTMDB(.series(#require(TMDBSeriesID(1396))), origin: .catalogue)
        #expect(stored.tmdbEnrichedAt == nil && stored.isFavorite)
        #expect(try stored.tmdbAssignment?.identity == .series(#require(TMDBSeriesID(1396))))
    }
}
