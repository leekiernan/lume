import Foundation
@testable import Lume
import Testing

struct SportsFixtureWindowTests {
    @Test func `only successful windows replace old fixtures including an empty schedule`() throws {
        let january = SportsFixtureWindow.month(DateComponents(year: 2026, month: 1))
        let february = SportsFixtureWindow.month(DateComponents(year: 2026, month: 2))
        let march = SportsFixtureWindow.month(DateComponents(year: 2026, month: 3))
        let januaryStart = try #require(january.interval).start
        let februaryStart = try #require(february.interval).start
        let marchStart = try #require(march.interval).start
        func fixture(_ id: String, at date: Date) -> SportsFixture {
            SportsFixture(id: id, leagueId: "league", leagueName: "League", leagueAbbreviation: "LG",
                          startDate: date, status: SportsFixtureStatus(state: .scheduled))
        }
        let old = [fixture("withdrawn", at: januaryStart), fixture("outage", at: februaryStart), fixture("outside", at: marchStart)]
        let results = [
            SportsFixtureWindowResult(window: january, result: .success([])),
            SportsFixtureWindowResult(window: february, result: .failure(URLError(.timedOut)))
        ]
        #expect(Set(SportsFixtureWindowResult.merging(results, into: old).map(\.id)) == ["outage", "outside"])
        let rescheduled = SportsFixtureWindowResult(window: january, result: .success([fixture("outage", at: januaryStart)]))
        let merged = SportsFixtureWindowResult.merging([rescheduled], into: old)
        #expect(merged.count(where: { $0.id == "outage" }) == 1)
        #expect(merged.first { $0.id == "outage" }?.startDate == januaryStart)
    }
}
