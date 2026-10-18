import Foundation
@testable import Lume
import Testing

struct PlaybackStartupStateTests {
    @Test func `replacement and teardown invalidate old deadlines`() {
        var state = PlaybackStartupState()
        let retired = state.begin()
        let current = state.begin()
        #expect(!state.canExpire(retired))
        #expect(state.canExpire(current))
        state.end()
        #expect(!state.canExpire(current))
    }

    @Test func `failure is terminal until an explicit new load`() {
        var state = PlaybackStartupState()
        _ = state.begin()
        let started = state.started()
        let failed = state.fail()
        let duplicate = state.fail()
        let lateProof = state.started()
        #expect(started && failed && !duplicate && !lateProof)
        _ = state.begin()
        let retryStarted = state.started()
        #expect(retryStarted)
    }
}

@MainActor
struct PlaybackStartupSupervisorTests {
    @Test func `a new stream does not borrow the previous streams first frame`() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let qoe = PlaybackQoE(defaults: defaults)
        let owner = NSObject()
        let supervisor = PlaybackStartupSupervisor(qoe: qoe)
        supervisor.recordSession(engine: .ksPlayer, isLive: false, owner: owner)
        #expect(supervisor.accept(.playhead, engine: .ksPlayer))
        supervisor.recordSession(engine: .ksPlayer, isLive: false, owner: owner)
        #expect(qoe.summary.engines[PlayerEngineKind.ksPlayer.rawValue]?.firstFrames == 1)
        #expect(supervisor.fail())
        #expect(!supervisor.fail())
        #expect(qoe.summary.engines[PlayerEngineKind.ksPlayer.rawValue]?.startupFailures == 1)
        supervisor.end()
    }

    @Test func `retired engine callbacks cannot claim the replacement sessions first frame`() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let qoe = PlaybackQoE(defaults: defaults)
        let first = PlaybackStartupSupervisor(qoe: qoe)
        let second = PlaybackStartupSupervisor(qoe: qoe)
        let firstOwner = NSObject()
        let secondOwner = NSObject()
        first.recordSession(engine: .ksPlayer, isLive: false, owner: firstOwner)
        second.recordSession(engine: .vlcKit, isLive: false, owner: secondOwner)
        #expect(first.accept(.playhead, engine: .ksPlayer))
        first.end()
        #expect(qoe.summary.engines[PlayerEngineKind.vlcKit.rawValue]?.firstFrames == 0)
        #expect(second.accept(.displayedFrames, engine: .vlcKit))
        #expect(qoe.summary.engines[PlayerEngineKind.vlcKit.rawValue]?.firstFrames == 1)
        second.end()
    }

    @Test func `appearance registers first frame proof delivered before mounting`() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let qoe = PlaybackQoE(defaults: defaults)
        let owner = NSObject()
        let supervisor = PlaybackStartupSupervisor(qoe: qoe)
        #expect(supervisor.accept(.playhead, engine: .ksPlayer))
        supervisor.recordSession(engine: .ksPlayer, isLive: false, owner: owner, restarting: false)
        #expect(qoe.summary.engines[PlayerEngineKind.ksPlayer.rawValue]?.firstFrames == 1)
        supervisor.end()
    }

    @Test func `first frame before appearance is retained when the timer is armed`() async throws {
        let supervisor = PlaybackStartupSupervisor()
        let accepted = supervisor.started()
        #expect(accepted)
        var expired = false
        supervisor.arm(timeout: 0.01) { expired = true }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!expired)
        supervisor.end()
        let lateProof = supervisor.started()
        #expect(!lateProof)
    }

    @Test func `appearance cannot reset an earlier terminal failure`() async throws {
        let supervisor = PlaybackStartupSupervisor()
        let reported = supervisor.fail()
        #expect(reported)
        var expired = false
        supervisor.arm(timeout: 0.01) { expired = true }
        let duplicate = supervisor.fail()
        let lateFrame = supervisor.started()
        #expect(!duplicate && !lateFrame)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!expired)
        supervisor.begin(timeout: 1) { expired = true }
        let retried = supervisor.started()
        #expect(retried)
        supervisor.end()
    }

    @Test func `a replaced timer cannot call the old failure handler`() async {
        let supervisor = PlaybackStartupSupervisor()
        var expired: [String] = []
        supervisor.begin(timeout: 0.01) { expired.append("old") }
        supervisor.begin(timeout: 0.02) { expired.append("new") }
        // Until something fires, not a fixed 60 ms a busy run outlasted. The
        // old deadline is earlier, so had it survived it would be first.
        _ = await eventually { !expired.isEmpty }
        #expect(expired == ["new"])
        supervisor.end()
    }
}
