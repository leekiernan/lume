import SwiftUI

#if os(tvOS)
    extension View {
        /// A detail screen may be recreated while the viewer is still moving
        /// across the tab bar. Declare its landing *inside* its own scope; do
        /// not write FocusState on appearance or after asynchronous enrichment.
        /// Those writes try to pull focus off the tab bar during stack restore.
        ///
        /// `priority` `.userInitiated` (the default) also lands there when the
        /// viewer moves in from the tab bar; `.automatic` lands there only on
        /// presentation, leaving later entry to geometry.
        func tvDetailDefaultFocus<Value: Hashable>(
            _ focus: FocusState<Value?>.Binding, _ target: Value, priority: DefaultFocusEvaluationPriority = .userInitiated
        ) -> some View {
            modifier(TVDetailDefaultFocus(focus: focus, target: target, priority: priority))
        }
    }

    private struct TVDetailDefaultFocus<Value: Hashable>: ViewModifier {
        let focus: FocusState<Value?>.Binding
        let target: Value
        let priority: DefaultFocusEvaluationPriority
        @Namespace private var scope

        func body(content: Content) -> some View {
            content
                // Prefer the action on user-driven entry as well as initial
                // presentation. This declares a landing, never grabs focus
                // after enrichment or while the viewer moves across tabs.
                .defaultFocus(focus, target, priority: priority)
                .focusScope(scope)
                .focusSection()
        }
    }
#endif
