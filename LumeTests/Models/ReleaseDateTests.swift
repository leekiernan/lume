import Foundation
@testable import Lume
import Testing

struct ReleaseDateTests {
    @Test func `precision survives storage and invalid days never roll forward`() throws {
        let year = try #require(ReleaseDate("2026"))
        #expect(year.precision == .year)
        #expect(year.calendarDate() == nil)
        #expect(year.storageValue == "2026")
        let date = try #require(ReleaseDate("2024-02-29T23:00:00Z"))
        #expect(date.precision == .day)
        #expect(date.storageValue == "2024-02-29")
        for invalid in ["2026-02-31", "2023-02-29", "2026-13-01", "2026-01-00", "2026garbage", "0000"] {
            #expect(ReleaseDate(invalid) == nil)
        }
        #expect(try JSONDecoder().decode(ReleaseDate.self, from: JSONEncoder().encode(date)) == date)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ReleaseDate.self, from: Data(#""2026-02-31""#.utf8)) }
        #expect(RatingsFreshness.releaseDay("2026-02-31") == nil)
    }
}
