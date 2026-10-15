import Foundation
@testable import Lume
import Testing

struct MetadataNumbersTests {
    @Test func `scores validate scale and retain a genuine zero`() throws {
        #expect(RatingScore(0, scale: .ten)?.value == 0)
        #expect(RatingScore(8, scale: .ten)?.fiveBased == 4)
        for invalid in [-1, 11, 1e100, Double.infinity, Double.nan] {
            #expect(RatingScore(invalid, scale: .ten) == nil)
        }
        let encoded = Data(#"{"value":101,"scale":100}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RatingScore.self, from: encoded) }
    }

    @Test func `ratings discard invalid numbers before integer formatting`() throws {
        let payload = Data(#"{"ratings":[{"source":"metacritic","value":1e100},{"source":"tomatoes","value":-1},{"source":"imdb","value":8.7}]}"#.utf8)
        let decoded = try JSONDecoder().decode(MDBListResponse.self, from: payload)
        let mapped = MDBListClient.mapRatings(decoded.ratings ?? [])
        #expect(mapped.map(\.source) == [.imdb])
        #expect(mapped.first?.value == "8.7/10")
    }

    @Test func `runtime conversions reject invalid and overflowing minutes`() {
        #expect(MediaRuntime(minutes: 120)?.seconds == 7200)
        #expect(MediaRuntime(minutes: Int.max) == nil)
        #expect(MediaRuntime(minutes: -1) == nil)
        #expect(MediaRuntime(seconds: 0) == nil)
    }
}
