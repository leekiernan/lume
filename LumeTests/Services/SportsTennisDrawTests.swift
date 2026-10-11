import Foundation
@testable import Lume
import Testing

/// A tennis draw rebuilt from progression, from a scoreboard shaped like the
/// China Open's (2026-10): ESPN lists each round's matches by start time, not
/// by where they sit in the draw.
struct SportsTennisDrawTests {
    private static func match(_ id: String, round: (String, String), date: String, _ players: [(id: String, name: String, won: Bool?)]) -> String {
        let competitors = players.enumerated().map { index, player in
            let winner = player.won.map { #","winner":\#($0)"# } ?? ""
            return #"{"id":"\#(player.id)","homeAway":"\#(index == 0 ? "home" : "away")"\#(winner),"curatedRank":{"current":\#(index + 10)},"athlete":{"displayName":"\#(player.name)"}}"#
        }
        let state = players.contains { $0.won != nil } ? "post" : "pre"
        let status = #""status":{"type":{"state":"\#(state)"}}"#
        return #"{"id":"\#(id)","date":"\#(date)","round":{"id":"\#(round.0)","displayName":"\#(round.1)"},\#(status),"competitors":[\#(competitors.joined(separator: ","))]}"#
    }

    private static let quarter = ("5", "Quarterfinal"), semi = ("6", "Semifinal"), final = ("7", "Final")

    private static let event: String = {
        let matches = [
            match("183462", round: quarter, date: "2026-10-04T05:10Z", [("2367", "Karen Khachanov", false), ("2726", "Hubert Hurkacz", true)]),
            match("183463", round: quarter, date: "2026-10-04T07:05Z", [("2642", "Andrey Rublev", false), ("2651", "Alex de Minaur", true)]),
            match("183464", round: quarter, date: "2026-10-04T08:40Z", [("3700", "Francisco Cerundolo", false), ("2383", "Daniil Medvedev", true)]),
            match("183465", round: quarter, date: "2026-10-04T11:10Z", [("296", "Novak Djokovic", true), ("2375", "Alexander Zverev", false)]),
            match("183466", round: semi, date: "2026-10-05T09:25Z", [("2726", "Hubert Hurkacz", false), ("2651", "Alex de Minaur", true)]),
            match("183467", round: semi, date: "2026-10-05T11:20Z", [("2383", "Daniil Medvedev", false), ("296", "Novak Djokovic", true)]),
            // Djokovic listed first, so his half of the draw leads.
            match("183468", round: final, date: "2026-10-06T11:10Z", [("296", "Novak Djokovic", nil), ("-1", "TBD", nil)]),
            match("186254", round: ("11", "Qualifying 1st Round"), date: "2026-09-28T03:00Z", [("1", "Q One", true), ("2", "Q Two", false)])
        ]
        return #"{"id":"959-2026","name":"China Open","groupings":[{"grouping":{"slug":"mens-singles"},"competitions":[\#(matches.joined(separator: ","))]},"#
            + #"{"grouping":{"slug":"womens-singles"},"competitions":[\#(match("9", round: final, date: "2026-10-06T08:00Z", [("7", "W", nil), ("8", "X", nil)]))]}]}"#
    }()

    @Test func `each round follows the matches its players came through`() throws {
        let event = try JSONDecoder().decode(ESPNEvent.self, from: Data(Self.event.utf8))
        let draw = try #require(ESPNClient.mapTennisDraw(event, draw: "mens-singles"))
        // Qualifying and the other tour's draw stay out.
        #expect(draw.rounds.map(\.name) == ["Quarterfinal", "Semifinal", "Final"])
        #expect(draw.rounds[1].matches.map(\.id) == ["183467", "183466"])
        #expect(draw.rounds[0].matches.map(\.id) == ["183464", "183465", "183462", "183463"])
        let final = draw.rounds[2].matches[0]
        #expect(final.players[0]?.name == "Novak Djokovic" && final.players[1] == nil)
        #expect(final.players[0]?.seed == 10)
        #expect(draw.rounds[0].matches[1].players[0]?.isWinner == true)
    }

    @Test func `undecided slots take the unlinked matches by start time, byes take none`() {
        func player(_ id: String) -> SportsDrawPlayer {
            SportsDrawPlayer(id: id, name: id, shortName: id, flagURL: nil, seed: nil, sets: [], isWinner: false)
        }
        func match(_ id: String, day: Double, _ players: [SportsDrawPlayer?]) -> SportsDrawMatch {
            SportsDrawMatch(id: id, date: Date(timeIntervalSince1970: day * 86400), isDayOnly: false, state: .scheduled, players: players)
        }
        let first = SportsDrawRound(name: "Round 1", matches: [
            match("C", day: 3, [player("c1"), player("c2")]),
            match("A", day: 1, [player("a1"), player("a2")]),
            match("B", day: 2, [player("b1"), player("b2")])
        ])
        // The seed "s" had a bye; a1 is through, the other two slots wait.
        let second = SportsDrawRound(name: "Round 2", matches: [
            match("Y", day: 11, [player("s"), nil]),
            match("X", day: 10, [nil, player("a1")])
        ])
        let ordered = SportsTennisDraw.bracketOrdered([first, second])
        #expect(ordered.map(\.name) == ["Round 1", "Round 2"])
        #expect(ordered[1].matches.map(\.id) == ["X", "Y"])
        #expect(ordered[0].matches.map(\.id) == ["B", "A", "C"])
    }

    @Test func `the draw opens on the match's round and hides with the scores`() {
        let draw = SportsTennisDraw(rounds: [
            SportsDrawRound(name: "Semifinal", matches: []),
            SportsDrawRound(name: "Final", matches: [])
        ])
        let fixture = SportsFixture(
            id: "1", leagueId: "tennis/atp", leagueName: "", leagueAbbreviation: "", startDate: Date(),
            status: SportsFixtureStatus(state: .scheduled), round: "Semifinal"
        )
        #expect(draw.initialRound(for: fixture) == "Semifinal")
        let detail = SportsEventDetail(draw: draw)
        #expect(detail.availableTabs(hidingScores: false) == [.draw])
        #expect(detail.availableTabs(hidingScores: true).isEmpty)
        #expect(!detail.hasTabContent(hidingScores: true))
    }
}
