//
//  HueSyncMachineTests.swift
//  LumeTests
//
//  The Hue sync lifecycle as pure transitions: stop mid-setup, a start
//  queued behind a close, stale replies from ended sessions, and what the UI
//  is shown at each step.
//

@testable import Lume
import Testing

struct HueSyncMachineTests {
    private static let normal = HueSyncMachine.Config(intensity: .moderate, reduceMotion: false)
    private static let intense = HueSyncMachine.Config(intensity: .intense, reduceMotion: true)

    /// Starts a session and returns its token.
    private func opening(_ machine: inout HueSyncMachine) throws -> RequestToken {
        let effects = machine.handle(.start(Self.normal))
        guard case let .open(token, _) = try #require(effects.first) else {
            Issue.record("expected open, got \(effects)")
            throw CancellationError()
        }
        return token
    }

    private func streaming(_ machine: inout HueSyncMachine) throws -> RequestToken {
        let token = try opening(&machine)
        #expect(machine.handle(.opened(token, .ready)) == [.connect(token)])
        #expect(machine.handle(.streamReady(token)) == [.startTicks])
        return token
    }

    @Test func `a session opens, connects and streams`() throws {
        var machine = HueSyncMachine()
        let token = try opening(&machine)
        #expect(machine.state.published == .connecting)
        #expect(machine.isOpening(token))
        _ = machine.handle(.opened(token, .ready))
        #expect(machine.state.published == .connecting)
        _ = machine.handle(.streamReady(token))
        #expect(machine.state.published == .streaming)
        #expect(machine.isStreaming(token))
    }

    @Test func `stopping a streaming session closes it, then idles`() throws {
        var machine = HueSyncMachine()
        let token = try streaming(&machine)
        #expect(machine.handle(.stop) == [.close(token)])
        #expect(!machine.isActive)
        #expect(machine.handle(.closed(token)) == [])
        #expect(machine.state == .idle(last: nil))
    }

    @Test func `a stop during setup waits for setup, then closes`() throws {
        var machine = HueSyncMachine()
        let token = try opening(&machine)
        #expect(machine.handle(.stop) == [])
        #expect(!machine.isOpening(token), "setup must see it is no longer wanted")
        #expect(machine.handle(.opened(token, .ready)) == [.close(token)])
        #expect(machine.handle(.closed(token)) == [])
        #expect(machine.state.published == .idle)
    }

    @Test func `a start during a close opens a new session once the close ends`() throws {
        var machine = HueSyncMachine()
        let first = try streaming(&machine)
        _ = machine.handle(.stop)
        #expect(machine.handle(.start(Self.intense)) == [], "no second session while lamps restore")
        #expect(machine.state.published == .connecting)
        let effects = machine.handle(.closed(first))
        guard case let .open(second, config) = try #require(effects.first) else {
            Issue.record("expected open, got \(effects)")
            return
        }
        #expect(second != first)
        #expect(config == Self.intense)
    }

    @Test func `stop then start then stop during a close leaves it idle`() throws {
        var machine = HueSyncMachine()
        let token = try streaming(&machine)
        _ = machine.handle(.stop)
        _ = machine.handle(.start(Self.normal))
        _ = machine.handle(.stop)
        #expect(machine.handle(.closed(token)) == [])
        #expect(machine.state == .idle(last: nil))
    }

    @Test func `a start while running retargets without reopening`() throws {
        var machine = HueSyncMachine()
        let token = try streaming(&machine)
        #expect(machine.handle(.start(Self.intense)) == [.apply(Self.intense)])
        #expect(machine.isStreaming(token))
    }

    @Test func `replies from an ended session are ignored`() throws {
        var machine = HueSyncMachine()
        let old = try streaming(&machine)
        _ = machine.handle(.stop)
        _ = machine.handle(.closed(old))
        let new = try opening(&machine)
        #expect(machine.handle(.streamFailed(old, .connectionLost)) == [])
        #expect(machine.handle(.opened(old, .ready)) == [])
        #expect(machine.handle(.closed(old)) == [])
        #expect(machine.isOpening(new))
    }

    @Test func `area in use and failures are shown after the close`() throws {
        var machine = HueSyncMachine()
        let token = try opening(&machine)
        #expect(machine.handle(.opened(token, .areaInUse)) == [.close(token)])
        #expect(machine.state.published == .areaInUse)
        _ = machine.handle(.closed(token))
        #expect(machine.state.published == .areaInUse)

        let next = try opening(&machine)
        _ = machine.handle(.opened(next, .ready))
        _ = machine.handle(.streamFailed(next, .handshakeFailed))
        _ = machine.handle(.closed(next))
        #expect(machine.state.published == .error(.stream(.handshakeFailed)))
    }

    @Test func `missing frames show as unavailable and clear again`() throws {
        var machine = HueSyncMachine()
        _ = try streaming(&machine)
        _ = machine.handle(.frames(unavailable: .unsupportedContent))
        #expect(machine.state.published == .unavailable(.unsupportedContent))
        _ = machine.handle(.frames(unavailable: nil))
        #expect(machine.state.published == .streaming)
    }

    @Test func `the launch restore runs only when idle and holds a start`() throws {
        var machine = HueSyncMachine()
        let effects = machine.handle(.restoreLeftover)
        guard case let .restoreLeftover(token) = try #require(effects.first) else {
            Issue.record("expected restore, got \(effects)")
            return
        }
        #expect(machine.handle(.restoreLeftover) == [], "one restore at a time")
        #expect(machine.handle(.start(Self.normal)) == [])
        let after = machine.handle(.leftoverRestored(token))
        guard case .open = try #require(after.first) else {
            Issue.record("expected the held start to open, got \(after)")
            return
        }

        var running = HueSyncMachine()
        _ = try streaming(&running)
        #expect(running.handle(.restoreLeftover) == [], "never under a running session")
    }

    @Test func `a stop while idle does nothing`() {
        var machine = HueSyncMachine()
        #expect(machine.handle(.stop) == [])
        #expect(machine.state == .idle(last: nil))
    }
}
