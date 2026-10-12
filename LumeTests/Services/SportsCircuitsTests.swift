import Foundation
@testable import Lume
import Testing

struct SportsCircuitsTests {
    @Test func `the 2026 calendar's circuits are bundled with outlines`() {
        #expect(SportsCircuits.bundled.count >= 25)
        let marinaBay = SportsCircuits.circuit(id: "740")
        #expect(marinaBay?.name == "Marina Bay Street Circuit")
        #expect((marinaBay?.outline.count ?? 0) > 10)
        #expect(SportsCircuits.circuit(id: "nope") == nil && SportsCircuits.circuit(id: nil) == nil)
    }

    /// The counts ESPN reported for these races once run (2026 season).
    @Test(arguments: [("740", 62), ("601", 58), ("618", 53), ("616", 44), ("615", 53), ("611", 52), ("606", 78)])
    func `scheduled race laps follow the 305 km rule`(_ circuitID: String, _ laps: Int) {
        #expect(SportsCircuits.scheduledLaps(for: .race, circuitID: circuitID) == laps)
    }

    @Test func `sprints run 100 km and timed sessions have no lap count`() {
        #expect(SportsCircuits.scheduledLaps(for: .sprint, circuitID: "740") == 21)
        #expect(SportsCircuits.scheduledLaps(for: .qualifying, circuitID: "740") == nil)
        #expect(SportsCircuits.scheduledLaps(for: .fp1, circuitID: "740") == nil)
        #expect(SportsCircuits.scheduledLaps(for: .race, circuitID: nil) == nil)
    }

    @Test func `sessions read the laps run, and the weekend its circuit`() throws {
        let json = """
        {"events":[{"id":"600050","date":"2026-10-09T08:30Z","name":"Singapore Grand Prix",
          "circuit":{"id":"740","fullName":"Marina Bay Street Circuit"},
          "competitions":[
            {"id":"1","date":"2026-10-10T13:00Z","type":{"abbreviation":"Qual"},"status":{"period":3,"type":{"state":"post"}}},
            {"id":"2","date":"2026-10-11T12:00Z","type":{"abbreviation":"Race"},"status":{"period":34,"type":{"state":"in"}}}]}]}
        """
        let scoreboard = try JSONDecoder().decode(ESPNScoreboard.self, from: Data(json.utf8))
        let formula1 = SportsLeague(sport: "racing", slug: "f1", name: "Formula 1", abbreviation: "F1", region: .motorsport)
        let weekend = try #require(ESPNClient.mapScoreboard(scoreboard, league: formula1).first)
        #expect(weekend.circuitID == "740")
        #expect(weekend.sessions.first { $0.kind == .race }?.laps == 34)
        // A session card keeps its weekend's circuit.
        #expect(weekend.expandedBySession(now: Date()).allSatisfy { $0.circuitID == "740" })
    }

    @Test func `the laps line counts up while running and keeps a result back`() throws {
        func fixture(_ state: SportsFixtureState, laps: Int?) -> SportsFixture {
            SportsFixture(
                id: "600050#Race", leagueId: "racing/f1", leagueName: "F1", leagueAbbreviation: "F1",
                startDate: Date(), status: SportsFixtureStatus(state: state),
                sessions: [SportsSession(kind: .race, date: Date(), state: state, laps: laps)],
                sessionKind: .race, circuitID: "740"
            )
        }
        let running = try #require(RaceCircuitSummary(fixture: fixture(.inProgress, laps: 34)))
        #expect(running.isRunning && running.lapsText(hidingScores: false) == String(localized: "Lap \(34)/\(62)"))
        let scheduled = try #require(RaceCircuitSummary(fixture: fixture(.scheduled, laps: nil)))
        #expect(scheduled.lapsText(hidingScores: false) == String(localized: "\(62) Laps"))
        // A race cut short ran fewer laps: shown, unless scores are hidden.
        let shortened = try #require(RaceCircuitSummary(fixture: fixture(.final, laps: 40)))
        #expect(shortened.lapsText(hidingScores: false) == String(localized: "\(40) Laps"))
        #expect(shortened.lapsText(hidingScores: true) == String(localized: "\(62) Laps"))
        #expect(RaceCircuitSummary(fixture: SportsFixture(
            id: "x", leagueId: "racing/f1", leagueName: "", leagueAbbreviation: "", startDate: Date(),
            status: SportsFixtureStatus(state: .scheduled)
        )) == nil)
    }
}
