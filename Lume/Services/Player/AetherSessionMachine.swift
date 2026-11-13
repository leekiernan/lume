//
//  AetherSessionMachine.swift
//  Lume
//
//  One AetherEngine player's stream lifecycle as one explicit state. Pure: the
//  coordinator feeds the engine's callbacks in as events and performs the
//  effects; the bridge, tasks and clocks live outside.
//
//  What it owns is only what is Aether's: when a load counts as started, an
//  unrequested pause on live TV, the in-place recovery of a parked live
//  source, and where a failure goes. Everything shared stays where it is —
//  the startup deadline and QoE in `PlaybackStartupSupervisor`, the reconnect
//  budget in `PlaybackRetryController`, scrobbles and saves in
//  `PlaybackSessionMachine` (fed by `report`) — and is driven by effects.
//
//  Every load has a `RequestToken`; so does every timer. A reply or a timer
//  carrying another token belongs to something already superseded and is
//  ignored, so nothing needs cancelling.
//
//  A load never stops the engine: the next one replaces the running one in
//  place (`prepareForReplacement`). A stop returns the TV to the menu's
//  display mode and the next stream re-syncs the HDMI link twice (~2.9 s
//  each); replacing keeps the mode, the last picture and a Picture in Picture
//  window.
//

import Foundation

