//
//  BrowseSidebarFocus.swift
//  Lume
//
//  tvOS focus behaviour of `BrowseSidebarPanel`, the browse panel Movies,
//  Series, Live TV and Sports share. A panel that slides in over the
//  page has to *take* focus, or the page underneath stays live: the user keeps
//  navigating a list they can no longer read, and neither Menu nor a press to
//  the right reaches the panel, so there is no way back out of it.
//
//  Landing follows `landTVFocus`, the same release-settle-assert every tvOS
//  surface over live content uses — scrolling to the target first, because the
//  row to land on is routinely below the fold in a long category list.
//
//  Where to land is the caller's `target`, and the panel remembers the row it
//  was last left on so reopening returns there rather than to the top. That
//  matters wherever a panel is opened repeatedly against a live selection.
//
//  tvOS only — every other platform has a pointer and a close button.
//

#if os(tvOS)

    import SwiftUI

    extension View {
        /// Moves focus into a browse panel when it opens, and closes it when
        /// focus leaves. Apply to the panel's scrolling content, inside the
        /// `ScrollViewReader` whose `proxy` this is given.
        ///
        /// `state` outlives the panel, retaining both its row and its opener.
        func browseSidebarFocus(
            state: BrowseSidebarState,
            focus: FocusState<String?>.Binding,
            scrollProxy: ScrollViewProxy,
            scrollTarget: @escaping (String) -> AnyHashable = { AnyHashable($0) },
            target: @escaping () -> String?
        ) -> some View {
            modifier(BrowseSidebarFocus(
                state: state,
                focus: focus,
                scrollProxy: scrollProxy,
                scrollTarget: scrollTarget,
                target: target
            ))
        }
    }

    private struct BrowseSidebarFocus: ViewModifier {
        let state: BrowseSidebarState
        let focus: FocusState<String?>.Binding
        let scrollProxy: ScrollViewProxy
        let scrollTarget: (String) -> AnyHashable
        let target: () -> String?

        /// Focus arrives a beat after the panel appears; until it has, a nil
        /// focus value means "not there yet", not "focus left". Fresh on every
        /// open, since the panel is built anew each time.
        @State private var handoff = BrowseSidebarFocusPolicy.Handoff()

        func body(content: Content) -> some View {
            content
                // Menu closes the panel rather than leaving the tab.
                .onExitCommand { if state.isPresented { Task { returnToContent() } } }
                .onMoveCommand { direction in
                    // Right is the way out, so take it rather than let the
                    // engine move focus into the page first: it would land
                    // beside whichever panel row was focused, and putting that
                    // right afterwards is the highlight jumping again. Nothing
                    // in the panel sits to the right of anything else, so
                    // claiming this direction swallows no in-panel move.
                    guard direction == .right, state.isPresented else { return }
                    Task { returnToContent() }
                }
                .task {
                    let target = target()
                    await landTVFocus(focus, on: target, scrollingTo: scrollProxy,
                                      scrollTarget: target.map(scrollTarget)) { state.isPresented }
                    handoff.finishLanding()
                }
                .onChange(of: focus.wrappedValue) { _, item in
                    guard state.isPresented else { return }
                    if let item {
                        handoff.didFocusRow()
                        // Where to reopen: wherever the panel was left.
                        if handoff.shouldRememberFocus { state.rememberedRowID = item }
                        return
                    }
                    // Focus left the panel some other way than the exits
                    // above. Confirm a hop later: focus briefly reads nil while
                    // it moves between rows inside the panel too.
                    guard handoff.shouldReturnToContent else { return }
                    Task {
                        guard handoff.shouldReturnToContent, focus.wrappedValue == nil, state.isPresented else { return }
                        returnToContent()
                    }
                }
        }

        /// Closes the panel and hands focus back to the page in one move.
        private func returnToContent() {
            state.dismissToContent()
        }
    }

#endif
