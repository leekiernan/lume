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
