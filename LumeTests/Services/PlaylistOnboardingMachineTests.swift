//
//  PlaylistOnboardingMachineTests.swift
//  LumeTests
//

import Foundation
@testable import Lume
import Testing

struct PlaylistOnboardingMachineTests {
    @Test func `save failures remain retryable and cancellation retires validation results`() throws {
        var machine = PlaylistOnboardingMachine()
        let begun = machine.begin(.xtream)
        let attempt = try #require(begun)
        #expect(throws: CocoaError.self) {
            try machine.commit(attempt) { throw CocoaError(.fileWriteOutOfSpace) }
        }
        #expect(machine.errorMessage != nil)
        #expect(!machine.isValidating)
        let retried = machine.begin(.xtream)
        let retry = try #require(retried)
        machine.cancel()
        var persisted = false
        let accepted = try machine.commit(retry) { persisted = true }
        #expect(!accepted)
        #expect(!persisted)
    }

    @Test func `only one validation attempt can own the form`() {
        var machine = PlaylistOnboardingMachine()
        let attempt = machine.begin(.xtream)

        #expect(attempt != nil)
        #expect(machine.isValidating)
        let second = machine.begin(.m3u)
        #expect(second == nil)
    }

    @Test func `only the active attempt can complete the form`() throws {
        var machine = PlaylistOnboardingMachine()
        let begun = machine.begin(.stalker)
        let active = try #require(begun)
        let stale = PlaylistOnboardingMachine.Attempt(id: UUID(), source: .stalker)

        let staleSucceeded = try machine.commit(stale, persist: {})
        #expect(!staleSucceeded)
        #expect(machine.isValidating)
        let activeSucceeded = try machine.commit(active, persist: {})
        #expect(activeSucceeded)
        #expect(!machine.isValidating)
        #expect(machine.errorMessage == nil)
    }

    @Test func `a failed attempt is retryable and clears its error on retry`() throws {
        var machine = PlaylistOnboardingMachine()
        let begun = machine.begin(.m3u)
        let failed = try #require(begun)

        machine.fail(failed, message: "Could not connect")
        #expect(machine.errorMessage == "Could not connect")
        #expect(!machine.isValidating)

        let retry = machine.begin(.m3u)
        #expect(retry != nil)
        #expect(machine.errorMessage == nil)
        #expect(machine.isValidating)
    }

    @Test func `late failures cannot replace a newer form state`() throws {
        var machine = PlaylistOnboardingMachine()
        let firstBegun = machine.begin(.xtream)
        let first = try #require(firstBegun)
        machine.fail(first, message: "First failure")
        let retryBegun = machine.begin(.mediaServer)
        let retry = try #require(retryBegun)

        machine.fail(first, message: "Late failure")

        #expect(machine.isValidating)
        let retrySucceeded = try machine.commit(retry, persist: {})
        #expect(retrySucceeded)
        #expect(machine.errorMessage == nil)
    }

    @Test func `input errors use the same retryable error state`() {
        var machine = PlaylistOnboardingMachine()

        machine.reportInputFailure("Couldn't read file")
        #expect(machine.errorMessage == "Couldn't read file")

        machine.clearFailure()
        #expect(machine.errorMessage == nil)
    }
}
