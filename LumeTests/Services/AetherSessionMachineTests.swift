//
//  AetherSessionMachineTests.swift
//  LumeTests
//
//  The AetherEngine stream lifecycle, driven through its pure machine: no
//  engine, tasks or clocks.
//

import Foundation
@testable import Lume
import Testing

struct AetherSessionMachineTests {
    private typealias Machine = AetherSessionMachine

    /// A machine with a load under way, and that load's token.
    private func loading(
        _ kind: Machine.LoadKind = .open,
        isLive: Bool = false,
        on machine: Machine = Machine()
    ) -> (Machine, RequestToken) {
        var machine = machine
        _ = machine.handle(.load(kind, isLive: isLive, startupTimeout: 15, waitsForLiveJoin: false))
        return (machine, machine.load!.token)
    }

    /// A machine whose load returned and is playing.
    private func playing(isLive: Bool = false) -> (Machine, RequestToken) {
        var (machine, token) = loading(isLive: isLive)
        _ = machine.handle(.loadReturned(token))
        _ = machine.handle(.phase(.playing))
        return (machine, token)
    }

    private func scheduled(_ effects: [Machine.Effect], _ timer: Machine.Timer) -> RequestToken? {
        for case let .schedule(kind, token, _) in effects where kind == timer {
            return token
        }
        return nil
    }

    // MARK: Loads

    @Test func `the first load starts the engine with a fresh startup window`() throws {
        var machine = Machine()
        let effects = machine.handle(.load(.open, isLive: false, startupTimeout: 15, waitsForLiveJoin: false))
        let token = try #require(machine.load?.token)
        #expect(effects == [.retry(.newStream), .beginStartup(token, timeout: 15), .startLoad(token)])
        #expect(!machine.acceptsTime)
        #expect(machine.report == .init(started: false, buffering: true, playing: false, failed: false))
    }

    @Test func `a live join on the standard profile gets the join floor`() throws {
        var machine = Machine()
        let effects = machine.handle(.load(.open, isLive: true, startupTimeout: 15, waitsForLiveJoin: true))
        #expect(try effects.contains(.beginStartup(#require(machine.load?.token), timeout: Machine.liveJoinStartupFloor)))
    }

    @Test func `another title replaces the stream in place and never stops the engine`() {
        let (machine, _) = playing()
        var next = machine
        let effects = next.handle(.load(.replace, isLive: false, startupTimeout: 15, waitsForLiveJoin: false))
        #expect(effects.first == .prepareForReplacement)
        #expect(!effects.contains(.stop))
        #expect(effects.contains(.retry(.newStream)))
        #expect(!next.hasPlayedStream)
    }

