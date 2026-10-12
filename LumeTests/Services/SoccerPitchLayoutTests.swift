import Foundation
@testable import Lume
import Testing

/// Lineups on the pitch, from ESPN summaries shaped like the Premier League's
/// (a 4-2-3-1 against a 3-4-2-1), formation places as ESPN sends them.
struct SoccerPitchLayoutTests {
    private func roster(team: String, formation: String, places: [(Int, String)]) -> String {
        let entries = places.map { place, name in
            // ESPN sends places as strings; one as a number proves either reads.
            let value = place == 11 ? "11" : "\"\(place)\""
            return #"{"starter":true,"jersey":"\#(place)","formationPlace":\#(value),"athlete":{"displayName":"\#(name)"},"position":{"abbreviation":"X"}}"#
        }
        return #"{"homeAway":"x","formation":"\#(formation)","team":{"id":"\#(team)"},"roster":[\#(entries.joined(separator: ","))]}"#
    }

    private func detail(_ rosters: [String]) throws -> SportsEventDetail {
        let json = #"{"rosters":[\#(rosters.joined(separator: ","))]}"#
        return try ESPNClient.mapEventDetail(JSONDecoder().decode(ESPNSummaryResponse.self, from: Data(json.utf8)))
    }

    private let elevenNames = (1 ... 11).map { (place: $0, name: "Player \($0)") }

    @Test func `a 4-2-3-1 lines up back four, pivot, three and striker, left to right`() throws {
        let lineup = try #require(try detail([roster(team: "1", formation: "4-2-3-1", places: elevenNames.map { ($0.place, $0.name) })]).lineups.first)
        #expect(lineup.starters.allSatisfy { $0.formationPlace != nil })
        let spots = try #require(SoccerPitchLayout.spots(for: lineup))
        let lines = Dictionary(grouping: spots, by: \.depth).sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.lateral < $1.lateral }.compactMap(\.player.formationPlace) }
        // Opta's 4-2-3-1: 3 LB, 6 LCB, 5 RCB, 2 RB; 8 and 4 the pivot;
        // 11, 10, 7 behind the striker, 9.
        #expect(lines == [[1], [3, 6, 5, 2], [8, 4], [11, 10, 7], [9]])
    }

    @Test func `a 3-4-2-1 puts its wing-backs in the midfield four`() throws {
        let lineup = try #require(try detail([roster(team: "2", formation: "3-4-2-1", places: elevenNames.map { ($0.place, $0.name) })]).lineups.first)
        let spots = try #require(SoccerPitchLayout.spots(for: lineup))
        let lines = Dictionary(grouping: spots, by: \.depth).sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.lateral < $1.lateral }.compactMap(\.player.formationPlace) }
        #expect(lines == [[1], [4, 5, 6], [3, 8, 7, 2], [11, 10], [9]])
    }

    @Test func `every bundled formation places all eleven`() {
        #expect(SoccerPitchLayout.formations.count >= 20)
        for (key, _) in SoccerPitchLayout.formations {
            let formation = key.map(String.init).joined(separator: "-")
            let lineup = SportsLineup(teamId: "t", formation: formation, starters: (1 ... 11).map {
                SportsLineupPlayer(name: "P\($0)", jersey: "\($0)", position: nil, formationPlace: $0)
            })
            #expect(SoccerPitchLayout.spots(for: lineup)?.count == 11, "\(formation)")
        }
    }

    @Test func `anything that doesn't add up keeps the list`() {
        func lineup(_ formation: String?, places: [Int?]) -> SportsLineup {
            SportsLineup(teamId: "t", formation: formation, starters: places.enumerated().map { index, place in
                SportsLineupPlayer(name: "P\(index)", jersey: nil, position: nil, formationPlace: place)
            })
        }
        let all = (1 ... 11).map(Optional.some)
        #expect(SoccerPitchLayout.spots(for: lineup("4-2-3-1", places: all)) != nil)
        #expect(SoccerPitchLayout.spots(for: lineup("4-2-3-1", places: Array(all.dropLast()) + [nil])) == nil)
        #expect(SoccerPitchLayout.spots(for: lineup("4-2-3-1", places: Array(all.dropLast()))) == nil)
        #expect(SoccerPitchLayout.spots(for: lineup("9-9-9", places: all)) == nil)
        #expect(SoccerPitchLayout.spots(for: lineup(nil, places: all)) == nil)
        #expect(SoccerPitchLayout.spots(for: lineup("4-2-3-1", places: [1, 1] + Array(all.dropFirst(2)))) == nil)
    }
}
