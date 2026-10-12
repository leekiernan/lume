//
//  SportsFightCard+Presentation.swift
//  Lume
//
//  The fight card's labels and emphasis, shared by the tvOS Match Centre and
//  the game-detail sheet.
//

import SwiftUI

extension SportsBout {
    /// "W Flyweight · 5 Rounds".
    var billingLine: String? {
        let parts = [weightClass, scheduledRounds.map { String(localized: "\($0) Rounds") }].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A finished bout dims its loser; nothing is given away under Hide Scores.
    func emphasis(of fighter: SportsBoutFighter, hidingScores: Bool) -> Double {
        guard !hidingScores, status.state == .final, winner != nil else { return 1 }
        return fighter.isWinner ? 1 : 0.5
    }
}

extension SportsFightCard.SegmentKind {
    var title: LocalizedStringKey {
        switch self {
        case .mainCard: "Main Card"
        case .prelims: "Prelims"
        case .earlyPrelims: "Early Prelims"
        }
    }
}

extension SportsBout.Method {
    var title: LocalizedStringKey {
        switch self {
        case .knockout: "KO/TKO"
        case .submission: "Submission"
        case .decision: "Decision"
        }
    }
}
