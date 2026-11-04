//
//  HueSyncMachine.swift
//  Lume
//
//  The lifecycle of Hue light sync as one explicit state. Pure: the
//  controller feeds events in and performs the effects; every bridge call,
//  the stream and the tick loop live outside.
//
//  Each session has a `RequestToken`. A reply carrying another token belongs
//  to a session that already ended and is ignored, so a slow bridge or a
//  stream failing after a stop can't touch the next session.
//
//  A close (stream ended, area stopped, lights restored) always runs to the
//  end before the next session opens, so a session never snapshots lamps
//  still showing the previous stream. A start that arrives meanwhile waits in
//  the state (`then:`), not in a chain of tasks.
//

import Foundation

nonisolated struct HueSyncMachine: Equatable {
    /// The level and motion the session runs at; retargeted without reopening.
    struct Config: Equatable {
        var intensity: HueIntensity
        var reduceMotion: Bool
    }

    /// How a session ended, for the published state while idle.
    enum Outcome: Equatable {
        /// Another app or a Sync Box streams to the area; it was left alone.
        case areaInUse
        case failed(HueSyncError)
    }

    /// Setup's result. `.notConfigured` (no pairing, keys or area) ends
    /// quietly.
    enum OpenResult: Equatable {
        case ready
        case notConfigured
        case areaInUse
        case failed(HueSyncError)
    }

    enum State: Equatable {
        case idle(last: Outcome?)
        /// Putting back lamps a crash left in stream colours.
        case restoringLeftover(RequestToken, then: Config?)
        /// Reading the area, snapshotting the lights and opening the area.
        case opening(RequestToken, Config)
        /// The area is open; the stream handshake is running.
        case connecting(RequestToken, Config)
        /// `unavailable` holds the source's reason it has no frames; the
        /// lamps keep their last colours.
        case streaming(RequestToken, Config, unavailable: HueFrameUnavailableReason?)
        /// Stopped while setup was still running: the close waits for it.
        case abandoningOpen(RequestToken, outcome: Outcome?, then: Config?)
        /// Stream closed, area stopping, lights restoring.
        case closing(RequestToken, outcome: Outcome?, then: Config?)
    }

    enum Event: Equatable {
        /// Open a session, or retarget the running one.
        case start(Config)
        case stop
        /// At launch: lamps a crash left behind.
        case restoreLeftover
        case leftoverRestored(RequestToken)
        case opened(RequestToken, OpenResult)
        case streamReady(RequestToken)
        case streamFailed(RequestToken, HueStreamTransportError)
        case closed(RequestToken)
        /// The current source's frame availability, from the tick.
        case frames(unavailable: HueFrameUnavailableReason?)
    }

    enum Effect: Equatable {
        case open(RequestToken, Config)
        /// Retarget the running session's sampler.
        case apply(Config)
        case connect(RequestToken)
        case startTicks
        /// Stop ticking and cancel the stream at once, then stop the area and
        /// restore the lights; answers `.closed`.
        case close(RequestToken)
        case restoreLeftover(RequestToken)
    }

    private(set) var state: State = .idle(last: nil)

    /// The token of the session `effect`s should be performed for, if it is
    /// still the one setting up. Setup checks this after every await.
    func isOpening(_ token: RequestToken) -> Bool {
        if case let .opening(current, _) = state { return current == token }
        return false
    }

    func isStreaming(_ token: RequestToken) -> Bool {
        if case let .streaming(current, _, _) = state { return current == token }
        return false
    }

    /// A session is set up or running — not idle, restoring or closing.
    var isActive: Bool {
        switch state {
        case .opening, .connecting, .streaming: true
        case .idle, .restoringLeftover, .abandoningOpen, .closing: false
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .start(config):
            start(config)
        case .stop:
            stop()
        case .restoreLeftover, .leftoverRestored:
            restore(event)
        case let .opened(token, result):
            opened(token, result)
        case .streamReady, .streamFailed, .frames:
            stream(event)
        case let .closed(token):
            closed(token)
        }
    }

    private mutating func restore(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .restoreLeftover):
            // Only with nothing else going on.
            let token = RequestToken()
            state = .restoringLeftover(token, then: nil)
            return [.restoreLeftover(token)]
        case let (.restoringLeftover(current, then), .leftoverRestored(token)) where current == token:
            return settle(then: then, outcome: nil)
        default:
            return []
        }
    }

    private mutating func stream(_ event: Event) -> [Effect] {
        switch (state, event) {
        case let (.connecting(current, config), .streamReady(token)) where current == token:
            state = .streaming(token, config, unavailable: nil)
            return [.startTicks]
        case let (.connecting(current, _), .streamFailed(token, error)) where current == token,
             let (.streaming(current, _, _), .streamFailed(token, error)) where current == token:
            return close(token, outcome: .failed(.stream(error)), then: nil)
        case let (.streaming(token, config, _), .frames(unavailable)):
            state = .streaming(token, config, unavailable: unavailable)
            return []
        default:
            // A reply from an ended session.
            return []
        }
    }

    private mutating func closed(_ token: RequestToken) -> [Effect] {
        guard case let .closing(current, outcome, then) = state, current == token else { return [] }
        return settle(then: then, outcome: outcome)
    }

    /// Opens from idle, retargets a running session, or waits behind a
    /// restore or close.
    private mutating func start(_ config: Config) -> [Effect] {
        switch state {
        case .idle:
            return open(config)
        case let .opening(token, _):
            state = .opening(token, config)
        case let .connecting(token, _):
            state = .connecting(token, config)
        case let .streaming(token, _, unavailable):
            state = .streaming(token, config, unavailable: unavailable)
        case let .restoringLeftover(token, _):
            state = .restoringLeftover(token, then: config)
            return []
        case let .abandoningOpen(token, outcome, _):
            state = .abandoningOpen(token, outcome: outcome, then: config)
            return []
        case let .closing(token, outcome, _):
            state = .closing(token, outcome: outcome, then: config)
            return []
        }
        return [.apply(config)]
    }

    /// Setup still running is waited for; a queued start is dropped.
    private mutating func stop() -> [Effect] {
        switch state {
        case .idle:
            break
        case let .opening(token, _):
            state = .abandoningOpen(token, outcome: nil, then: nil)
        case let .connecting(token, _), let .streaming(token, _, _):
            return close(token, outcome: nil, then: nil)
        case let .restoringLeftover(token, _):
            state = .restoringLeftover(token, then: nil)
        case let .abandoningOpen(token, outcome, _):
            state = .abandoningOpen(token, outcome: outcome, then: nil)
        case let .closing(token, outcome, _):
            state = .closing(token, outcome: outcome, then: nil)
        }
        return []
    }

    private mutating func opened(_ token: RequestToken, _ result: OpenResult) -> [Effect] {
        switch state {
        case let .opening(current, config) where current == token:
            switch result {
            case .ready:
                state = .connecting(token, config)
                return [.connect(token)]
            case .notConfigured:
                return close(token, outcome: nil, then: nil)
            case .areaInUse:
                return close(token, outcome: .areaInUse, then: nil)
            case let .failed(error):
                return close(token, outcome: .failed(error), then: nil)
            }
        case let .abandoningOpen(current, outcome, then) where current == token:
            return close(token, outcome: outcome, then: then)
        default:
            // A reply from an ended session.
            return []
        }
    }

    private mutating func open(_ config: Config) -> [Effect] {
        let token = RequestToken()
        state = .opening(token, config)
        return [.open(token, config)]
    }

    private mutating func close(_ token: RequestToken, outcome: Outcome?, then: Config?) -> [Effect] {
        state = .closing(token, outcome: outcome, then: then)
        return [.close(token)]
    }

    /// After a close or restore: the queued start, else idle.
    private mutating func settle(then: Config?, outcome: Outcome?) -> [Effect] {
        if let then { return open(then) }
        state = .idle(last: outcome)
        return []
    }
}

