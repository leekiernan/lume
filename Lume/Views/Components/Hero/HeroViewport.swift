import SwiftUI

extension EnvironmentValues {
    /// The height of the scroll view a hero opens, 0 until it has been
    /// measured. `HeroCarouselFrame` caps the hero at it.
    @Entry var heroViewportHeight: CGFloat = 0
}

extension View {
    /// Measures this scroll view and hands its height to the hero inside, so a
    /// fold or rotation resizes the hero mid-session. Measured here, outside
    /// the hero, so the hero's own size never feeds back into it.
    func heroViewport() -> some View {
        modifier(HeroViewportModifier())
    }
}

private struct HeroViewportModifier: ViewModifier {
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.heroViewportHeight, height)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }
}
