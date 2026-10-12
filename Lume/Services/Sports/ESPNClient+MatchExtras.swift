//
//  ESPNClient+MatchExtras.swift
//  Lume
//
//  Soccer's form guide and text commentary from the match summary (see
//  `SportsMatchExtras`).
//

import Foundation

nonisolated extension ESPNClient {
    /// One side's last results, oldest first as ESPN lists them. Its own
    /// score comes from the home and away fields: ESPN's `score` string runs
    /// winner first, so "1-0" on a defeat is the opponent's 1.
    static func mapForm(_ entry: ESPNLastFive) -> SportsTeamForm? {
        guard let teamId = entry.team?.id else { return nil }
        let games = (entry.events?.elements ?? []).compactMap { game -> SportsFormGame? in
            guard let result = game.gameResult.flatMap(SportsFormGame.Result.init(rawValue:)),
                  let opponent = nonEmpty(game.opponent?.abbreviation) ?? nonEmpty(game.opponent?.displayName)
            else { return nil }
            let isHome = game.homeTeamId == teamId || (game.homeTeamId == nil && game.atVs == "vs")
            let home = game.homeTeamScore?.stringValue.flatMap { Int($0) }
            let away = game.awayTeamScore?.stringValue.flatMap { Int($0) }
            return SportsFormGame(
                date: parseDate(game.gameDate), result: result, opponent: opponent,
                opponentName: nonEmpty(game.opponent?.displayName), isHome: isHome,
                teamScore: isHome ? home : away, opponentScore: isHome ? away : home,
                competition: nonEmpty(game.competitionName)
            )
        }
        return games.isEmpty ? nil : SportsTeamForm(teamId: teamId, games: games)
    }

    static func mapCommentary(_ entries: [ESPNCommentary]) -> [SportsCommentaryEntry] {
        entries.enumerated().compactMap { index, entry in
            guard let text = nonEmpty(entry.text) else { return nil }
            return SportsCommentaryEntry(
                sequence: entry.sequence ?? index, minute: entry.time?.displayValue ?? "",
                text: text, kind: commentaryKind(entry.play?.type?.text)
            )
        }
        .sorted { $0.sequence < $1.sequence }
    }

    private static func commentaryKind(_ type: String?) -> SportsCommentaryEntry.Kind? {
        switch type?.lowercased() {
        case "goal", "penalty - scored": .goal
        case "own goal": .ownGoal
        case "yellow card": .yellowCard
        case "red card", "second yellow card": .redCard
        case "substitution": .substitution
        default: nil
        }
    }
}
