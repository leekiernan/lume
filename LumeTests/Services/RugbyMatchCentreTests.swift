import Foundation
@testable import Lume
import Testing

/// Rugby union's match summary as ESPN serves it, shaped like Sale Sharks v
/// Harlequins (Premiership, 2026-10-11): the matchday 23 with no starter
/// flagged, and line scores that run past the two halves.
struct RugbyMatchCentreTests {
    private static let positions = ["FB", "W", "C", "C", "W", "FH", "SH", "P", "H", "P", "L", "L", "F", "F", "N8"]

    private func roster(team: String, numbers: ClosedRange<Int> = 1 ... 23) -> String {
        let entries = numbers.map { number in
            let position = number <= 15 ? Self.positions[(number + 14) % 15] : "R"
            return #"{"starter":false,"jersey":"\#(number)","athlete":{"displayName":"Player \#(number)"},"position":{"abbreviation":"\#(position)"}}"#
        }
        return #"{"homeAway":"x","team":{"id":"\#(team)"},"roster":[\#(entries.joined(separator: ","))]}"#
    }

    private func detail(_ json: String, sport: String) throws -> SportsEventDetail {
        try ESPNClient.mapEventDetail(JSONDecoder().decode(ESPNSummaryResponse.self, from: Data(json.utf8)), sport: sport)
    }

    @Test func `the numbers one to fifteen start, the bench doesn't`() throws {
        let rugby = try detail(#"{"rosters":[\#(roster(team: "SAL"))]}"#, sport: "rugby")
        let starters = try #require(rugby.lineups.first).starters
        #expect(starters.compactMap(\.jersey) == (1 ... 15).map(String.init))
        // Soccer keeps reading its flags: an unflagged squad has no starters.
        let soccer = try detail(#"{"rosters":[\#(roster(team: "SAL"))]}"#, sport: "soccer")
        #expect(soccer.lineups.first?.starters.isEmpty == true)
    }

    @Test func `a fifteen stands pack forward, full-back deepest, wings wide`() throws {
        let lineup = try #require(try detail(#"{"rosters":[\#(roster(team: "SAL"))]}"#, sport: "rugby").lineups.first)
        let spots = try #require(RugbyPitchLayout.spots(for: lineup))
        let byNumber = Dictionary(uniqueKeysWithValues: spots.compactMap { spot in spot.player.jersey.flatMap(Int.init).map { ($0, spot) } })
        #expect(byNumber.count == 15)
        let depth = { (number: Int) in byNumber[number]?.depth ?? -1 }
        #expect((1 ... 8).allSatisfy { depth($0) > depth(9) })
        #expect((9 ... 14).allSatisfy { depth($0) > depth(15) })
        #expect([11, 12, 13, 14].compactMap { byNumber[$0]?.lateral } == [11, 12, 13, 14].compactMap { byNumber[$0]?.lateral }.sorted())
        // Any number missing and there's no layout.
        let short = SportsLineup(teamId: "t", formation: nil, starters: Array(lineup.starters.dropLast()))
        #expect(RugbyPitchLayout.spots(for: short) == nil)
    }

    @Test func `period scores keep the leading periods that add up to the score`() {
        func count(_ home: [String], _ homeScore: String?, _ away: [String], _ awayScore: String?) -> Int? {
            ESPNClient.periodCount(home: (home, homeScore), away: (away, awayScore))
        }
        // Rugby: two halves, then two figures that are neither.
        #expect(count(["14", "14", "7", "14"], "28", ["17", "7", "17", "24"], "24") == 2)
        // A scoreless last period still counts.
        #expect(count(["1", "0", "0"], "1", ["0", "2", "0"], "2") == 3)
        // Without numbers to check, every period shows; ones that never add up, none.
        #expect(count(["245/6", "180"], "245/6", ["1", "2"], "3") == 2)
        #expect(count(["1", "1"], nil, ["0", "0"], nil) == 2)
        #expect(count(["3", "3"], "7", ["0", "0"], "0") == nil)
    }
}
