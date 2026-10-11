/// Input policy for the bare picture. Focus ownership and media changes are
/// still native-view/host responsibilities, never playback-machine transitions.
nonisolated enum PlayerSurfaceInput {
    enum Direction { case left, right, upward, downward, other }
    enum Action { case controls, browser, surf }
    enum ControlsFocus { case transport, progress }

    /// Revealing the controls does not seek. A second horizontal press on the
    /// progress bar uses the normal seek/skip handling.
    static func controlsFocus(for direction: Direction) -> ControlsFocus {
        switch direction {
        case .left, .right: .progress
        case .upward, .downward, .other: .transport
        }
    }

    static func action(for direction: Direction, isLive: Bool) -> Action {
        guard isLive else { return .controls }
        switch direction {
        case .left: return .browser
        case .right, .upward, .downward: return .surf
        case .other: return .controls
        }
    }

    static func catcherDisabled(controlsDrawn: Bool, browserOpen: Bool, failed: Bool) -> Bool {
        controlsDrawn || browserOpen || failed
    }
}
