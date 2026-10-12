//
//  ESPNDTOs+Summary.swift
//  Lume
//
//  The summary blocks behind the game-detail extras: `pickcenter` (bookmaker
//  lines), `winprobability` (per play, US sports), the header's per-period
//  line scores, and soccer's `lastFiveGames` and `commentary`. Only the fields
//  read are declared.
//

import Foundation

nonisolated struct ESPNPickcenter: Codable, Hashable {
    let provider: ESPNOddsProvider?
    let homeTeamOdds: ESPNMoneylineOdds?
    let awayTeamOdds: ESPNMoneylineOdds?
    let drawOdds: ESPNMoneylineOdds?
}

nonisolated struct ESPNOddsProvider: Codable, Hashable {
    let name: String?
}

nonisolated struct ESPNMoneylineOdds: Codable, Hashable {
    /// An American price; a number in every feed seen, decoded flexibly.
    let moneyLine: ESPNFlexibleValue?
}

nonisolated struct ESPNWinProbability: Codable, Hashable {
    let homeWinPercentage: Double?
    let tiePercentage: Double?
}

nonisolated struct ESPNSummaryHeader: Codable, Hashable {
    let competitions: [ESPNSummaryHeaderCompetition]?
}

nonisolated struct ESPNSummaryHeaderCompetition: Codable, Hashable {
    let competitors: [ESPNSummaryHeaderCompetitor]?
}

nonisolated struct ESPNSummaryHeaderCompetitor: Codable, Hashable {
    let homeAway: String?
    let score: ESPNFlexibleValue?
    let linescores: [ESPNPeriodLinescore]?
}

nonisolated struct ESPNPeriodLinescore: Codable, Hashable {
    let displayValue: String?
}

/// An array that keeps the elements it can decode and drops the rest, and
/// reads a non-array as empty: an optional block never fails its response.
nonisolated struct ESPNLossyArray<Element: Codable & Hashable>: Codable, Hashable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        guard var container = try? decoder.unkeyedContainer() else {
            elements = []
            return
        }
        var decoded: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                decoded.append(element)
            } else if (try? container.decode(ESPNSkipped.self)) == nil {
                break
            }
        }
        elements = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(elements)
    }
}

/// Consumes one element of any shape, so a lossy array can step past it.
private nonisolated struct ESPNSkipped: Codable, Hashable {
    init(from _: Decoder) throws {}
    func encode(to _: Encoder) throws {}
}

nonisolated struct ESPNLastFive: Codable, Hashable {
    let team: ESPNTeamRef?
    let events: ESPNLossyArray<ESPNLastFiveGame>?
}

nonisolated struct ESPNLastFiveGame: Codable, Hashable {
    let gameDate: String?
    /// "vs" at home, "@" away.
    let atVs: String?
    let homeTeamId: String?
    let awayTeamId: String?
    let homeTeamScore: ESPNFlexibleValue?
    let awayTeamScore: ESPNFlexibleValue?
    /// "W", "D" or "L". The `score` string beside it runs winner first, so
    /// the side's own score comes from the home/away fields instead.
    let gameResult: String?
    let competitionName: String?
    let opponent: ESPNLastFiveOpponent?
}

nonisolated struct ESPNLastFiveOpponent: Codable, Hashable {
    let id: String?
    let displayName: String?
    let abbreviation: String?
}

nonisolated struct ESPNCommentary: Codable, Hashable {
    let sequence: Int?
    let text: String?
    let time: ESPNCommentaryTime?
    let play: ESPNCommentaryPlay?
}

nonisolated struct ESPNCommentaryTime: Codable, Hashable {
    let displayValue: String?
}

nonisolated struct ESPNCommentaryPlay: Codable, Hashable {
    let type: ESPNCompetitionType?
}
