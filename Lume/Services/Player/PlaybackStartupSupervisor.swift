import Foundation

/// The lifecycle around first-frame proof, not the proof itself. Engines keep
/// PlaybackStartTracker's ready/playhead/frame checks and their reconnect policy.
nonisolated struct PlaybackStartupState: Equatable {
    enum Phase: Equatable {
        case idle
        case waiting(RequestToken)
        case started
        case failed
    }

    /// Engine callbacks can arrive while a representable is being mounted,
    /// before its appearance hook arms the deadline. Do not discard that proof.
    private(set) var phase: Phase = .waiting(RequestToken())

    mutating func begin() -> RequestToken {
        let token = RequestToken()
        phase = .waiting(token)
        return token
    }

    func canExpire(_ token: RequestToken) -> Bool {
        phase == .waiting(token)
    }

    mutating func started() -> Bool {
        guard case .waiting = phase else { return false }
        phase = .started
        return true
    }

    mutating func fail() -> Bool {
        switch phase {
        case .waiting, .started: phase = .failed; return true
        case .idle, .failed: return false
        }
    }

    mutating func end() {
        phase = .idle
    }
}

/// One cancellable startup deadline per stream. A retired timer cannot fail a
/// replacement, and late healthy callbacks cannot undo a terminal failure.
@MainActor
final class PlaybackStartupSupervisor {
    private var state = PlaybackStartupState()
    private var timer: Task<Void, Never>?

    /// A genuinely new load or explicit retry resets the terminal latch.
    func begin(timeout: TimeInterval, onTimeout: @escaping @MainActor () -> Void) {
        _ = state.begin()
        arm(timeout: timeout, onTimeout: onTimeout)
    }

    /// Appearance alone must not erase first-frame proof or a failure delivered
    /// synchronously while the representable was being mounted.
    func arm(timeout: TimeInterval, onTimeout: @escaping @MainActor () -> Void) {
        cancelTimer()
        guard case .waiting = state.phase else { return }
        let token = state.begin()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            guard let self, !Task.isCancelled, state.canExpire(token) else { return }
            timer = nil
            onTimeout()
        }
    }

    func started() -> Bool {
        guard state.started() else { return false }
        cancelTimer()
        return true
    }

    func fail() -> Bool {
        guard state.fail() else { return false }
        cancelTimer()
        return true
    }

    func cancelTimer() {
        timer?.cancel(); timer = nil
    }

    func end() {
        cancelTimer(); state.end()
    }
}
