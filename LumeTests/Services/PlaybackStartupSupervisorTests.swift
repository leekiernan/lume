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

    @Test func `a replaced timer cannot call the old failure handler`() async throws {
        let supervisor = PlaybackStartupSupervisor()
        var expired: [String] = []
        supervisor.begin(timeout: 0.01) { expired.append("old") }
        supervisor.begin(timeout: 0.02) { expired.append("new") }
        try await Task.sleep(for: .milliseconds(60))
        #expect(expired == ["new"])
        supervisor.end()
    }
}