    @Test func `time reports wait for the replacing load to return`() throws {
        var (machine, token) = playing()
        _ = machine.handle(.load(.replace, isLive: false, startupTimeout: 15, waitsForLiveJoin: false))
        #expect(!machine.acceptsTime)
        _ = machine.handle(.loadReturned(token))
        #expect(!machine.acceptsTime)
        _ = try machine.handle(.loadReturned(#require(machine.load?.token)))
        #expect(machine.acceptsTime)
    }

    @Test func `a reconnect keeps the stream's history and the retry budget`() {
        var (machine, _) = playing()
        let effects = machine.handle(.load(.reconnect, isLive: false, startupTimeout: 15, waitsForLiveJoin: false))
        #expect(machine.hasPlayedStream)
        #expect(effects.contains(.retry(.reconnect)))
        // A reconnect failing before its first frame is still a drop.
        let failed = machine.handle(.engineFailed(.interrupted))
        #expect(failed.last == .route(.interrupted, .reconnect(freshURL: false)))
    }

    @Test func `try again refills the budget`() {
        var (machine, _) = loading()
        _ = machine.handle(.engineFailed(.notFound))
        let effects = machine.handle(.load(.retry, isLive: false, startupTimeout: 15, waitsForLiveJoin: false))
        #expect(effects.contains(.retry(.manualRetry)))
    }

    @Test func `a superseded load's reply is ignored`() throws {
        var (machine, old) = loading()
        _ = machine.handle(.load(.replace, isLive: false, startupTimeout: 15, waitsForLiveJoin: false))
        #expect(machine.handle(.loadReturned(old)).isEmpty)
        #expect(machine.handle(.loadFailed(old, .interrupted)).isEmpty)
        #expect(machine.handle(.startupDeadline(old, checkpoints: 0)).isEmpty)
        #expect(try machine.state == .active(#require(machine.load)))
    }

    // MARK: First frame

    @Test func `the first playing phase is the first frame, reported once`() {
        var (machine, token) = loading()
        _ = machine.handle(.loadReturned(token))
        #expect(machine.handle(.phase(.playing)) == [.startupSucceeded, .retry(.healthy)])
        _ = machine.handle(.phase(.paused))
        #expect(machine.handle(.phase(.playing)) == [.retry(.healthy)])
        #expect(machine.report == .init(started: true, buffering: false, playing: true, failed: false))
    }

    @Test func `the startup window rolls while checkpoints advance, up to a cap`() {
        var (machine, token) = loading()
        #expect(machine.handle(.startupDeadline(token, checkpoints: 2)) == [.rearmStartup(token, timeout: 15)])
        #expect(machine.handle(.startupDeadline(token, checkpoints: 3)) == [.rearmStartup(token, timeout: 15)])
        let effects = machine.handle(.startupDeadline(token, checkpoints: 4))
        #expect(effects.contains(.startupFailed))
        #expect(effects.last == .route(.interrupted, .nextEngineOrReconnect))
    }

    @Test func `a load stuck on one checkpoint fails at the first deadline`() {
        var (machine, token) = loading()
        _ = machine.handle(.startupDeadline(token, checkpoints: 1))
        let effects = machine.handle(.startupDeadline(token, checkpoints: 1))
        #expect(effects.last == .route(.interrupted, .nextEngineOrReconnect))
    }

    // MARK: Routing

    @Test func `failures route by cause and by whether the stream played`() {
        #expect(Machine.route(.notFound, hasPlayed: false) == .overlay)
        #expect(Machine.route(.notFound, hasPlayed: true) == .overlay)
        #expect(Machine.route(.unsupported, hasPlayed: false) == .nextEngine)
        #expect(Machine.route(.unsupported, hasPlayed: true) == .overlay)
        #expect(Machine.route(.sourceEnded, hasPlayed: true) == .retune)
        #expect(Machine.route(.unauthorized, hasPlayed: true) == .reconnect(freshURL: true))
        #expect(Machine.route(.overloaded, hasPlayed: true) == .reconnect(freshURL: false))
        #expect(Machine.route(.interrupted, hasPlayed: true) == .reconnect(freshURL: false))
        for failure in [AetherEngineFailure.interrupted, .unauthorized, .overloaded, .sourceEnded] {
            #expect(Machine.route(failure, hasPlayed: false) == .nextEngineOrReconnect)
        }
    }

    @Test func `a failure before the first frame stops the engine for the next one`() {
        var (machine, _) = loading()
        let effects = machine.handle(.engineFailed(.unsupported))
        #expect(effects == [.startupFailed, .stop, .route(.unsupported, .nextEngine)])
    }

    @Test func `a dead stream shows the overlay and ends the retry budget`() {
        var (machine, _) = playing()
        let effects = machine.handle(.engineFailed(.notFound))
        #expect(effects == [.retry(.terminalFailure), .route(.notFound, .overlay)])
        #expect(machine.report.failed)
        // Late callbacks can't revive it.
        #expect(machine.handle(.phase(.playing)).isEmpty)
        #expect(machine.handle(.engineFailed(.interrupted)).isEmpty)
    }

    @Test func `video on demand that ends is not a failure`() {
        var (machine, _) = playing()
        #expect(machine.handle(.phase(.ended)).isEmpty)
    }

    @Test func `a live channel that ends is retuned`() {
        var (machine, _) = playing(isLive: true)
        #expect(machine.handle(.phase(.ended)).last == .route(.sourceEnded, .retune))
    }

    // MARK: Pauses

    @Test func `a viewer's pause on live TV stays a pause`() {
        var (machine, _) = playing(isLive: true)
        #expect(machine.handle(.request(.pause(.viewer))) == [.pause])
        #expect(machine.handle(.phase(.paused)).isEmpty)
        #expect(machine.unrequestedPause == nil)
        #expect(machine.report == .init(started: true, buffering: false, playing: false, failed: false))
    }

    @Test func `a pause from a Picture in Picture window is the window's own`() {
        var (machine, _) = playing(isLive: true)
        _ = machine.handle(.pictureInPicture(active: true))
        #expect(machine.handle(.phase(.paused)).isEmpty)
        #expect(machine.unrequestedPause == nil)
    }

    @Test func `video on demand keeps the engine's pause`() {
        var (machine, _) = playing()
        #expect(machine.handle(.phase(.paused)).isEmpty)
    }

    @Test func `a live pause nobody asked for is a stall, and play is asked for again`() throws {
        var (machine, _) = playing(isLive: true)
        let effects = machine.handle(.phase(.paused))
        let timer = try #require(scheduled(effects, .reassertPlay))
        #expect(effects == [.stall(began: true), .play, .schedule(.reassertPlay, timer, after: Machine.reassertPlayInterval)])
        // Buffering, not paused: no pause scrobble, no save.
        #expect(machine.report == .init(started: true, buffering: true, playing: false, failed: false))
        #expect(machine.handle(.timerFired(.reassertPlay, timer)) == [.play, .schedule(.reassertPlay, timer, after: Machine.reassertPlayInterval)])
        #expect(machine.handle(.phase(.playing)) == [.stall(began: false), .retry(.healthy)])
        #expect(machine.unrequestedPause == nil)
        // The finished recovery's timer is stale.
        #expect(machine.handle(.timerFired(.reassertPlay, timer)).isEmpty)
    }

    @Test func `a live channel that stays paused by itself goes to the reconnect path`() throws {
        var (machine, _) = playing(isLive: true)
        let timer = try #require(scheduled(machine.handle(.phase(.paused)), .reassertPlay))
        var last: [Machine.Effect] = []
        for _ in 0 ..< 7 {
            last = machine.handle(.timerFired(.reassertPlay, timer))
        }
        #expect(last.last == .route(.interrupted, .reconnect(freshURL: false)))
    }

    // MARK: Parked live source

    private let now = ContinuousClock.Instant.now

    /// A playing live channel whose source just parked, and the retry timer.
    private func parked() throws -> (Machine, RequestToken) {
        var (machine, _) = playing(isLive: true)
        let effects = machine.handle(.liveSourceReset(now: now))
        let timer = try #require(scheduled(effects, .liveRetry))
        #expect(effects == [.stall(began: true), .schedule(.liveRetry, timer, after: .seconds(1))])
        return (machine, timer)
    }

    @Test func `a parked source is retried in place and checked`() throws {
        var (machine, timer) = try parked()
        #expect(machine.report.buffering)
        #expect(machine.handle(.timerFired(.liveRetry, timer)) == [.retryLiveSourceInPlace(timer)])
        #expect(machine.handle(.liveRetryAnswered(timer, accepted: true, position: 100)) == [.schedule(.liveCheck, timer, after: Machine.liveCheckWindow)])
        _ = machine.handle(.phase(.playing))
        #expect(machine.handle(.timerFired(.liveCheck, timer)) == [.checkLiveSource(timer)])
        #expect(machine.handle(.liveSourceChecked(timer, position: 115)).isEmpty)
        #expect(machine.liveRecovery == nil)
        #expect(try machine.state == .active(#require(machine.load)))
    }

    @Test func `resets during a queued retry are absorbed`() throws {
        var (machine, _) = try parked()
        #expect(machine.handle(.liveSourceReset(now: now + .seconds(1))).isEmpty)
    }

    @Test func `a retry the engine refuses retunes the channel`() throws {
        var (machine, timer) = try parked()
        _ = machine.handle(.timerFired(.liveRetry, timer))
        #expect(machine.handle(.liveRetryAnswered(timer, accepted: false, position: 0)).last == .route(.sourceEnded, .retune))
    }

    @Test func `a refilling source gets one grace period, then a frozen one is retuned`() throws {
        var (machine, timer) = try parked()
        _ = machine.handle(.timerFired(.liveRetry, timer))
        _ = machine.handle(.liveRetryAnswered(timer, accepted: true, position: 100))
        _ = machine.handle(.phase(.rebuffering))
        #expect(machine.handle(.liveSourceChecked(timer, position: 100)) == [.schedule(.liveCheck, timer, after: Machine.liveRefillGrace)])
        #expect(machine.handle(.liveSourceChecked(timer, position: 100)).last == .route(.sourceEnded, .retune))
    }

    @Test func `a playing phase with a stuck clock is frozen`() throws {
        var (machine, timer) = try parked()
        _ = machine.handle(.timerFired(.liveRetry, timer))
        _ = machine.handle(.liveRetryAnswered(timer, accepted: true, position: 100))
        _ = machine.handle(.phase(.playing))
        #expect(machine.handle(.liveSourceChecked(timer, position: 100.5)).last == .route(.sourceEnded, .retune))
    }

    @Test func `in-place retries run out after three in a row`() throws {
        var (machine, _) = playing(isLive: true)
        for attempt in 0 ..< 3 {
            let timer = try #require(scheduled(machine.handle(.liveSourceReset(now: now + .seconds(attempt * 10))), .liveRetry))
            _ = machine.handle(.timerFired(.liveRetry, timer))
            _ = machine.handle(.liveRetryAnswered(timer, accepted: true, position: 0))
        }
        #expect(machine.handle(.liveSourceReset(now: now + .seconds(30))).last == .route(.sourceEnded, .retune))
    }

    @Test func `a reset before the first frame is a lost source`() {
        var (machine, _) = loading(isLive: true)
        #expect(machine.handle(.liveSourceReset(now: now)).last == .route(.sourceEnded, .nextEngineOrReconnect))
    }

    // MARK: Teardown

    @Test func `teardown stops the engine and retires every timer`() throws {
        var (machine, timer) = try parked()
        #expect(machine.handle(.tearDown) == [.stall(began: false), .stop, .endStartup, .retry(.teardown)])
        #expect(machine.handle(.timerFired(.liveRetry, timer)).isEmpty)
        #expect(machine.handle(.phase(.playing)).isEmpty)
        #expect(machine.report == .init(started: false, buffering: false, playing: false, failed: false))
    }
}

struct LiveSourceRecoveryTests {
    private let start = ContinuousClock.Instant.now

    @Test func `retries back off and run out after three`() {
        var budget = LiveSourceRecoveryBudget()
        #expect(budget.admit(at: start) == .seconds(1))
        #expect(budget.admit(at: start + .seconds(10)) == .seconds(2))
        #expect(budget.admit(at: start + .seconds(20)) == .seconds(4))
        #expect(budget.admit(at: start + .seconds(30)) == nil)
    }

    @Test func `a source that stays up longer than the window starts afresh`() {
        var budget = LiveSourceRecoveryBudget()
        _ = budget.admit(at: start)
        _ = budget.admit(at: start + .seconds(10))
        _ = budget.admit(at: start + .seconds(20))
        #expect(budget.admit(at: start + .seconds(81)) == .seconds(1))
        #expect(budget.attempts == 1)
    }

    private func verdict(_ phase: AetherSessionMachine.EnginePhase, moved: Double) -> LiveSourceRecoveryVerdict {
        LiveSourceRecoveryVerdict(phase: phase, positionAtRetry: 100, positionNow: 100 + moved)
    }

    @Test func `recovery needs a moving picture, not just the playing phase`() {
        #expect(verdict(.playing, moved: 15) == .recovered)
        #expect(verdict(.playing, moved: 0.5) == .frozen)
        #expect(verdict(.paused, moved: 15) == .frozen)
        #expect(verdict(.stalled, moved: 0) == .frozen)
        #expect(verdict(.rebuffering, moved: 0) == .refilling)
        #expect(verdict(.loading, moved: 0) == .refilling)
    }
}
