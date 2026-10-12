//
//  RugbyPitchLayout.swift
//  Lume
//
//  Where a rugby union side's fifteen stand. The shirt number is the
//  position, so there's no formation to read: the pack at the front, the
//  half-backs behind it, the back line, then the full-back, laid out as a
//  team sheet does. A lineup without exactly the numbers 1 to 15 gets no
//  layout and shows as a list.
//

import Foundation

nonisolated enum RugbyPitchLayout {
    /// Shirt number → (depth, lateral), in `PitchSpot`'s terms.
    /// Rows are staggered so no two neighbouring rows put a player in the
    /// same lane, and the front row stops short of halfway, leaving room for
    /// the other pack.
    static let positions: [Int: (depth: Double, lateral: Double)] = [
        // Front row: loosehead, hooker, tighthead.
        1: (0.88, 0.32), 2: (0.88, 0.5), 3: (0.88, 0.68),
        // Locks.
        4: (0.74, 0.41), 5: (0.74, 0.59),
        // Back row: blindside, number eight, openside.
        6: (0.6, 0.2), 8: (0.6, 0.5), 7: (0.6, 0.8),
        // Scrum-half and fly-half.
        9: (0.46, 0.38), 10: (0.42, 0.56),
        // Left wing, centres, right wing.
        11: (0.26, 0.08), 12: (0.26, 0.3), 13: (0.26, 0.7), 14: (0.26, 0.92),
        15: (0.1, 0.5)
    ]

    static func spots(for lineup: SportsLineup) -> [PitchSpot]? {
        let numbered = lineup.starters.compactMap { player in player.jersey.flatMap { Int($0) }.map { ($0, player) } }
        guard numbered.count == 15, Set(numbered.map(\.0)) == Set(1 ... 15) else { return nil }
        return numbered.compactMap { number, player in
            positions[number].map { PitchSpot(player: player, depth: $0.depth, lateral: $0.lateral) }
        }
    }
}
