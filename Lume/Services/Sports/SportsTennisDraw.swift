//
//  SportsTennisDraw.swift
//  Lume
//
//  A tennis tournament's singles draw, round by round, for the match centre.
//  The provider lists every main-draw match — slots still waiting on a result
//  included — but in neither bracket nor id order, and it has no draw
//  positions. The order is rebuilt from progression instead: working back from
//  the last round, each match is followed by the earlier matches its two
//  players came through, so the two matches that feed one tie sit together.
//  A slot nobody has reached yet links to nothing; the unlinked matches of
//  that round fill those gaps in the order they're scheduled, a guess the
//  draw never presents as a bracket line.
//

import Foundation

nonisolated struct SportsTennisDraw: Codable, Hashable {
    /// First round first.
    let rounds: [SportsDrawRound]

    /// The round a match is in, by the provider's name for it.
    func round(named name: String?) -> SportsDrawRound? {
        rounds.first { $0.name == name }
    }
}

nonisolated struct SportsDrawRound: Codable, Hashable, Identifiable {
    /// The provider's English name ("Round 2", "Quarterfinal");
    /// `SportsRoundLabel` localises it.
    let name: String
    /// In draw order (see the file comment).
    let matches: [SportsDrawMatch]

    var id: String {
        name
    }
}

nonisolated struct SportsDrawMatch: Codable, Hashable, Identifiable {
    let id: String
    let date: Date?
    /// `date` is only the day: the match isn't on an order of play yet.
    let isDayOnly: Bool
    let state: SportsFixtureState
    /// The two slots in the provider's order; `nil` until someone reaches it.
    let players: [SportsDrawPlayer?]

    func contains(_ playerId: String) -> Bool {
        players.contains { $0?.id == playerId }
    }
}

nonisolated struct SportsDrawPlayer: Codable, Hashable {
    let id: String
    let name: String
    let shortName: String
    let flagURL: URL?
    /// The player's seeding in this tournament; `nil` when unseeded.
    let seed: Int?
    let sets: [SportsSetScore]
    let isWinner: Bool
}

nonisolated extension SportsTennisDraw {
    /// Orders each round's matches by progression. `rounds` run first to last,
    /// each in any order.
    static func bracketOrdered(_ rounds: [SportsDrawRound]) -> [SportsDrawRound] {
        guard var next = rounds.last else { return [] }
        let chronological: (SportsDrawMatch, SportsDrawMatch) -> Bool = {
            ($0.date ?? .distantFuture, $0.id) < ($1.date ?? .distantFuture, $1.id)
        }
        next = SportsDrawRound(name: next.name, matches: next.matches.sorted(by: chronological))
        var ordered = [next]
        for round in rounds.dropLast().reversed() {
            let pool = round.matches.sorted(by: chronological)
            var placed: Set<String> = []
            // A known player links to the match they came through; `nil` is a
            // slot still waiting on one. A player with no earlier match had a bye.
            var slots: [SportsDrawMatch?] = []
            for player in next.matches.flatMap(\.players) {
                guard let player else {
                    slots.append(nil)
                    continue
                }
                if let feeder = pool.first(where: { $0.contains(player.id) }), placed.insert(feeder.id).inserted {
                    slots.append(feeder)
                }
            }
            var unlinked = pool.filter { !placed.contains($0.id) }.makeIterator()
            var matches = slots.compactMap { $0 ?? unlinked.next() }
            while let leftover = unlinked.next() {
                matches.append(leftover)
            }
            next = SportsDrawRound(name: round.name, matches: matches)
            ordered.append(next)
        }
        return ordered.reversed()
    }
}
