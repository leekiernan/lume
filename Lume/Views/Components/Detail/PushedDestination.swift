//
//  PushedDestination.swift
//  Lume
//
//  Every page pushed onto an area's NavigationStack is declared through
//  `pushedDestination` or `PushedLink`, never `navigationDestination` or a
//  destination `NavigationLink` directly (SwiftLint rules hold this), so all
//  of them share one chrome policy. `NavigationLink(value:)` is fine: its
//  pages come from a `pushedDestination`.
//
//  - tvOS: the tab bar belongs to an area's root page. A pushed page hides it,
//    so its visibility no longer depends on how far the page that pushed it
//    was scrolled, and moving within a stack never jumps to another area;
//    Back returns to the root, where the tab bar is.
//  - Other platforms keep their conventions: pages decide for themselves
//    (the iPhone movie and series details hide the tab bar).
//

import SwiftUI

extension View {
    func pushedDestination<Data: Hashable>(
        for data: Data.Type,
        @ViewBuilder destination: @escaping (Data) -> some View
    ) -> some View {
        navigationDestination(for: data) { destination($0).pushedPage() }
    }

    func pushedDestination<Item: Hashable>(
        item: Binding<Item?>,
        @ViewBuilder destination: @escaping (Item) -> some View
    ) -> some View {
        navigationDestination(item: item) { destination($0).pushedPage() }
    }

    func pushedDestination(
        isPresented: Binding<Bool>,
        @ViewBuilder destination: () -> some View
    ) -> some View {
        navigationDestination(isPresented: isPresented) { destination().pushedPage() }
    }

    /// The chrome every pushed page shares; see the file header.
    func pushedPage() -> some View {
        modifier(PushedPageChrome())
    }
}

/// `NavigationLink { destination } label: { … }`, for a page that isn't a
/// value route, with the pushed-page chrome.
struct PushedLink<Label: View, Destination: View>: View {
    private let destination: () -> Destination
    private let label: () -> Label

    init(@ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: @escaping () -> Label) {
        self.destination = destination
        self.label = label
    }

    var body: some View {
        NavigationLink {
            destination().pushedPage()
        } label: {
            label()
        }
    }
}

private struct PushedPageChrome: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
            content.toolbar(.hidden, for: .tabBar)
        #else
            content
        #endif
    }
}
