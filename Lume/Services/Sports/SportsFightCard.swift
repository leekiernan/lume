//
//  SportsFightCard.swift
//  Lume
//
//  A fight card's bouts (UFC, PFL): ESPN's scoreboard lists each bout as a
//  competition of the event, in running order, with its weight class, the
//  scheduled rounds, both fighters' records and — once it's over — the
//  winner, the method and when it ended. The same response the hub already
//  fetches, so a card costs no extra requests and the live poll updates it.
//
//  The card's segments come from the bouts' start times: the last block is the
//  main card, the one before it the prelims, anything earlier the early
//  prelims. The last bout is the main event.
//

import Foundation

nonisolated struct SportsBout: Codable, Hashable, Identifiable {
    let id: String
    let startDate: Date?
    /// ESPN's label, verbatim: "Middleweight", "W Flyweight".
    let weightClass: String?
    /// 3, or 5 for main events and title fights.
    let scheduledRounds: Int?
    /// In ESPN's corner order.
    let fighters: [SportsBoutFighter]
    let status: SportsFixtureStatus
    /// The method, once there is a winner. `nil` for a draw or no contest.
    let method: Method?

    nonisolated enum Method: String, Codable, Hashable {
        case knockout, submission, decision
    }

    var winner: SportsBoutFighter? {
        fighters.first(where: \.isWinner)
    }

    /// The round a finish came in and the clock in that round: "R2 3:35". A
    /// decision runs the distance, and a draw or no contest has no finish.
    var endedAt: (round: Int, clock: String)? {
        guard status.state == .final, let method, method != .decision, let round = status.period, round > 0,
              let clock = status.clock, !clock.isEmpty else { return nil }
        return (round, clock)
    }
}

nonisolated struct SportsBoutFighter: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let shortName: String?
    /// "28-7-0".
    let record: String?
    let flagURL: URL?
    let isWinner: Bool
}

/// A card's bouts as the viewer reads it: the main card first, the main event
/// at its top, then the prelims and early prelims.
nonisolated struct SportsFightCard {
    nonisolated enum SegmentKind: Hashable {
        case mainCard, prelims, earlyPrelims
    }

    struct Segment: Identifiable, Hashable {
        let kind: SegmentKind
        /// Latest first, as a card is billed.
        let bouts: [SportsBout]

        var id: SegmentKind {
            kind
        }
    }

    let segments: [Segment]
    /// The last bout of the night.
    let mainEvent: SportsBout?
    /// The bout under way, when it isn't the main event.
    let current: SportsBout?

    init(bouts: [SportsBout]) {
        let ordered = bouts.enumerated().sorted { lhs, rhs in
            switch (lhs.element.startDate, rhs.element.startDate) {
            case let (left?, right?) where left != right: left < right
            default: lhs.offset < rhs.offset
            }
        }.map(\.element)
        mainEvent = ordered.last
        let live = ordered.last { $0.status.state == .inProgress }
        current = live?.id == ordered.last?.id ? nil : live
        // One block per start time, latest first: main card, prelims, then
        // everything earlier counts as early prelims.
        var blocks: [[SportsBout]] = []
        for bout in ordered {
            if let last = blocks.last?.last, last.startDate == bout.startDate {
                blocks[blocks.count - 1].append(bout)
            } else {
                blocks.append([bout])
            }
        }
        var segments: [Segment] = []
        for (index, block) in blocks.reversed().enumerated() {
            let kind: SegmentKind = switch index {
            case 0: .mainCard
            case 1: .prelims
            default: .earlyPrelims
            }
            if kind == .earlyPrelims, let last = segments.last, last.kind == .earlyPrelims {
                segments[segments.count - 1] = Segment(kind: kind, bouts: last.bouts + block.reversed())
            } else {
                segments.append(Segment(kind: kind, bouts: block.reversed()))
            }
        }
        self.segments = segments
    }
}
