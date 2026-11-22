//
//  PlaylistOnboardingMachine.swift
//  Lume
//
//  The add-playlist form may validate four distinct source types, but it has
//  one user-visible lifecycle. Keeping the active attempt here prevents a
//  duplicate tap or a late network completion from changing a newer form state.
//

import Foundation

nonisolated struct PlaylistOnboardingMachine: Equatable {
    enum Source: String, Equatable {
        case xtream
        case m3u
        case stalker
        case mediaServer
    }

    struct Attempt: Equatable, Hashable {
        let id: UUID
        let source: Source
    }

    enum State: Equatable {
        case ready
        case validating(Attempt)
        case saving(Attempt)
        case failed(String)
    }

    private(set) var state: State = .ready

    var isValidating: Bool {
        switch state {
        case .validating, .saving: true
        case .ready, .failed: false
        }
    }

    var errorMessage: String? {
        if case let .failed(message) = state { return message }
        return nil
    }

    /// Starts one source validation. A second submit is ignored until the
    /// current attempt completes, so its task can never race the first.
    mutating func begin(_ source: Source) -> Attempt? {
        guard !isValidating else { return nil }
        let attempt = Attempt(id: UUID(), source: source)
        state = .validating(attempt)
        return attempt
    }

    /// Marks this exact attempt as failed. A completion belonging to an older
    /// attempt is intentionally ignored.
    mutating func fail(_ attempt: Attempt, message: String) {
        guard owns(attempt) else { return }
        state = .failed(message)
    }

    /// Persistence is part of the attempt: a save failure remains on the form,
    /// and stale validation results cannot insert anything.
    @discardableResult
    mutating func commit(_ attempt: Attempt, persist: () throws -> Void) throws -> Bool {
        guard case .validating(attempt) = state else { return false }
        state = .saving(attempt)
        do {
            try persist()
            state = .ready
            return true
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    mutating func cancel() {
        state = .ready
    }

    private func owns(_ attempt: Attempt) -> Bool {
        switch state {
        case .validating(attempt), .saving(attempt): true
        default: false
        }
    }

    /// File-import errors happen before a network attempt, but present in the
    /// same inline error surface and should be cleared by the next submission.
    mutating func reportInputFailure(_ message: String) {
        guard !isValidating else { return }
        state = .failed(message)
    }

    mutating func clearFailure() {
        guard !isValidating else { return }
        state = .ready
    }
}
