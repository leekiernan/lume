import Foundation
@testable import Lume
import Testing

struct ProfileProjectionGateTests {
    /// The success waits return as soon as they succeed; their ceilings only
    /// absorb a global queue starved by the rest of a parallel run.
    @Test func `projection swaps wait for an already admitted synchronous save`() {
        let gate = ProfileProjectionGate()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let attempted = DispatchSemaphore(value: 0)
        let swapped = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DispatchQueue.global().async {
            gate.withExclusive {
                entered.signal()
                _ = release.wait(timeout: .now() + 20)
            }
        }
        #expect(entered.wait(timeout: .now() + 10) == .success)
        DispatchQueue.global().async {
            attempted.signal()
            gate.withExclusive { swapped.signal() }
        }
        #expect(attempted.wait(timeout: .now() + 10) == .success)
        #expect(swapped.wait(timeout: .now() + 0.02) == .timedOut)
        release.signal()
        #expect(swapped.wait(timeout: .now() + 10) == .success)
    }

    @Test func `the projection pointer may commit inside its own swap`() {
        let gate = ProfileProjectionGate()
        var committed = false
        gate.withExclusive { gate.withExclusive { committed = true } }
        #expect(committed)
    }
}