nonisolated struct AetherSessionMachine: Equatable {
    /// The engine's playback phase, mirrored from the bridge's
    /// `LumeAetherPhase` so this file doesn't import it.
    enum EnginePhase: Equatable {
        case idle
        case loading
        case playing
        case paused
        case seeking
        case rebuffering
        case stalled
        case ended
        case failed
    }

    enum LoadKind: Equatable {
        /// The player's first stream.
        case open
        /// Another title, or another catch-up segment, loaded in place.
        case replace
        /// The same stream again after a drop, maybe at a fresh URL.
        case reconnect
        /// The viewer pressed Try Again.
        case retry

        var isNewStream: Bool {
            self == .open || self == .replace
        }
    }

    struct Load: Equatable {
        let token: RequestToken
        let kind: LoadKind
        let isLive: Bool
        /// The startup window, already raised to the live-join floor.
        let startupTimeout: TimeInterval
        /// `load` returned: the engine has the item, and time reports are
        /// about it rather than the stream it replaced.
        var returned = false
        var hasStartedPlayback = false
        /// Startup checkpoints the engine had completed at the last deadline.
        var checkpoints = 0
        var rearms = 0
    }

    /// Where a failure goes. The host decides what "the next engine" means at
    /// that moment (an AirPlay route can change the answer).
    enum Route: Equatable {
        /// Show the failure; nothing reloads behind it.
        case overlay
        /// This engine can't play the source: the next engine, or the overlay
        /// when none is left.
        case nextEngine
        /// The stream never played: the next engine, or a reconnect when
        /// none is left.
        case nextEngineOrReconnect
        /// The stream played: back through the reconnect budget.
        case reconnect(freshURL: Bool)
        /// A live channel whose source is gone: a fresh load of it.
        case retune
    }

    enum State: Equatable {
        case idle
        case active(Load)
        case failed(Load, AetherEngineFailure, Route)
    }

    enum PauseSource: Equatable {
        /// The overlay, the remote, Now Playing or leaving the app.
        case viewer
        /// A Picture in Picture window's own controls.
        case pictureInPicture
    }

    enum Intent: Equatable {
        case play
        case pause(PauseSource)
    }

    enum Timer: Equatable {
        /// Asks a live channel the engine paused by itself to play again.
        case reassertPlay
        /// The backoff before an in-place retry of a parked live source.
        case liveRetry
        /// Whether the picture moved again after an accepted retry.
        case liveCheck
    }

    /// The in-place recovery of a parked live source.
    enum LiveRecovery: Equatable {
        case backingOff(RequestToken)
        /// The retry was asked for; waiting for the engine's answer.
        case retrying(RequestToken)
        /// The engine took it; watching whether the picture moves.
        case checking(RequestToken, positionAtRetry: Double, graceUsed: Bool)
    }

    struct UnrequestedPause: Equatable {
        let token: RequestToken
        var elapsed: Duration = .zero
    }

    /// What a step means for `PlaybackRetryController`'s budget.
    enum RetryStep: Equatable {
        case newStream
        case reconnect
        case manualRetry
        /// Playing again: a later, unrelated drop gets a full budget.
        case healthy
        case terminalFailure
        case teardown
    }

    enum Event: Equatable {
        /// `waitsForLiveJoin`: a live load on the standard join profile, which
        /// can't start within a short window.
        case load(LoadKind, isLive: Bool, startupTimeout: TimeInterval, waitsForLiveJoin: Bool)
        case loadReturned(RequestToken)
        /// The load threw, or the engine couldn't be built.
        case loadFailed(RequestToken, AetherEngineFailure)
        /// The engine reported a failure (or dropped the audio) mid-load.
        case engineFailed(AetherEngineFailure)
        case phase(EnginePhase)
        /// The startup window ran out, with the checkpoints done so far.
        case startupDeadline(RequestToken, checkpoints: Int)
        case request(Intent)
        case pictureInPicture(active: Bool)
        case liveSourceReset(now: ContinuousClock.Instant)
        case timerFired(Timer, RequestToken)
        case liveRetryAnswered(RequestToken, accepted: Bool, position: Double)
        case liveSourceChecked(RequestToken, position: Double)
        case tearDown
    }

    enum Effect: Equatable {
        /// Replace the running item in place; never a stop.
        case prepareForReplacement
        case startLoad(RequestToken)
        /// After `load` returned: sidecar subtitles, Picture in Picture,
        /// tracks.
        case finishLoad(RequestToken)
        case stop
        case play
        case pause
        /// A new startup window (`PlaybackStartupSupervisor.begin`).
        case beginStartup(RequestToken, timeout: TimeInterval)
        /// The engine is still working through its checkpoints: roll the
        /// window (`PlaybackStartupSupervisor.arm`).
        case rearmStartup(RequestToken, timeout: TimeInterval)
        case startupSucceeded
        case startupFailed
        case endStartup
        case retry(RetryStep)
        case stall(began: Bool)
        /// Answer with `timerFired(timer, token)` after `delay`.
        case schedule(Timer, RequestToken, after: Duration)
        /// Ask the engine to pick the parked source up again; answer with
        /// `liveRetryAnswered`.
        case retryLiveSourceInPlace(RequestToken)
        /// Answer with `liveSourceChecked` and the playhead.
        case checkLiveSource(RequestToken)
        case route(AetherEngineFailure, Route)
    }

    /// Aether holds the first live playlist until ~18 s of a 1x origin has
    /// arrived and gives up by itself after 30 s; a shorter window kills a
    /// healthy join.
    static let liveJoinStartupFloor: TimeInterval = 35
    /// A slow origin can spend most of a window in stream analysis; a load
    /// still completing checkpoints gets this many more windows.
    static let maxStartupRearms = 2
    static let reassertPlayInterval: Duration = .seconds(3)
    /// How long a live channel may stay paused on its own before it goes to
    /// the reconnect path. The engine gives up on a quiet source well within
    /// this; it only bounds one that neither recovers nor gives up.
    static let unrequestedPauseWindow: Duration = .seconds(20)
    static let liveCheckWindow: Duration = .seconds(20)
    /// Granted once when the check finds the engine refilling: the source came
    /// back late and the picture is about to move.
    static let liveRefillGrace: Duration = .seconds(10)

    private(set) var state: State = .idle
    private(set) var intent = Intent.play
    private(set) var lastPhase = EnginePhase.idle
    private(set) var isPictureInPictureActive = false
    /// Whether this stream played in an earlier load. A reconnect that fails
    /// before its first frame is still a drop of a stream that played.
    private(set) var hasPlayedStream = false
    private(set) var unrequestedPause: UnrequestedPause?
    private(set) var liveRecovery: LiveRecovery?
    private var liveBudget = LiveSourceRecoveryBudget()
    private var isInStall = false

    // MARK: - Reading

    var load: Load? {
        switch state {
        case .idle: nil
        case let .active(load), let .failed(load, _, _): load
        }
    }

    var hasStartedPlayback: Bool {
        load?.hasStartedPlayback == true
    }

    /// Time reports describe the current stream: an in-place swap has no
    /// remount to cut the previous item's last ticks.
    var acceptsTime: Bool {
        guard case let .active(load) = state else { return false }
        return load.returned || load.hasStartedPlayback
    }

    var isPlaying: Bool {
        guard case .active = state else { return false }
        return lastPhase == .playing && unrequestedPause == nil
    }

    var isBuffering: Bool {
        switch state {
        case .idle: return false
        case let .failed(_, _, route): return route != .overlay
        case let .active(load):
            if unrequestedPause != nil { return true }
            switch liveRecovery {
            case .backingOff, .retrying: return true
            case .checking, nil: break
            }
            switch lastPhase {
            case .playing, .paused: return false
            case .loading, .seeking, .rebuffering, .stalled: return true
            case .idle, .ended, .failed: return !load.hasStartedPlayback
            }
        }
    }

    /// What `PlaybackSessionMachine` hears. An unrequested pause, a parked
    /// source and a stall all read as buffering: no pause scrobble, no save.
    var report: PlaybackSessionMachine.EngineReport {
        let overlay = if case .failed(_, _, .overlay) = state { true } else { false }
        return .init(started: hasStartedPlayback, buffering: isBuffering, playing: isPlaying, failed: overlay)
    }

    func isCurrent(_ token: RequestToken) -> Bool {
        load?.token == token
    }

    /// Where `failure` goes. `hasPlayed`: this stream showed a frame, in this
    /// load or an earlier one.
    static func route(_ failure: AetherEngineFailure, hasPlayed: Bool) -> Route {
        switch (failure, hasPlayed) {
        case (.notFound, _): .overlay
        case (.unsupported, false): .nextEngine
        case (.unsupported, true): .overlay
        case (.sourceEnded, true): .retune
        case (.unauthorized, true): .reconnect(freshURL: true)
        case (_, false): .nextEngineOrReconnect
        case (_, true): .reconnect(freshURL: false)
        }
    }

    // MARK: - Transitions

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .load(kind, isLive, timeout, waitsForLiveJoin):
            start(kind, isLive: isLive, timeout: waitsForLiveJoin ? max(timeout, Self.liveJoinStartupFloor) : timeout)
        case .loadReturned, .loadFailed:
            loadReply(event)
        case let .engineFailed(failure):
            fail(failure)
        case let .phase(phase):
            enginePhase(phase)
        case let .startupDeadline(token, checkpoints):
            startupDeadline(token, checkpoints: checkpoints)
        case let .request(intent):
            request(intent)
        case let .pictureInPicture(active):
            pictureInPicture(active)
        case let .timerFired(.reassertPlay, token):
            reassertPlay(token)
        case .liveSourceReset, .timerFired, .liveRetryAnswered, .liveSourceChecked:
            liveSource(event)
        case .tearDown:
            tearDown()
        }
    }

    private mutating func start(_ kind: LoadKind, isLive: Bool, timeout: TimeInterval) -> [Effect] {
        var effects: [Effect] = state == .idle ? [] : [.prepareForReplacement]
        effects += clearRecovery()
        if kind.isNewStream { hasPlayedStream = false }
        intent = .play
        lastPhase = .idle
        liveBudget = LiveSourceRecoveryBudget()
        let load = Load(token: RequestToken(), kind: kind, isLive: isLive, startupTimeout: timeout)
        state = .active(load)
        let step: RetryStep = switch kind {
        case .open, .replace: .newStream
        case .reconnect: .reconnect
        case .retry: .manualRetry
        }
        return effects + [.retry(step), .beginStartup(load.token, timeout: timeout), .startLoad(load.token)]
    }

    private mutating func loadReply(_ event: Event) -> [Effect] {
        guard case var .active(load) = state else { return [] }
        switch event {
        case let .loadReturned(token) where token == load.token:
            load.returned = true
            state = .active(load)
            return [.finishLoad(token)]
        case let .loadFailed(token, failure) where token == load.token:
            return fail(failure)
        default:
            return []
        }
    }

    private mutating func fail(_ failure: AetherEngineFailure) -> [Effect] {
        guard case let .active(load) = state else { return [] }
        let route = Self.route(failure, hasPlayed: hasPlayedStream || load.hasStartedPlayback)
        state = .failed(load, failure, route)
        var effects = clearRecovery()
        if !load.hasStartedPlayback { effects.append(.startupFailed) }
        switch route {
        case .overlay:
            effects.append(.retry(.terminalFailure))
        case .nextEngine, .nextEngineOrReconnect:
            // The next engine starts from a quiet session.
            effects.append(.stop)
        case .reconnect, .retune:
            break
        }
        return effects + [.route(failure, route)]
    }

    private mutating func enginePhase(_ phase: EnginePhase) -> [Effect] {
        guard case var .active(load) = state else { return [] }
        lastPhase = phase
        switch phase {
        case .playing:
            var effects: [Effect] = []
            unrequestedPause = nil
            effects += endStall()
            if !load.hasStartedPlayback {
                load.hasStartedPlayback = true
                hasPlayedStream = true
                state = .active(load)
                effects.append(.startupSucceeded)
            }
            return effects + [.retry(.healthy)]
        case .paused:
            if load.isLive, load.hasStartedPlayback, intent == .play, !isPictureInPictureActive {
                return beginUnrequestedPause()
            }
            return endStall()
        case .rebuffering, .stalled:
            return load.hasStartedPlayback ? beginStall() : []
        case .ended:
            // Terminal: nothing revives it but a new load. A live channel
            // that ends is a lost source.
            return load.isLive ? fail(.sourceEnded) : endStall()
        case .idle, .loading, .seeking, .failed:
            // A failure arrives with its cause through `engineFailed`.
            return []
        }
    }

    private mutating func startupDeadline(_ token: RequestToken, checkpoints: Int) -> [Effect] {
        guard case var .active(load) = state, load.token == token, !load.hasStartedPlayback else { return [] }
        guard checkpoints > load.checkpoints, load.rearms < Self.maxStartupRearms else {
            return fail(.interrupted)
        }
        load.checkpoints = checkpoints
        load.rearms += 1
        state = .active(load)
        return [.rearmStartup(token, timeout: load.startupTimeout)]
    }

    private mutating func request(_ intent: Intent) -> [Effect] {
        self.intent = intent
        guard case .active = state else { return [] }
        switch intent {
        case .play:
            return [.play]
        case .pause:
            unrequestedPause = nil
            return endStall() + [.pause]
        }
    }

    private mutating func pictureInPicture(_ active: Bool) -> [Effect] {
        isPictureInPictureActive = active
        return []
    }

    // MARK: Unrequested live pause

    /// The engine paused a live channel that was playing: the buffer ran dry
    /// and AVPlayer paused itself, which the engine takes for an outside
    /// command. Shown as buffering; play is asked for again until it moves or
    /// the window runs out.
    private mutating func beginUnrequestedPause() -> [Effect] {
        guard unrequestedPause == nil else { return [.play] }
        let pause = UnrequestedPause(token: RequestToken())
        unrequestedPause = pause
        return beginStall() + [.play, .schedule(.reassertPlay, pause.token, after: Self.reassertPlayInterval)]
    }

    private mutating func reassertPlay(_ token: RequestToken) -> [Effect] {
        guard case .active = state, var pause = unrequestedPause, pause.token == token else { return [] }
        pause.elapsed += Self.reassertPlayInterval
        guard pause.elapsed < Self.unrequestedPauseWindow else {
            unrequestedPause = nil
            return fail(.interrupted)
        }
        unrequestedPause = pause
        let replay: [Effect] = lastPhase == .paused ? [.play] : []
        return replay + [.schedule(.reassertPlay, token, after: Self.reassertPlayInterval)]
    }

    // MARK: Parked live source

    private mutating func liveSource(_ event: Event) -> [Effect] {
        switch event {
        case let .liveSourceReset(now):
            return liveSourceReset(at: now)
        case let .timerFired(.liveRetry, token):
            guard liveRecovery == .backingOff(token) else { return [] }
            liveRecovery = .retrying(token)
            return [.retryLiveSourceInPlace(token)]
        case let .liveRetryAnswered(token, accepted, position):
            guard liveRecovery == .retrying(token) else { return [] }
            guard accepted else {
                liveRecovery = nil
                return fail(.sourceEnded)
            }
            liveRecovery = .checking(token, positionAtRetry: position, graceUsed: false)
            return [.schedule(.liveCheck, token, after: Self.liveCheckWindow)]
        case let .timerFired(.liveCheck, token):
            guard case .checking(token, _, _) = liveRecovery else { return [] }
            return [.checkLiveSource(token)]
        case let .liveSourceChecked(token, position):
            return liveSourceChecked(token, position: position)
        default:
            return []
        }
    }

    private mutating func liveSourceReset(at now: ContinuousClock.Instant) -> [Effect] {
        guard case let .active(load) = state else { return [] }
        guard load.isLive, load.hasStartedPlayback else { return fail(.sourceEnded) }
        switch liveRecovery {
        case .backingOff, .retrying:
            // A retry already queued or under way absorbs further resets.
            return []
        case .checking, nil:
            guard let backoff = liveBudget.admit(at: now) else {
                liveRecovery = nil
                return fail(.sourceEnded)
            }
            let token = RequestToken()
            liveRecovery = .backingOff(token)
            return beginStall() + [.schedule(.liveRetry, token, after: backoff)]
        }
    }

    private mutating func liveSourceChecked(_ token: RequestToken, position: Double) -> [Effect] {
        guard case let .checking(current, positionAtRetry, graceUsed) = liveRecovery, current == token else { return [] }
        switch LiveSourceRecoveryVerdict(phase: lastPhase, positionAtRetry: positionAtRetry, positionNow: position) {
        case .recovered:
            liveRecovery = nil
            return []
        case .refilling where !graceUsed:
            liveRecovery = .checking(token, positionAtRetry: positionAtRetry, graceUsed: true)
            return [.schedule(.liveCheck, token, after: Self.liveRefillGrace)]
        case .refilling, .frozen:
            liveRecovery = nil
            return fail(.sourceEnded)
        }
    }

    // MARK: Teardown and helpers

    private mutating func tearDown() -> [Effect] {
        guard state != .idle else { return [] }
        let effects = clearRecovery()
        state = .idle
        lastPhase = .idle
        return effects + [.stop, .endStartup, .retry(.teardown)]
    }

    /// Ends any recovery under way; their timers are left to fire stale.
    private mutating func clearRecovery() -> [Effect] {
        unrequestedPause = nil
        liveRecovery = nil
        return endStall()
    }

    private mutating func beginStall() -> [Effect] {
        guard !isInStall else { return [] }
        isInStall = true
        return [.stall(began: true)]
    }

    private mutating func endStall() -> [Effect] {
        guard isInStall else { return [] }
        isInStall = false
        return [.stall(began: false)]
    }
}
