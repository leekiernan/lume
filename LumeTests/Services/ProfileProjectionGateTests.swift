import Foundation
@testable import Lume
import Testing

struct ProfileProjectionGateTests {
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
                _ = release.wait(timeout: .now() + 5)
            }
        }
        #expect(entered.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async {
            attempted.signal()
            gate.withExclusive { swapped.signal() }
        }
        #expect(attempted.wait(timeout: .now() + 2) == .success)
        #expect(swapped.wait(timeout: .now() + 0.02) == .timedOut)
        release.signal()
        #expect(swapped.wait(timeout: .now() + 2) == .success)
    }

    @Test func `the projection pointer may commit inside its own swap`() {
        let gate = ProfileProjectionGate()
        var committed = false
        gate.withExclusive { gate.withExclusive { committed = true } }
        #expect(committed)
    }
}
