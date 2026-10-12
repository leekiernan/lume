import Foundation
@testable import Lume
import Testing

struct SportsOddsLabelTests {
    private func competitor(_ abbreviation: String) -> SportsCompetitor {
        SportsCompetitor(team: SportsTeam(
            leagueId: "soccer/eng.1", teamId: abbreviation, name: abbreviation, shortName: abbreviation, abbreviation: abbreviation
        ))
    }

    @Test func `outcomes read as the teams and a draw, not 1 X 2`() {
        let fixture = SportsFixture(
            id: "m", leagueId: "soccer/eng.1", leagueName: "EPL", leagueAbbreviation: "EPL", startDate: Date(),
            status: SportsFixtureStatus(state: .scheduled), home: competitor("ARS"), away: competitor("LEE")
        )
        let labels = fixture.oddsOutcomeLabels
        #expect(labels.home == "ARS" && labels.away == "LEE" && labels.draw == String(localized: "Draw"))
    }

    @Test func `teams without a code fall back to the bookmaker's 1 and 2`() {
        let fixture = SportsFixture(
            id: "m", leagueId: "soccer/eng.1", leagueName: "EPL", leagueAbbreviation: "EPL", startDate: Date(),
            status: SportsFixtureStatus(state: .scheduled), home: competitor(" "), away: nil
        )
        #expect(fixture.oddsOutcomeLabels.home == "1" && fixture.oddsOutcomeLabels.away == "2")
    }
}