// MARK: - Published state

nonisolated extension HueSyncMachine.State {
    /// What the UI shows. A queued start reads as connecting; a close shows
    /// how the session ended.
    var published: HueSyncState {
        switch self {
        case let .idle(last), let .closing(_, last, nil), let .abandoningOpen(_, last, nil):
            switch last {
            case nil: .idle
            case .areaInUse: .areaInUse
            case let .failed(error): .error(error)
            }
        case .restoringLeftover(_, nil):
            .idle
        case .opening, .connecting, .restoringLeftover, .closing, .abandoningOpen:
            .connecting
        case let .streaming(_, _, unavailable):
            unavailable.map(HueSyncState.unavailable) ?? .streaming
        }
    }

    /// For the diagnostic journal: no tokens, no addresses.
    var logName: String {
        switch self {
        case let .idle(last): last.map { "idle(\($0.logName))" } ?? "idle"
        case let .restoringLeftover(_, then): "restoringLeftover" + (then == nil ? "" : " → start")
        case .opening: "opening"
        case .connecting: "connecting"
        case let .streaming(_, _, unavailable): unavailable.map { "streaming(no frames: \($0))" } ?? "streaming"
        case let .abandoningOpen(_, _, then): "abandoningOpen" + (then == nil ? "" : " → start")
        case let .closing(_, outcome, then):
            "closing" + (outcome.map { "(\($0.logName))" } ?? "") + (then == nil ? "" : " → start")
        }
    }
}

nonisolated extension HueSyncMachine.Outcome {
    var logName: String {
        switch self {
        case .areaInUse: "area in use"
        case let .failed(error): "\(error)"
        }
    }
}
