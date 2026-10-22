import Foundation
@testable import Lume
import Testing

struct LiveQualityStepDownTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    @Test func `one short stall only asks to look again`() {
        var machine = LiveQualityStepDown()
        let decision = machine.stallBegan(on: "a", at: start)
        #expect(decision == .recheck(after: LiveQualityStepDown.longStall))
        machine.stallEnded(on: "a")
        let outlasted = machine.stallOutlasted(on: "a", at: at(8))
        #expect(!outlasted)
    }

    @Test func `a stall that outlasts the limit steps down`() {
        var machine = LiveQualityStepDown()
        _ = machine.stallBegan(on: "a", at: start)
        let early = machine.stallOutlasted(on: "a", at: at(5))
        let late = machine.stallOutlasted(on: "a", at: at(8))
        #expect(!early)
        #expect(late)
    }

    @Test func `three stalls in a minute step down, spread out they don't`() {
        var bunched = LiveQualityStepDown()
        for offset in [0.0, 20] {
            _ = bunched.stallBegan(on: "a", at: at(offset))
            bunched.stallEnded(on: "a")
        }
        let third = bunched.stallBegan(on: "a", at: at(40))
        #expect(third == .stepDown)

        var spread = LiveQualityStepDown()
        for offset in [0.0, 50] {
            _ = spread.stallBegan(on: "a", at: at(offset))
            spread.stallEnded(on: "a")
        }
        let later = spread.stallBegan(on: "a", at: at(100))
        #expect(later != .stepDown)
    }

    @Test func `a new stream starts the count afresh`() {
        var machine = LiveQualityStepDown()
        _ = machine.stallBegan(on: "a", at: start)
        _ = machine.stallBegan(on: "a", at: at(1))
        let other = machine.stallBegan(on: "b", at: at(2))
        let stale = machine.stallOutlasted(on: "a", at: at(20))
        #expect(other != .stepDown)
        #expect(!stale)
    }

    @Test func `a stream that never starts steps down`() {
        var machine = LiveQualityStepDown()
        let decision = machine.failedToStart(on: "a")
        #expect(decision == .stepDown)
    }
}
