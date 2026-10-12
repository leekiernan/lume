//
//  ESPNClient+Lineups.swift
//  Lume
//
//  A summary's rosters as starting lineups. Soccer flags its starters; a
//  rugby union roster lists the matchday 23 with no starter flagged, but its
//  numbers are the positions — 1 to 15 start, 16 to 23 are the bench.
//

import Foundation

nonisolated extension ESPNClient {
    static func mapLineup(_ roster: ESPNRoster, sport: String?) -> SportsLineup? {
        guard let teamId = roster.team?.id else { return nil }
        let entries = roster.roster ?? []
        let flagged = entries.filter { $0.starter ?? false }
        let starters = if flagged.isEmpty, sport == "rugby" {
            entries.filter { $0.jersey.flatMap { Int($0) }.map { (1 ... 15).contains($0) } ?? false }
        } else {
            flagged
        }
        let players = starters.compactMap { entry -> SportsLineupPlayer? in
            guard let name = entry.athlete?.displayName else { return nil }
            return SportsLineupPlayer(
                name: name, jersey: entry.jersey, position: entry.position?.abbreviation,
                formationPlace: entry.formationPlace?.stringValue.flatMap { Int($0) }
            )
        }
        return SportsLineup(teamId: teamId, formation: roster.formation, starters: players)
    }
}
