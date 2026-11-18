/// FocusState is nil both before controls acquire focus and while a native
/// menu owns it. Only a handoff from a present menu trigger may pin chrome.
/// Lifetime belongs to one mounted controls overlay, not the player session.
nonisolated struct PlayerControlsFocusMachine<Focus: Hashable> {
    enum Effect: Equatable {
        case activity, menuOpened, menuClosed
    }

    private enum State {
        case awaitingFocus(RequestToken)
        case requestingFocus(RequestToken)
        case assignedControl(Focus)
        case unowned
        case control(Focus)
        case nativeMenu(Focus)
    }

    private var state: State = .awaitingFocus(RequestToken())

    var isMenuOpen: Bool {
        if case .nativeMenu = state { return true }
        return false
    }

    var needsLanding: Bool {
        if case .awaitingFocus = state { return true }
        return false
    }

    /// Stable while the focus request is delivered. A declined request
    /// must not create another task or renew the inactivity deadline.
    var landingRequest: RequestToken? {
        switch state {
        case let .awaitingFocus(request), let .requestingFocus(request): request
        default: nil
        }
    }

    mutating func beginLanding() {
        guard case let .awaitingFocus(request) = state else { return }
        state = .requestingFocus(request)
    }

    @discardableResult
    mutating func focusChanged(to focus: Focus?, menuTriggers: Set<Focus>) -> Effect? {
        if let focus {
            if case .requestingFocus = state {
                state = .assignedControl(focus)
                return nil
            }
            let effect: Effect = isMenuOpen ? .menuClosed : .activity
            state = .control(focus)
            return effect
        }
        switch state {
        case let .control(source), let .assignedControl(source):
            if menuTriggers.contains(source) {
                state = .nativeMenu(source)
                return .menuOpened
            }
            if case .assignedControl = state {
                state = .unowned
            } else {
                state = .awaitingFocus(RequestToken())
            }
        case .nativeMenu:
            return menuTriggersChanged(menuTriggers)
        case .requestingFocus:
            state = .unowned
        case .awaitingFocus, .unowned:
            break
        }
        return nil
    }

    @discardableResult
    mutating func menuTriggersChanged(_ menuTriggers: Set<Focus>) -> Effect? {
        guard case let .nativeMenu(source) = state, !menuTriggers.contains(source) else { return nil }
        state = .awaitingFocus(RequestToken())
        return .menuClosed
    }
}
