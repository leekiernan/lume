//
//  SportsCircuits.swift
//  Lume
//
//  Race circuits' outlines and lengths, bundled as F1Circuits.json and keyed
//  by ESPN's circuit id (`SportsFixture.circuitID`). ESPN serves no map, and
//  counts a session's laps only once they're run, so the scheduled distance
//  comes from the length here too. Built by Scripts/generate-f1-circuits.py
//  from bacinger/f1-circuits (MIT; credited in CreditsInfo).
//

import CoreGraphics
import Foundation

nonisolated struct SportsCircuit: Decodable, Hashable {
    let name: String
    /// Metres per lap.
    let length: Int
    /// The outline in a unit box, aspect kept, north up.
    let points: [[Double]]

    var outline: [CGPoint] {
        points.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }

    /// The outline's own width : height, for laying it out without distortion.
    var aspectRatio: CGFloat {
        let horizontal = outline.map(\.x), vertical = outline.map(\.y)
        guard let minX = horizontal.min(), let maxX = horizontal.max(), let minY = vertical.min(), let maxY = vertical.max(), maxY > minY else { return 1 }
        return (maxX - minX) / (maxY - minY)
    }
}

nonisolated enum SportsCircuits {
    /// ESPN's id for Monaco: the one Grand Prix run short of 305 km.
    static let monacoID = "606"

    static let bundled: [String: SportsCircuit] = load()

    static func circuit(id: String?) -> SportsCircuit? {
        id.flatMap { bundled[$0] }
    }

    /// The laps a session is run over, by the regulations' distances: the
    /// fewest laps beyond 305 km for a Grand Prix (Monaco's 78 fixed), 100 km
    /// for a sprint. `nil` for practice and qualifying, which run on time.
    static func scheduledLaps(for kind: SportsSessionKind, circuitID: String?) -> Int? {
        guard let circuit = circuit(id: circuitID), circuit.length > 0 else { return nil }
        let distance: Double
        switch kind {
        case .race:
            if circuitID == monacoID { return 78 }
            distance = 305_000
        case .sprint:
            distance = 100_000
        default:
            return nil
        }
        return Int((distance / Double(circuit.length)).rounded(.down)) + 1
    }

    static func load(bundle: Bundle = .main) -> [String: SportsCircuit] {
        struct File: Decodable {
            let circuits: [String: SportsCircuit]
        }
        for candidate in [bundle] + Bundle.allBundles {
            guard let url = candidate.url(forResource: "F1Circuits", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(File.self, from: data)
            else { continue }
            return file.circuits
        }
        return [:]
    }
}
