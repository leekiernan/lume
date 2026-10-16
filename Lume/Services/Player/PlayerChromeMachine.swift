import Foundation

/// Requested chrome only, not playback readiness, buffering or retry state.
/// One deadline owns hiding: pointer exit replaces inactivity, and later
/// activity invalidates either. Eligibility belongs to the engine host; an
/// open menu belongs here, since it is the chrome's own.
nonisolated struct PlayerChromeMachine {
    enum Deadline: Equatable {
        case inactivity, pointerExit

        var delay: Duration {
            switch self {
            case .inactivity: .seconds(4)
            case .pointerExit: .milliseconds(600)
            }
        }
    }

    struct Request: Equatable {
        fileprivate let token = RequestToken()
        let deadline: Deadline
    }

    private enum State {
        case hidden, visible, waiting(Request)
        /// Up under a native menu one of the controls opened (audio,
        /// subtitles, source, the favourite's long press). The menu takes
        /// focus, and with it the activity that would renew a deadline, so
        /// none runs until it closes.
        case menuOpen
    }

    private var state: State = .visible

    var isVisible: Bool {
        if case .hidden = state { return false }
        return true
    }

    var isMenuOpen: Bool {
        if case .menuOpen = state { return true }
        return false
    }

    /// Already up under an open menu, the controls stay held.
    mutating func show() {
        if !isMenuOpen { state = .visible }
    }

    mutating func hide() {
        state = .hidden
    }

    mutating func cancelDeadline() {
        if isVisible, !isMenuOpen { state = .visible }
    }

    /// Revokes any pending deadline; none can be scheduled until it closes.
    mutating func menuOpened() {
        if isVisible { state = .menuOpen }
    }

    /// Back to plain visible: the host schedules a fresh deadline.
    mutating func menuClosed() {
        if isMenuOpen { state = .visible }
    }

    mutating func schedule(_ deadline: Deadline, mayHide: Bool) -> Request? {
        cancelDeadline()
        guard isVisible, !isMenuOpen, mayHide else { return nil }
        let request = Request(deadline: deadline)
        state = .waiting(request)
        return request
    }

    /// A completed deadline is consumed even when the host is now pinned.
    /// Replaying it after playback resumes must never hide the controls.
    @discardableResult
    mutating func fire(_ request: Request, mayHide: Bool) -> Bool {
        guard case let .waiting(current) = state, current == request else { return false }
        state = mayHide ? .hidden : .visible
        return mayHide
    }
}
