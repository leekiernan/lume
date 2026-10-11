//
//  SoccerPitchLayout.swift
//  Lume
//
//  Where a soccer lineup's starters stand. ESPN gives each one an Opta
//  formation place (1–11), but a place's meaning depends on the formation —
//  in a 4-2-3-1, place 4 is a holding midfielder; in a 4-4-2, a central one —
//  and ESPN's own position codes follow suit ("LM" for a 4-2-3-1 pivot), so
//  neither alone says where a player is. SoccerFormations.json carries Opta's
//  place-to-position table per formation (from kloppy, BSD 3-Clause; credited
//  in CreditsInfo; rebuilt by Scripts/generate-soccer-formations.py).
//
//  Each position has a depth (back line to striker) and a side. The outfield
//  ten, sorted by depth, are dealt into the formation's lines ("4-2-3-1": four,
//  two, three, one), then each line is ordered left to right. Anything that
//  doesn't add up — an unknown formation, a missing place — gets no layout,
//  and the lineup shows as a list instead.
//

import Foundation

nonisolated struct SoccerPitchSpot: Hashable {
    let player: SportsLineupPlayer
    /// 0 at the team's own goal line, 1 at halfway.
    let depth: Double
    /// 0 on the team's left, 1 on its right, facing the opponent.
    let lateral: Double
}

nonisolated enum SoccerPitchLayout {
    static let formations: [String: [Int: String]] = load()

    /// The starters' spots, or `nil` when they can't be placed exactly.
    static func spots(for lineup: SportsLineup) -> [SoccerPitchSpot]? {
        guard let formation = lineup.formation else { return nil }
        let key = formation.filter(\.isNumber)
        let lines = key.compactMap(\.wholeNumberValue)
        guard lines.reduce(0, +) == 10, let table = formations[key], lineup.starters.count == 11 else { return nil }

        var keeper: SportsLineupPlayer?
        var outfield: [(player: SportsLineupPlayer, depth: Double, side: Double)] = []
        for player in lineup.starters {
            guard let place = player.formationPlace, let position = table[place], let role = role(of: position) else { return nil }
            if role.depth == 0 {
                guard keeper == nil else { return nil }
                keeper = player
            } else {
                outfield.append((player, role.depth, role.side))
            }
        }
        guard let keeper, outfield.count == 10 else { return nil }
        outfield.sort { ($0.depth, $0.side) < ($1.depth, $1.side) }

        var spots = [SoccerPitchSpot(player: keeper, depth: 0.06, lateral: 0.5)]
        var start = 0
        for (index, count) in lines.enumerated() {
            let line = outfield[start ..< start + count].sorted { $0.side < $1.side }
            start += count
            // Lines spread from just outside the box to the front line, kept
            // clear of halfway so the two strikers don't stand on each other.
            let depth = 0.24 + 0.58 * Double(index) / Double(max(lines.count - 1, 1))
            for (slot, entry) in line.enumerated() {
                spots.append(SoccerPitchSpot(player: entry.player, depth: depth, lateral: Double(slot + 1) / Double(count + 1)))
            }
        }
        return spots
    }

    /// A position's depth (0 the keeper, then back line to striker) and side
    /// (-2 wide left to 2 wide right), from kloppy's position names.
    static func role(of position: String) -> (depth: Double, side: Double)? {
        depth(of: position).map { ($0, side(of: position)) }
    }

    private static func depth(of position: String) -> Double? {
        switch position {
        case "Goalkeeper": 0
        case let name where name.hasSuffix("Back"): 1
        case let name where name.hasSuffix("DefensiveMidfield"): 2
        case let name where name.hasSuffix("AttackingMidfield"): 4
        case let name where name.hasSuffix("Midfield"): 3
        case let name where name.hasSuffix("Wing"): 4.5
        case let name where name.hasSuffix("Forward"): 5
        case "Striker": 6
        default: nil
        }
    }

    private static func side(of position: String) -> Double {
        let inner = ["Center", "Central", "Defensive", "Attacking"].contains { position.contains($0) }
        if position.hasPrefix("Left") { return inner ? -1 : -2 }
        if position.hasPrefix("Right") { return inner ? 1 : 2 }
        return 0
    }

    static func load(bundle: Bundle = .main) -> [String: [Int: String]] {
        struct File: Decodable {
            let formations: [String: [String: String]]
        }
        for candidate in [bundle] + Bundle.allBundles {
            guard let url = candidate.url(forResource: "SoccerFormations", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(File.self, from: data)
            else { continue }
            return file.formations.mapValues { places in
                Dictionary(uniqueKeysWithValues: places.compactMap { key, value in Int(key).map { ($0, value) } })
            }
        }
        return [:]
    }
}
