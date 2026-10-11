//
//  ESPNClient+Tennis.swift
//  Lume
//
//  Tennis, whose scoreboard is shaped unlike every other sport's: an event is a
//  whole tournament with its draws under `groupings`, competitors are athletes
//  with per-set `linescores`, and a tour has no teams or table — its world
//  ranking stands in for both. Split from `ESPNClient.swift` to keep that file
//  under the length cap.
//

import Foundation

nonisolated extension ESPNClient {
    /// A tennis event is a whole tournament — every draw's matches under one id —
    /// so each match becomes its own fixture. Only the tour's own main-draw
    /// singles are kept: the WTA feed carries a combined event's men's draw too,
    /// and qualifying, doubles and not-yet-decided (TBD) matches would bury the
    /// matches people follow under hundreds of cards a month.
    static func mapTennisEvent(_ event: ESPNEvent, context: ScoreboardContext) -> [SportsFixture] {
        guard let draw = context.league.tennisSinglesDraw else { return [] }
        return (event.groupings ?? [])
            .filter { $0.grouping?.slug == draw }
            .flatMap { $0.competitions ?? [] }
            .compactMap { mapTennisMatch($0, event: event, context: context) }
    }

    private static func mapTennisMatch(
        _ match: ESPNCompetition,
        event: ESPNEvent,
        context: ScoreboardContext
    ) -> SportsFixture? {
        guard let id = match.id, let startDate = parseDate(match.date) else { return nil }
        let round = nonEmpty(match.round?.displayName)
        if round?.range(of: "qualifying", options: .caseInsensitive) != nil { return nil }

        var home: SportsCompetitor?
        var away: SportsCompetitor?
        for competitor in match.competitors ?? [] {
            guard let player = mapPlayer(competitor, leagueId: context.league.id) else { return nil }
            if competitor.homeAway == "away" {
                away = player
            } else {
                home = player
            }
        }
        guard home != nil, away != nil else { return nil }

        return SportsFixture(
            id: id,
            leagueId: context.league.id,
            leagueName: context.leagueName,
            leagueAbbreviation: context.leagueAbbreviation,
            startDate: startDate,
            status: mapStatus(match.status),
            home: home,
            away: away,
            venue: nonEmpty(match.venue?.fullName) ?? nonEmpty(event.venue?.displayName),
            name: nonEmpty(event.name),
            shortName: nonEmpty(event.shortName),
            leagueLogoURL: context.leagueLogoURL,
            round: round,
            startTimeIsTentative: match.timeValid == false ? true : nil,
            tournamentId: event.id
        )
    }

    // MARK: Draw

    /// A tennis match's tournament draw. One day's scoreboard carries every
    /// tournament in play with all its matches, so the match's own day finds it.
    func tennisDraw(league: SportsLeague, fixture: SportsFixture) async -> SportsEventDetail? {
        guard let tournamentId = fixture.tournamentId, let slug = league.tennisSinglesDraw else { return nil }
        let url = Self.siteAPIBase
            .appending(path: "\(league.sport)/\(league.slug)/scoreboard")
            .appending(queryItems: [URLQueryItem(name: "dates", value: Self.dayFormatter.string(from: fixture.startDate))])
        guard let response: ESPNScoreboard = await fetch(url),
              let event = response.events?.first(where: { $0.id == tournamentId }),
              let draw = Self.mapTennisDraw(event, draw: slug)
        else { return nil }
        return SportsEventDetail(draw: draw)
    }

    /// The main draw's rounds in bracket order (`SportsTennisDraw`), or `nil`
    /// when the tournament has fewer than two rounds to show.
    static func mapTennisDraw(_ event: ESPNEvent, draw slug: String) -> SportsTennisDraw? {
        let matches = (event.groupings ?? [])
            .filter { $0.grouping?.slug == slug }
            .flatMap { $0.competitions ?? [] }
        var rounds: [Int: (name: String, matches: [SportsDrawMatch])] = [:]
        for match in matches {
            guard let id = match.id,
                  let number = match.round?.id.flatMap(Int.init),
                  let name = nonEmpty(match.round?.displayName),
                  name.range(of: "qualifying", options: .caseInsensitive) == nil
            else { continue }
            let players = (match.competitors ?? []).map(mapDrawPlayer)
            let entry = SportsDrawMatch(
                id: id, date: parseDate(match.date), isDayOnly: match.timeValid == false,
                state: mapStatus(match.status).state, players: players
            )
            rounds[number, default: (name, [])].matches.append(entry)
        }
        let ordered = rounds.sorted { $0.key < $1.key }.map { SportsDrawRound(name: $0.value.name, matches: $0.value.matches) }
        guard ordered.count > 1 else { return nil }
        return SportsTennisDraw(rounds: SportsTennisDraw.bracketOrdered(ordered))
    }

    /// A draw slot's player; `nil` while it waits on an earlier result.
    private static func mapDrawPlayer(_ competitor: ESPNCompetitor) -> SportsDrawPlayer? {
        guard let id = competitor.id, !id.hasPrefix("-"),
              let athlete = competitor.athlete,
              let name = nonEmpty(athlete.displayName), name != "TBD"
        else { return nil }
        return SportsDrawPlayer(
            id: id,
            name: name,
            shortName: nonEmpty(athlete.shortName) ?? name,
            flagURL: athlete.flag?.href.flatMap(URL.init(string:)),
            seed: competitor.curatedRank?.current,
            sets: (competitor.linescores ?? []).compactMap { line in line.value.map { SportsSetScore(games: Int($0), tiebreak: line.tiebreak) } },
            isWinner: competitor.winner?.boolValue ?? false
        )
    }

    /// A singles player as the fixture's "team", crested with their flag. A
    /// draw slot still waiting on an earlier result (a negative id, "TBD") is
    /// `nil`, which drops the whole match.
    private static func mapPlayer(_ competitor: ESPNCompetitor, leagueId: String) -> SportsCompetitor? {
        guard let id = competitor.id, !id.hasPrefix("-"),
              let athlete = competitor.athlete,
              let name = nonEmpty(athlete.displayName), name != "TBD"
        else { return nil }
        let team = SportsTeam(
            leagueId: leagueId,
            teamId: id,
            name: name,
            shortName: nonEmpty(athlete.shortName) ?? name,
            abbreviation: "",
            logoURL: athlete.flag?.href.flatMap(URL.init(string:))
        )
        let linescores = competitor.linescores ?? []
        let sets = linescores.compactMap { line in
            line.value.map { SportsSetScore(games: Int($0), tiebreak: line.tiebreak) }
        }
        return SportsCompetitor(
            team: team,
            score: linescores.count(where: { $0.winner == true }),
            isWinner: competitor.winner?.boolValue ?? false,
            sets: sets
        )
    }

    /// The world ranking, each player both as a followable "team" and as a
    /// standings row.
    static func mapRankings(
        _ response: ESPNRankingsResponse,
        leagueId: String
    ) -> [(team: SportsTeam, row: SportsStandingRow)] {
        let ranks = response.rankings?.first?.ranks ?? []
        return ranks.enumerated().compactMap { index, rank in
            guard let athlete = rank.athlete, let id = athlete.id, let name = nonEmpty(athlete.displayName) else {
                return nil
            }
            let team = SportsTeam(
                leagueId: leagueId,
                teamId: id,
                name: name,
                shortName: nonEmpty(athlete.shortname) ?? name,
                abbreviation: "",
                logoURL: athlete.flag.flatMap(URL.init(string:))
            )
            var extra: [String: String] = [:]
            if let previous = rank.previous { extra["previous"] = String(previous) }
            if let country = nonEmpty(athlete.flagAltText) { extra["country"] = country }
            let row = SportsStandingRow(
                id: id,
                kind: .player,
                teamId: id,
                name: name,
                rank: rank.current ?? index + 1,
                points: rank.points.map { Int($0) },
                extra: extra
            )
            return (team, row)
        }
    }
}
