//
//  BrowseSidebarToolbar.swift
//  Lume
//
//  The affordances that reveal `LibraryBrowseSidebar`. The sidebar is hidden by
//  default, so each platform needs somewhere to ask for it: a leading toolbar
//  button on iOS / macOS / visionOS, and — since the Movies and Series pages
//  carry no toolbar on tvOS (see `LibraryToolbar`) — a left press on a rail's
//  heading or leading card reveals it (`onLeadingEdgeLeft`).
//

import SwiftUI

/// One placement contract for every browse panel. Keeping this outside the
/// individual Movies/Series/Live TV implementations prevents profile-specific
/// navigation layouts from drifting their glass surfaces into the title bar.
enum BrowseSidebarMetrics {
    static var margin: CGFloat {
        #if os(tvOS)
            30
        #else
            12
        #endif
    }

    static var topMargin: CGFloat {
        #if os(macOS)
            // Clear the traffic lights and the toolbar title on both compact
            // Live TV-only and full library tab layouts.
            64
        #else
            margin
        #endif
    }
}

extension View {
    /// The toolbar entry point. A no-op on tvOS, which reveals the panel by
    /// focus instead of by a button.
    func browseSidebarToolbar(isPresented: Binding<Bool>, isEnabled: Bool) -> some View {
        modifier(BrowseSidebarToolbar(isPresented: isPresented, isEnabled: isEnabled))
    }

    /// tvOS: fires when the user presses left on this view. Attached to a rail's
    /// heading or *leading* card only, so it means "left from the leftmost item" — a
    /// page-level handler fires on every left press, wherever focus sits, and
    /// would open the sidebar mid-row.
    @ViewBuilder
    func onLeadingEdgeLeft(_ action: (() -> Void)?) -> some View {
        #if os(tvOS)
            if let action {
                browseSidebarFocusTarget().modifier(BrowseLeadingMove(action: action))
            } else {
                self
            }
        #else
            self
        #endif
    }

    #if os(tvOS)
        func onLeadingEdgeLeft<Value: Hashable>(
            _ action: (() -> Void)?, focus: FocusState<Value?>.Binding, equals value: Value
        ) -> some View {
            browseSidebarFocusTarget(focus, equals: value)
                .modifier(BrowseLeadingMove(action: action))
        }
    #endif
}

#if os(tvOS)
    private struct BrowseLeadingMove: ViewModifier {
        let action: (() -> Void)?

        func body(content: Content) -> some View {
            if let action {
                content.onMoveCommand { direction in
                    guard direction == .left else { return }
                    // Never mutate presentation inside the focus animation.
                    Task { action() }
                }
            } else {
                content
            }
        }
    }
#endif

private struct BrowseSidebarToolbar: ViewModifier {
    @Binding var isPresented: Bool
    let isEnabled: Bool

    func body(content: Content) -> some View {
        #if os(tvOS)
            content
        #else
            content.toolbar {
                #if os(macOS)
                    ToolbarItem(placement: .navigation) { button.disabled(!isEnabled) }
                #else
                    ToolbarItem(placement: .topBarLeading) { button.disabled(!isEnabled) }
                #endif
            }
        #endif
    }

    #if !os(tvOS)
        private var button: some View {
            Button {
                isPresented.toggle()
            } label: {
                Label("Browse", systemImage: "line.3.horizontal")
            }
            .accessibilityLabel("Browse Categories")
        }
    #endif
}

/// A standing entry point to the browse sidebar, rendered below a page's rows.
/// Keeps the page from being actionless when every row happens to resolve to
/// nothing (a fresh catalog with no history, favorites or TMDB matches), and
/// makes the demoted categories discoverable besides.
struct BrowseCategoriesButton: View {
    private let onOpen: () -> Void

    init(isPresented: Binding<Bool>) {
        onOpen = { isPresented.wrappedValue = true }
    }

    init(onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
    }

    var body: some View {
        Button {
            onOpen()
        } label: {
            Label("Browse All Categories", systemImage: "square.grid.2x2")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .browseSidebarFocusTarget()
        .padding(.horizontal)
        .padding(.top, 8)
    }
}
