import SwiftUI

/// Where a rail sits, which sets its geometry. Callers keep their typed
/// navigation, menus and cells.
enum PosterRailStyle {
    /// Home, Movies/Series, Library, search, Live TV: the card role's fixed
    /// height (`PosterCardMetrics`) and the browse insets.
    case browse
    /// A movie or series page: the detail page's insets and spacing, and the
    /// height of the cards themselves (cast, videos, similar titles).
    case detail
}

/// The one horizontal rail: a heading (or none, under a section the caller
/// titles), then the cards. On tvOS a rail is its own focus section.
struct PosterRail<Destination: Hashable, Content: View>: View {
    /// Nil when the caller already titles the section.
    let title: Text?
    let showAll: Destination?
    var style = PosterRailStyle.browse
    var groupsFocus = false
    /// Overrides the role height for landscape cards such as Continue Watching.
    var rowHeight: CGFloat?
    var fitsContentHeight = false
    var isRefreshing = false
    /// tvOS: the title and the first card share the same sidebar handoff.
    var onLeadingLeft: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @Environment(\.posterPresentation) private var presentation

    private var layout: PosterCardMetrics.Layout {
        PosterCardMetrics.layout(for: presentation)
    }

    var body: some View {
        #if os(tvOS)
            if groupsFocus || style == .detail { rail.focusSection() } else { rail }
        #else
            rail
        #endif
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: headingSpacing) {
            if let title {
                heading(title)
                    .padding(.horizontal, horizontalInset)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                cards
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, verticalPadding)
            }
            .scrollClipDisabled()
            .fixedSize(horizontal: false, vertical: sizesToCards)
            .frame(height: sizesToCards ? nil : rowHeight ?? layout.rowHeight)
        }
    }

    @ViewBuilder private func heading(_ title: Text) -> some View {
        switch style {
        case .browse:
            RailHeading(title: title, destination: showAll, isRefreshing: isRefreshing, onLeadingLeft: onLeadingLeft)
        case .detail:
            #if os(tvOS)
                title
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            #else
                title.railHeadingStyle()
            #endif
        }
    }

    @ViewBuilder private var cards: some View {
        if sizesToCards {
            // The short Continue Watching rail measures every card up front,
            // so horizontal scrolling cannot change its height. Poster rails
            // retain lazy loading and their fixed artwork geometry.
            if style == .detail {
                LazyHStack(alignment: .top, spacing: spacing, content: content)
            } else {
                HStack(spacing: spacing, content: content)
            }
        } else {
            LazyHStack(spacing: spacing, content: content)
        }
    }

    // MARK: Geometry

    private var sizesToCards: Bool {
        fitsContentHeight || style == .detail
    }

    private var headingSpacing: CGFloat {
        #if os(tvOS)
            style == .detail ? 22 : 12
        #else
            12
        #endif
    }

    /// Nil keeps the system's default inset, which browse rails have always used.
    private var horizontalInset: CGFloat? {
        switch style {
        case .browse:
            nil
        case .detail:
            #if os(tvOS)
                TVDetailMetrics.horizontalInset
            #else
                DetailMetrics.contentPadding
            #endif
        }
    }

    private var spacing: CGFloat {
        #if os(tvOS)
            style == .detail ? TVDetailMetrics.railSpacing : layout.spacing
        #else
            layout.spacing
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(tvOS)
            // Breathing room for the focus lift.
            style == .detail ? 24 : layout.railVerticalPadding
        #else
            style == .detail ? 0 : layout.railVerticalPadding
        #endif
    }
}

extension PosterRail where Destination == Never {
    /// A rail of `items` with no See All, its cards keeping tvOS focus memory
    /// (`RailItems`).
    init<Item: Identifiable, Cell: View>(
        title: Text?,
        items: [Item],
        style: PosterRailStyle = .browse,
        @ViewBuilder cell: @escaping (Item) -> Cell
    ) where Content == RailItems<Item, Cell> {
        self.init(title: title, showAll: nil, style: style) { RailItems(items: items, cell: cell) }
    }
}

/// A rail's cards with tvOS focus memory: moving into the rail from above or
/// below lands on the card last focused there, or the first card — not on
/// whichever card sits nearest the middle of the screen, which is where the
/// focus engine would otherwise go. Elsewhere it is a plain `ForEach`.
struct RailItems<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    @ViewBuilder let cell: (Item) -> Cell

    #if os(tvOS)
        @FocusState private var focused: Item.ID?
        @State private var lastFocused: Item.ID?
    #endif

    var body: some View {
        #if os(tvOS)
            ForEach(items) { item in
                cell(item)
                    .focused($focused, equals: item.id)
            }
            .onChange(of: focused) { _, id in
                if let id { lastFocused = id }
            }
            .defaultFocus($focused, entryTarget, priority: .userInitiated)
        #else
            ForEach(items, content: cell)
        #endif
    }

    #if os(tvOS)
        /// The card last focused, while the rail still shows it.
        private var entryTarget: Item.ID? {
            if let lastFocused, items.contains(where: { $0.id == lastFocused }) { return lastFocused }
            return items.first?.id
        }
    #endif
}
