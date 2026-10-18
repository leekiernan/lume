import Foundation
@testable import Lume
import Testing

struct ProfileProjectionGateTests {
    /// The holder and the contender run on threads of their own: started from
    /// `DispatchQueue.global()`, they waited on a GCD pool the rest of a
    /// parallel run kept busy, and a 10 s wait for the holder to even start
    /// timed out. The success waits return as soon as they succeed.
    @Test func `projection swaps wait for an already admitted synchronous save`() {
        let gate = ProfileProjectionGate()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let attempted = DispatchSemaphore(value: 0)
        let swapped = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let holder = Thread {
            gate.withExclusive {
                entered.signal()
                _ = release.wait(timeout: .now() + 20)
            }
        }
        // The main thread waits on it: match its priority, not inherit default.
        holder.qualityOfService = .userInteractive
        holder.start()
        #expect(entered.wait(timeout: .now() + 10) == .success)
        let contender = Thread {
            attempted.signal()
            gate.withExclusive { swapped.signal() }
        }
        // The main thread waits on it: match its priority, not inherit default.
        contender.qualityOfService = .userInteractive
        contender.start()
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
