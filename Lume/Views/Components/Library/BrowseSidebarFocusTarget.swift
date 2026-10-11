import SwiftUI

extension View {
    /// Default for a sidebar-opening control with no other focus binding.
    /// Pointer platforms retain their normal responder behaviour.
    @ViewBuilder
    func browseSidebarFocusTarget() -> some View {
        #if os(tvOS)
            modifier(BrowseSidebarAutomaticFocusTarget())
        #else
            self
        #endif
    }

    /// Apply to content before its sidebar overlay. The panel alone accepts
    /// focus while open; bookmarks never survive a different page or viewer.
    @ViewBuilder
    func browseSidebarContentFocus(scope: [String]) -> some View {
        #if os(tvOS)
            modifier(BrowseSidebarContentFocus(scope: scope))
        #else
            self
        #endif
    }
}

#if os(tvOS)
    private struct BrowseSidebarContentFocus: ViewModifier {
        @Environment(BrowseSidebarState.self) private var sidebar: BrowseSidebarState?
        @Environment(ProfileManager.self) private var profiles: ProfileManager?
        let scope: [String]

        func body(content: Content) -> some View {
            content
                .disabled(sidebar?.isPresented == true)
                .onChange(of: scope) { _, _ in sidebar?.invalidateContentFocus() }
                .onChange(of: profiles?.activeProfileID) { _, _ in sidebar?.invalidateContentFocus() }
                .onDisappear { sidebar?.invalidateContentFocus() }
        }
    }

    extension View {
        /// Reuse an existing focus owner instead of attaching a second binding
        /// to the same control (which makes SwiftUI focus writes ambiguous).
        func browseSidebarFocusTarget<Value: Hashable>(_ focus: FocusState<Value?>.Binding, equals value: Value) -> some View {
            focused(focus, equals: value)
                .modifier(BrowseSidebarFocusRegistration(isFocused: focus.wrappedValue == value) { valid in
                    await landTVFocus(focus, on: value, while: valid)
                })
        }

        func browseSidebarFocusTarget(_ focus: FocusState<Bool>.Binding) -> some View {
            focused(focus)
                .modifier(BrowseSidebarFocusRegistration(isFocused: focus.wrappedValue) { valid in
                    await landTVFocus(focus, while: valid)
                })
        }
    }

    private struct BrowseSidebarAutomaticFocusTarget: ViewModifier {
        @Environment(BrowseSidebarState.self) private var sidebar: BrowseSidebarState?
        @FocusState private var isFocused: Bool

        func body(content: Content) -> some View {
            if sidebar != nil {
                content.browseSidebarFocusTarget($isFocused)
            } else {
                content
            }
        }
    }

    private struct BrowseSidebarFocusRegistration: ViewModifier {
        @Environment(BrowseSidebarState.self) private var sidebar: BrowseSidebarState?
        @State private var id = UUID()
        let isFocused: Bool
        let restore: (@escaping () -> Bool) async -> Void

        func body(content: Content) -> some View {
            content
                .onChange(of: isFocused, initial: true) { _, focused in
                    if focused {
                        sidebar?.rememberContentFocus(id: id, restore: restore)
                    } else {
                        sidebar?.releaseContentFocus(id: id)
                    }
                }
                .onDisappear { sidebar?.removeContentFocus(id: id) }
        }
    }
#endif
