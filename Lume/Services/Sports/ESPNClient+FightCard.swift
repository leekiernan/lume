//
//  ESPNClient+FightCard.swift
//  Lume
//
//  A fight card's bouts from the MMA scoreboard (see `SportsFightCard`).
//

import Foundation

nonisolated extension ESPNClient {
    /// Each competition of a fight card is a bout. Fighters stand in ESPN's
    /// corner order; the result is read from the bout's "… Winner …" entry
    /// (ESPN spells KO/TKO "Kotko").
    static func mapBouts(_ event: ESPNEvent) -> [SportsBout]? {
        let bouts = (event.competitions ?? []).compactMap { competition -> SportsBout? in
            guard let id = competition.id else { return nil }
            let fighters = (competition.competitors ?? [])
                .sorted { ($0.order ?? .max) < ($1.order ?? .max) }
                .compactMap { competitor -> SportsBoutFighter? in
                    guard let athlete = competitor.athlete, let name = nonEmpty(athlete.displayName) else { return nil }
                    return SportsBoutFighter(
                        id: athlete.id ?? competitor.id ?? name,
                        name: name,
                        shortName: nonEmpty(athlete.shortName),
                        record: (competitor.records ?? []).compactMap { nonEmpty($0.summary) }.first,
                        flagURL: athlete.flag?.href.flatMap(URL.init(string:)),
                        isWinner: competitor.winner?.boolValue ?? false
                    )
                }
            let hasWinner = fighters.contains(where: \.isWinner)
            return SportsBout(
                id: id,
                startDate: parseDate(competition.date),
                weightClass: nonEmpty(competition.type?.abbreviation),
                scheduledRounds: competition.format?.regulation?.periods,
                fighters: fighters,
                status: mapStatus(competition.status),
                method: hasWinner ? boutMethod(competition.details?.entries ?? []) : nil
            )
        }
        return bouts.isEmpty ? nil : bouts
    }

    static func boutMethod(_ details: [ESPNCompetitionDetail]) -> SportsBout.Method? {
        let result = details.compactMap { $0.type?.text?.lowercased() }.first { $0.contains("winner") }
        guard let result else { return nil }
        if result.contains("submission") { return .submission }
        if result.contains("decision") { return .decision }
        if result.contains("kotko") || result.contains("ko/tko") || result.contains("tko") || result.contains(" ko") { return .knockout }
        return nil
    }
}
