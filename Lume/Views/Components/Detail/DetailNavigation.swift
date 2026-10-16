import SwiftUI

/// Shared navigation mechanics, independent of the feed that supplied a card
/// or hero. Concrete destinations retain their own loading and playback owners.
enum DetailNavigation {
    static func pathBinding(
        in router: DeepLinkRouter?,
        at path: ReferenceWritableKeyPath<DeepLinkRouter, NavigationPath>,
        fallback: Binding<NavigationPath>
    ) -> Binding<NavigationPath> {
        guard let router else { return fallback }
        return Binding(get: { router[keyPath: path] }, set: { router[keyPath: path] = $0 })
    }

    static func appending(_ hero: HeroItem, to path: NavigationPath) -> NavigationPath {
        switch hero {
        case let .movie(movie, _, _, _, _): appending(movie, to: path)
        case let .series(series, _, _, _, _): appending(series, to: path)
        }
    }

    static func appending(_ route: some Hashable, to path: NavigationPath) -> NavigationPath {
        var path = path
        path.append(route)
        return path
    }

    static func push(_ route: some Hashable, on path: Binding<NavigationPath>) {
        path.wrappedValue = appending(route, to: path.wrappedValue)
    }

    static func push(_ hero: HeroItem, on path: Binding<NavigationPath>) {
        path.wrappedValue = appending(hero, to: path.wrappedValue)
    }
}

extension EnvironmentValues {
    /// Nested rails use the containing area's path, not a hard-coded Home or
    /// Sports path. This also works in previews with the area's local fallback.
    @Entry var detailNavigationPath: Binding<NavigationPath>?
}

extension View {
    /// Install inside the area's NavigationStack. A restored value route uses
    /// the same detail screen and platform transition as a new poster push.
    func detailDestinations(path: Binding<NavigationPath>? = nil, namespace: Namespace.ID? = nil) -> some View {
        modifier(DetailDestinations(path: path, namespace: namespace))
    }
}

private struct DetailDestinations: ViewModifier {
    @Environment(\.contentRestriction) private var restriction
    let path: Binding<NavigationPath>?
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        content
            // The page shows the copy watched most recently, with the others
            // on its Source button (`TitleSourceHost`).
            .pushedDestination(for: Movie.self) { movie in
                TitleSourceHost(movie: movie, restriction: restriction) { copy in
                    if case let .movie(shown) = copy {
                        MovieDetailView(movie: shown, animationNamespace: namespace)
                    }
                }
                .id(restriction.visibilityToken)
                .detailZoomTransition(sourceID: movie.id, namespace: namespace)
            }
            .pushedDestination(for: Series.self) { series in
                TitleSourceHost(series: series, restriction: restriction) { copy in
                    if case let .series(shown) = copy {
                        SeriesDetailView(series: shown, animationNamespace: namespace)
                    }
                }
                .id(restriction.visibilityToken)
                .detailZoomTransition(sourceID: series.id, namespace: namespace)
            }
            .pushedDestination(for: PersonRoute.self) { route in
                PersonFilmographyView(route: route, animationNamespace: namespace)
            }
        #if os(tvOS)
            .pushedDestination(for: SportsMatchRoute.self) { route in
                TVGameDetailView(route: route)
            }
        #endif
            .environment(\.detailNavigationPath, path)
    }
}

private extension View {
    @ViewBuilder
    func detailZoomTransition(sourceID: String, namespace: Namespace.ID?) -> some View {
        #if os(iOS)
            if let namespace {
                navigationTransition(.zoom(sourceID: sourceID, in: namespace))
            } else {
                self
            }
        #else
            self
        #endif
    }
}
