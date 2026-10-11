//
//  SportsMatchExtras.swift
//  Lume
//
//  A soccer match's form guide and text commentary, from the provider's
//  match summary. Both are results in all but name — the form guide lists
//  scores, the commentary narrates every goal — so both stay hidden under
//  Hide Scores.
//

import Foundation

/// One team's recent results, oldest first, as a form guide reads left to right.
nonisolated struct SportsTeamForm: Codable, Hashable {
    let teamId: String
    let games: [SportsFormGame]
}

nonisolated struct SportsFormGame: Codable, Hashable {
    nonisolated enum Result: String, Codable, Hashable {
        case win = "W", draw = "D", loss = "L"
    }

    let date: Date?
    let result: Result
    /// The opponent's short code ("SUN") and name.
    let opponent: String
    let opponentName: String?
    let isHome: Bool
    /// The score from this team's side, when the provider gave both.
    let teamScore: Int?
    let opponentScore: Int?
    let competition: String?

    /// "1-0", this team's goals first.
    var scoreLine: String? {
        guard let teamScore, let opponentScore else { return nil }
        return "\(teamScore)-\(opponentScore)"
    }
}

/// One line of live text commentary.
nonisolated struct SportsCommentaryEntry: Codable, Hashable, Identifiable {
    nonisolated enum Kind: String, Codable, Hashable {
        case goal, ownGoal, yellowCard, redCard, substitution
    }

    let sequence: Int
    /// The match minute as the provider renders it ("45'+2"); empty for
    /// lines outside play, such as the lineups being announced.
    let minute: String
    /// English prose, shown verbatim: the provider has no other language.
    let text: String
    let kind: Kind?

    var id: Int {
        sequence
    }
}
