//
//  EngineFallbackChain.swift
//  Lume
//
//  The viewer's engine order and how far down it the current stream has
//  fallen. Shared by the full-screen player and each Multi-View tile, which
//  used to keep their own index and bounds checks.
//

import Foundation

struct EngineFallbackChain: Equatable {
    /// Read once per player: a settings change doesn't reshuffle a stream
    /// already in flight.
    let priority: [PlayerEngineKind]
    /// Index into `priority` of the engine on the current stream.
    private(set) var attempt = 0

    init(priority: [PlayerEngineKind] = PlayerEnginePriority.resolveFromDefaults()) {
        self.priority = priority
    }

    var current: PlayerEngineKind {
        priority.indices.contains(attempt) ? priority[attempt] : .defaultValue
    }

    var hasNext: Bool {
        attempt + 1 < priority.count
    }

    /// Moves to the next engine. False, and unchanged, when none is left.
    @discardableResult
    mutating func advance() -> Bool {
        guard hasNext else { return false }
        attempt += 1
        return true
    }

    /// Back to the first engine: a new stream, or the viewer's Try Again.
    mutating func restart() {
        attempt = 0
    }
}

extension PlayerEnginePriority {
    /// The stored order, as every player reads it.
    static func resolveFromDefaults(_ defaults: UserDefaults = .standard) -> [PlayerEngineKind] {
        resolve(
            priorityRaw: defaults.string(forKey: PlayerSettings.enginePriorityKey) ?? "",
            legacyEngineRaw: defaults.string(forKey: PlayerSettings.engineKey) ?? PlayerEngineKind.defaultValue.rawValue
        )
    }
}
