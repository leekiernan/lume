import Foundation
@testable import Lume
import Testing

/// Form guide and commentary, from summaries shaped like Fulham v Manchester
/// United (2026-09-20) as ESPN served it.
struct SportsMatchExtrasTests {
    private func detail(_ body: String) throws -> SportsEventDetail {
        try ESPNClient.mapEventDetail(JSONDecoder().decode(ESPNSummaryResponse.self, from: Data(body.utf8)))
    }

    /// One past game as ESPN lists it.
    private struct Game {
        let date: String, atVs: String, home: String, away: String
        let homeScore: String, awayScore: String, result: String, opponent: String

        var json: String {
            """
            {"gameDate":"\(date)T15:00Z","atVs":"\(atVs)","homeTeamId":"\(home)","awayTeamId":"\(away)",
             "homeTeamScore":"\(homeScore)","awayTeamScore":"\(awayScore)","score":"ignored","gameResult":"\(result)",
             "competitionName":"2026-27 English Premier League","opponent":{"id":"9","displayName":"\(opponent) FC","abbreviation":"\(opponent)"}}
            """
        }
    }

    @Test func `form reads each result from the team's own side`() throws {
        let body = """
        {"lastFiveGames":[{"team":{"id":"370"},"events":[
          \(Game(date: "2026-08-30", atVs: "@", home: "366", away: "370", homeScore: "1", awayScore: "0", result: "L", opponent: "SUN").json),
          \(Game(date: "2026-09-05", atVs: "vs", home: "370", away: "384", homeScore: "2", awayScore: "3", result: "L", opponent: "CRY").json),
          \(Game(date: "2026-09-12", atVs: "@", home: "364", away: "370", homeScore: "0", awayScore: "0", result: "D", opponent: "LIV").json),
          {"unexpected":true},
          \(Game(date: "2026-09-15", atVs: "@", home: "371", away: "370", homeScore: "2", awayScore: "3", result: "W", opponent: "WHU").json)]}]}
        """
        let form = try #require(try detail(body).form.first)
        #expect(form.teamId == "370")
        // The malformed entry drops out; the ones after it stay.
        #expect(form.games.map(\.opponent) == ["SUN", "CRY", "LIV", "WHU"])
        // ESPN's own "score" runs winner first; a defeat away at Sunderland is 0-1.
        #expect(form.games[0].scoreLine == "0-1" && !form.games[0].isHome && form.games[0].result == .loss)
        #expect(form.games[1].scoreLine == "2-3" && form.games[1].isHome)
        #expect(form.games[3].scoreLine == "3-2" && form.games[3].result == .win)
    }

    @Test func `commentary runs in order and marks goals, cards and changes`() throws {
        let body = """
        {"commentary":[
          {"sequence":98,"time":{"displayValue":"89'"},"text":"Goal! Fulham 1, Manchester United 1.","play":{"type":{"id":"70","text":"Goal"}}},
          {"sequence":0,"time":{"displayValue":""},"text":"Lineups are announced and players are warming up."},
          {"sequence":40,"time":{"displayValue":"38'"},"text":"Kobbie Mainoo is shown the yellow card.","play":{"type":{"text":"Yellow Card"}}},
          {"sequence":41,"time":{"displayValue":"40'"},"text":""},
          {"sequence":70,"time":{"displayValue":"66'"},"text":"Substitution, Fulham.","play":{"type":{"text":"Substitution"}}}]}
        """
        let commentary = try detail(body).commentary
        #expect(commentary.map(\.sequence) == [0, 40, 70, 98]) // the empty line drops out
        #expect(commentary.map(\.kind) == [nil, .yellowCard, .substitution, .goal])
        #expect(commentary[3].minute == "89'")
    }

    @Test func `blocks in another sport's shape never cost the summary`() throws {
        let detail = try detail(#"{"lastFiveGames":{"odd":1},"commentary":"none","rosters":[]}"#)
        #expect(detail.form.isEmpty && detail.commentary.isEmpty)
    }

    @Test func `commentary is a tab unless scores are hidden`() {
        let detail = SportsEventDetail(
            lineups: [SportsLineup(teamId: "1", formation: nil, starters: [])],
            commentary: [SportsCommentaryEntry(sequence: 1, minute: "1'", text: "Kick off.", kind: nil)]
        )
        #expect(detail.availableTabs(hidingScores: false) == [.lineup, .commentary])
        #expect(detail.availableTabs(hidingScores: true) == [.lineup])
        #expect(detail.hasTabContent(hidingScores: false))
    }

    @Test func `the header's form comes from the summary, never soccer's scoreboard string`() throws {
        func fixture(_ leagueId: String, form: String?, state: SportsFixtureState = .scheduled) -> SportsFixture {
            SportsFixture(
                id: "m", leagueId: leagueId, leagueName: "", leagueAbbreviation: "", startDate: Date(),
                status: SportsFixtureStatus(state: state),
                home: SportsCompetitor(team: SportsTeam(leagueId: leagueId, teamId: "370", name: "Fulham", shortName: "Fulham", abbreviation: "FUL"),
                                       form: form)
            )
        }
        let soccer = fixture("soccer/eng.1", form: "DLDWL")
        let home = try #require(soccer.home)
        let detail = SportsEventDetail(form: [SportsTeamForm(teamId: "370", games: [.loss, .draw, .win].map {
            SportsFormGame(date: nil, result: $0, opponent: "SUN", opponentName: nil, isHome: true, teamScore: nil, opponentScore: nil, competition: nil)
        })])
        #expect(soccer.headerForm(for: home, detail: detail) == .results([.loss, .draw, .win]))
        // The scoreboard's soccer string didn't match the results: nothing until the summary.
        #expect(soccer.headerForm(for: home, detail: nil) == nil)
        let basketball = fixture("basketball/nba", form: "WWLWL")
        #expect(try basketball.headerForm(for: #require(basketball.home), detail: nil) == .text("WWLWL"))
        // Form shows unless scores are hidden on a finished game.
        #expect(soccer.showsForm(hidingScores: true))
        #expect(!fixture("soccer/eng.1", form: nil, state: .final).showsForm(hidingScores: true))
        #expect(fixture("soccer/eng.1", form: nil, state: .final).showsForm(hidingScores: false))
    }
}
