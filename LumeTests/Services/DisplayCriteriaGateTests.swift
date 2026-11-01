//
//  DisplayCriteriaGateTests.swift
//  LumeTests
//
//  Display-mode requests settle before reaching the TV, and one matching the
//  mode already set never does — a mode switch can hang the Apple TV.
//

@testable import Lume
import Testing

struct DisplayCriteriaGateTests {
    private let film = DisplayCriteriaGate.Criteria(refreshRate: 23.976, dynamicRange: 0)
    private let filmHDR = DisplayCriteriaGate.Criteria(refreshRate: 23.976, dynamicRange: 2)
    private let broadcast = DisplayCriteriaGate.Criteria(refreshRate: 25, dynamicRange: 0)

    @Test func `the first request applies`() {
        var gate = DisplayCriteriaGate()
        gate.request(film)
        let applies = gate.settle()
        #expect(applies)
        #expect(gate.applied == film)
    }

    @Test func `back-to-back requests apply only the last`() {
        var gate = DisplayCriteriaGate()
        gate.request(broadcast)
        gate.request(filmHDR)
        let applies = gate.settle()
        #expect(applies)
        #expect(gate.applied == filmHDR)
        let appliesAgain = gate.settle()
        #expect(!appliesAgain)
    }

    @Test func `an episode in the same format leaves the display alone`() {
        var gate = DisplayCriteriaGate()
        gate.request(film)
        _ = gate.settle()
        gate.request(.init(refreshRate: 23.98, dynamicRange: 0))
        let applies = gate.settle()
        #expect(!applies)
        #expect(gate.applied == film)
    }

    @Test func `a different format applies`() {
        var gate = DisplayCriteriaGate()
        gate.request(film)
        _ = gate.settle()
        gate.request(filmHDR)
        let applies = gate.settle()
        #expect(applies)
        gate.request(broadcast)
        let appliesAgain = gate.settle()
        #expect(appliesAgain)
    }

    @Test func `after the player clears the mode the same format applies again`() {
        var gate = DisplayCriteriaGate()
        gate.request(film)
        _ = gate.settle()
        gate.reset()
        gate.request(film)
        let applies = gate.settle()
        #expect(applies)
    }

    @Test func `settling with nothing pending does nothing`() {
        var gate = DisplayCriteriaGate()
        let applies = gate.settle()
        #expect(!applies)
        #expect(gate.applied == nil)
    }
}
