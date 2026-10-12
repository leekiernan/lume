import Foundation
@testable import Lume
import Testing

/// Fight cards from ESPN's MMA scoreboard, in the shape UFC 332 and UFC Fight
/// Night: Allen vs. Duncan were served (trimmed): bouts in running order, one
/// start time per block, the result in a "… Winner …" detail.
struct SportsFightCardTests {
    private let ufc = SportsLeague(sport: "mma", slug: "ufc", name: "UFC", abbreviation: "UFC", region: .combat)

    private func bout(
        _ id: String, _ time: String, _ weight: String, rounds: Int = 3, red: String, blue: String,
        winner: Int? = nil, result: String? = nil, state: String = "post", round: Int = 3, clock: String = "5:00"
    ) -> String {
        func fighter(_ name: String, order: Int) -> String {
            """
            {"id":"\(id)\(order)","order":\(order),"winner":\(winner == order),
             "athlete":{"id":"a\(id)\(order)","displayName":"\(name)","shortName":"\(name.prefix(1)). \(name)",
                        "flag":{"href":"https://a.espncdn.com/flags/\(order).png"}},
             "records":[{"name":"overall","type":"total","summary":"\(10 + order)-2-0"}]}
            """
        }
        let details = result.map { #"[{"id":"1","type":{"id":"20","text":"\#($0)"}},{"id":"2","type":{"id":"23","text":"Results"}}]"# } ?? "[]"
        let statusName = ["in": "STATUS_IN_PROGRESS", "pre": "STATUS_SCHEDULED"][state] ?? "STATUS_FINAL"
        return """
        {"id":"\(id)","date":"2026-10-0\(time)Z","type":{"id":"9","abbreviation":"\(weight)"},
         "format":{"regulation":{"periods":\(rounds)}},
         "status":{"period":\(round),"displayClock":"\(clock)","type":{"name":"\(statusName)","state":"\(state)","detail":"","shortDetail":""}},
         "competitors":[\(fighter(red, order: 1)),\(fighter(blue, order: 2))],"details":\(details)}
        """
    }

    private func card(_ bouts: [String]) throws -> SportsFixture {
        let json = """
        {"events":[{"id":"600057","date":"2026-10-03T20:00Z","name":"UFC 332: Silva vs. Wang","shortName":"UFC 332",
          "competitions":[\(bouts.joined(separator: ","))]}]}
        """
        let scoreboard = try JSONDecoder().decode(ESPNScoreboard.self, from: Data(json.utf8))
        return try #require(ESPNClient.mapScoreboard(scoreboard, league: ufc).first)
    }

    @Test func `bouts carry fighters, records, results and when they ended`() throws {
        let fixture = try card([
            bout("1", "3T20:00", "Welterweight", red: "McGee", blue: "Nolan", winner: 2, result: "Unofficial Winner Kotko", round: 3, clock: "3:26"),
            bout("2", "3T22:00", "Flyweight", red: "Rodriguez", blue: "Coria", winner: 1, result: "Unofficial Winner Submission", round: 1, clock: "3:11"),
            bout("3", "4T00:00", "Welterweight", red: "Soldic", blue: "Williams", winner: 1, result: "Unofficial Winner Decision"),
            bout("4", "4T00:00", "W Flyweight", rounds: 5, red: "Silva", blue: "Wang", state: "in", round: 2, clock: "1:04")
        ])
        let bouts = try #require(fixture.bouts)
        #expect(bouts.count == 4)
        let knockout = bouts[0]
        #expect(knockout.weightClass == "Welterweight" && knockout.scheduledRounds == 3)
        #expect(knockout.fighters.map(\.name) == ["McGee", "Nolan"])
        #expect(knockout.winner?.name == "Nolan" && knockout.method == .knockout)
        #expect(knockout.endedAt?.round == 3 && knockout.endedAt?.clock == "3:26")
        #expect(knockout.fighters[0].record == "11-2-0" && knockout.fighters[0].flagURL != nil)
        #expect(bouts[1].method == .submission && bouts[1].endedAt?.round == 1)
        // A decision goes the distance: the method says it all.
        #expect(bouts[2].method == .decision && bouts[2].endedAt == nil)
        #expect(bouts[3].status.state == .inProgress && bouts[3].winner == nil && bouts[3].method == nil)
    }

    @Test func `a bout with no winner is a draw or no contest, not a decision`() throws {
        let fixture = try card([bout("1", "3T20:00", "W Flyweight", red: "Kareckaite", blue: "Gatto")])
        let draw = try #require(fixture.bouts?.first)
        #expect(draw.winner == nil && draw.method == nil && draw.endedAt == nil)
    }

    @Test func `the card is billed main card first, the main event at its top`() throws {
        let fixture = try card([
            bout("1", "3T20:00", "Welterweight", red: "A", blue: "B", winner: 1, result: "Unofficial Winner Kotko"),
            bout("2", "3T20:00", "Lightweight", red: "C", blue: "D", winner: 1, result: "Unofficial Winner Kotko"),
            bout("3", "3T22:00", "Heavyweight", red: "E", blue: "F", winner: 1, result: "Unofficial Winner Kotko"),
            bout("4", "4T00:00", "Bantamweight", red: "G", blue: "H", state: "in", round: 1, clock: "2:00"),
            bout("5", "4T00:00", "W Flyweight", rounds: 5, red: "Silva", blue: "Wang", state: "pre", round: 0, clock: "0:00")
        ])
        let card = try SportsFightCard(bouts: #require(fixture.bouts))
        #expect(card.segments.map(\.kind) == [.mainCard, .prelims, .earlyPrelims])
        #expect(card.segments[0].bouts.map(\.id) == ["5", "4"])
        #expect(card.segments[2].bouts.map(\.id) == ["2", "1"])
        #expect(card.mainEvent?.id == "5")
        // The co-main event is being fought; the main event is still to come.
        #expect(card.current?.id == "4")
    }

    @Test func `the bout being fought is current unless it is the main event`() {
        func bout(_ id: String, _ state: SportsFixtureState) -> SportsBout {
            SportsBout(id: id, startDate: nil, weightClass: nil, scheduledRounds: 3, fighters: [],
                       status: SportsFixtureStatus(state: state), method: nil)
        }
        #expect(SportsFightCard(bouts: [bout("1", .final), bout("2", .inProgress), bout("3", .scheduled)]).current?.id == "2")
        #expect(SportsFightCard(bouts: [bout("1", .final), bout("2", .final), bout("3", .inProgress)]).current == nil)
        #expect(SportsFightCard(bouts: [bout("1", .final), bout("2", .inProgress)]).segments.map(\.kind) == [.mainCard])
    }

    @Test func `an unexpected details shape never costs the scoreboard`() throws {
        let json = """
        {"events":[{"id":"9","date":"2026-10-03T20:00Z","name":"Other",
          "competitions":[{"id":"1","date":"2026-10-03T20:00Z","details":{"unexpected":true},"competitors":[]}]}]}
        """
        let scoreboard = try JSONDecoder().decode(ESPNScoreboard.self, from: Data(json.utf8))
        #expect(scoreboard.events?.first?.competitions?.first?.details?.entries.isEmpty == true)
        let soccer = SportsLeague(sport: "soccer", slug: "eng.1", name: "Premier League", abbreviation: "EPL", region: .ukAndIreland)
        #expect(ESPNClient.mapScoreboard(scoreboard, league: soccer).first?.bouts == nil)
    }
}
