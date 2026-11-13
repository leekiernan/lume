//
//  LiveSourceRecovery.swift
//  Lume
//
//  A live source that stays down past AetherEngine's own bounded reopen makes
//  the engine park production and report `liveSourceReset`. Retuning (a fresh
//  load) throws away the cache, the replay history and the picture on screen,
//  and costs a full join. The engine can often pick the parked source up again
//  in place, keeping all of that, but never schedules that retry itself: the
//  timing is Lume's. These are the pure parts of that timing; the
//  `AetherSessionMachine` runs them.
//

import Foundation

/// How an in-place retry went, judged a while after the engine accepted it.
nonisolated enum LiveSourceRecoveryVerdict: Equatable {
    /// Playing, and the playhead moved since the retry.
    case recovered
    /// The source is back and the engine is buffering towards the picture.
    case refilling
    /// Still stalled, or `.playing` with a stuck clock.
    case frozen

    /// How far the playhead must advance to count as recovered; a frozen
    /// consumer reports `.playing` with a stuck clock.
    static let minimumProgress: Double = 2

    init(phase: AetherSessionMachine.EnginePhase, positionAtRetry: Double, positionNow: Double) {
        switch phase {
        case .playing where positionNow - positionAtRetry >= Self.minimumProgress:
            self = .recovered
        case .rebuffering, .loading, .seeking:
            self = .refilling
        default:
            self = .frozen
        }
    }
}

/// Bounds the in-place retries of one load. Resets that follow each other
/// within `window` of the last retry count against `maxAttempts`; a source
/// that then stays healthy for longer than the window starts afresh. Each
/// retry waits a little longer than the last.
nonisolated struct LiveSourceRecoveryBudget: Equatable {
    static let maxAttempts = 3
    static let window: Duration = .seconds(60)

    private(set) var attempts = 0
    private var lastAttempt: ContinuousClock.Instant?

    /// Admits another retry at `now`, returning the backoff before it, or nil
    /// when the budget is spent and the channel has to be retuned.
    mutating func admit(at now: ContinuousClock.Instant) -> Duration? {
        if let lastAttempt, now - lastAttempt > Self.window {
            attempts = 0
        }
        guard attempts < Self.maxAttempts else { return nil }
        attempts += 1
        lastAttempt = now
        return Self.backoff(forAttempt: attempts)
    }

    /// 1 s, 2 s, 4 s.
    static func backoff(forAttempt attempt: Int) -> Duration {
        .seconds(1 << max(0, attempt - 1))
    }
}
