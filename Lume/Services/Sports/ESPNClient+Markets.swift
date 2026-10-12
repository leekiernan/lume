//
//  ESPNClient+Markets.swift
//  Lume
//
//  Maps the summary's bookmaker lines, win probability and period scores
//  (split from ESPNClient.swift, at its length limit).
//

import Foundation

nonisolated extension ESPNClient {
    /// The first provider that prices both sides.
    static func mapOdds(_ pickcenter: [ESPNPickcenter]?) -> SportsOdds? {
        for line in pickcenter ?? [] {
            let home = line.homeTeamOdds?.moneyLine.flatMap(moneyline).flatMap(SportsOdds.decimal(fromMoneyline:))
            let away = line.awayTeamOdds?.moneyLine.flatMap(moneyline).flatMap(SportsOdds.decimal(fromMoneyline:))
            guard home != nil, away != nil else { continue }
            let draw = line.drawOdds?.moneyLine.flatMap(moneyline).flatMap(SportsOdds.decimal(fromMoneyline:))
            return SportsOdds(provider: line.provider?.name ?? "", home: home, draw: draw, away: away)
        }
        return nil
    }

    /// The latest play's probability.
    static func mapWinProbability(_ series: [ESPNWinProbability]?) -> SportsWinProbability? {
        guard let last = series?.last, let home = last.homeWinPercentage else { return nil }
        return SportsWinProbability(home: min(max(home, 0), 1), tie: min(max(last.tiePercentage ?? 0, 0), 1))
    }

    /// Both sides' per-period scores, when both have at least one.
    static func mapPeriodScores(_ header: ESPNSummaryHeader?) -> SportsPeriodScores? {
        let competitors = header?.competitions?.first?.competitors ?? []
        guard let home = competitors.first(where: { $0.homeAway == "home" }),
              let away = competitors.first(where: { $0.homeAway == "away" })
        else { return nil }
        let homeScores = (home.linescores ?? []).compactMap(\.displayValue)
        let awayScores = (away.linescores ?? []).compactMap(\.displayValue)
        guard !homeScores.isEmpty, homeScores.count == awayScores.count else { return nil }
        guard let count = periodCount(home: (homeScores, home.score?.stringValue), away: (awayScores, away.score?.stringValue)) else { return nil }
        return SportsPeriodScores(home: Array(homeScores.prefix(count)), away: Array(awayScores.prefix(count)))
    }

    /// How many leading periods to show: the most whose sums are both sides'
    /// scores. Rugby's feed sends each half and then two running totals
    /// (Sale 14, 14, 7, 14 for a 28), which only the first two add up to.
    /// Scores that aren't plain numbers keep every period; periods that never
    /// add up show none.
    static func periodCount(home: ([String], String?), away: ([String], String?)) -> Int? {
        /// Each side's running total after every period, and its score.
        func running(_ side: ([String], String?)) -> (totals: [Int], score: Int)? {
            let periods = side.0.compactMap { Int($0) }
            guard periods.count == side.0.count, let score = side.1.flatMap({ Int($0) }) else { return nil }
            var total = 0
            return (periods.map { total += $0; return total }, score)
        }
        guard let home = running(home), let away = running(away) else { return home.0.count }
        return home.totals.indices.last { home.totals[$0] == home.score && away.totals[$0] == away.score }.map { $0 + 1 }
    }

    private static func moneyline(_ value: ESPNFlexibleValue) -> Double? {
        value.stringValue.flatMap(Double.init)
    }
}
