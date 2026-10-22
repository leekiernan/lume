//
//  TitleSourcePicker.swift
//  Lume
//
//  A title's copies on its detail page (`TitleSources`). The page shows one
//  copy — the one watched most recently, so Play resumes where you left off —
//  and the Source button beside Play lists them all. Picking one plays it from
//  the page as it stands (`TitleSourcePlayback`); the page becomes that copy
//  once the player closes, and having watched it, opens on it next time.
//

import SwiftData
import SwiftUI

extension View {
    /// Plays a copy picked from the Source button through the page's own
    /// `present`. The page calls `showPicked()` once that player has closed.
    func playsPickedSource(_ selection: TitleSourceSelection?, present: @escaping (PlayableMedia) -> Void) -> some View {
        modifier(PickedSourcePlayback(selection: selection, present: present))
    }
}

private struct PickedSourcePlayback: ViewModifier {
    let selection: TitleSourceSelection?
    let present: (PlayableMedia) -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction

    func body(content: Content) -> some View {
        content
            .task(id: selection?.request?.id) {
                guard let selection, let request = selection.request else { return }
                defer { selection.abandonPick(request) }
                let media = await TitleSourcePlayback.media(for: request.source, restriction: restriction, in: modelContext)
                guard !Task.isCancelled, let media, selection.beginPlayback(request) else { return }
                present(media)
            }
            .onDisappear {
                // Revoke ownership synchronously even if a provider ignores
                // cancellation. A returning page must not restart that pick.
                if let request = selection?.request { selection?.abandonPick(request) }
            }
    }
}

/// The page for whichever copy is current. Resolved once, from the opened
/// copy's own context, so the page never shows one copy and then another.
struct TitleSourceHost<Page: View>: View {
    @State private var selection: TitleSourceSelection
    private let restriction: ContentRestriction
    private let page: (TitleCopy) -> Page

    init(movie: Movie, restriction: ContentRestriction, @ViewBuilder page: @escaping (TitleCopy) -> Page) {
        self.restriction = restriction
        let sources = movie.modelContext.map { TitleSources.resolve(for: movie, restriction: restriction, in: $0) } ?? []
        let fallback = TitleSource(copy: .movie(movie), categoryName: nil, playlistName: nil)
        _selection = State(initialValue: Self.selection(sources, opened: movie.id, fallback: fallback))
        self.page = page
    }

    init(series: Series, restriction: ContentRestriction, @ViewBuilder page: @escaping (TitleCopy) -> Page) {
        self.restriction = restriction
        let sources = series.modelContext.map { TitleSources.resolve(for: series, restriction: restriction, in: $0) } ?? []
        let fallback = TitleSource(copy: .series(series), categoryName: nil, playlistName: nil)
        _selection = State(initialValue: Self.selection(sources, opened: series.id, fallback: fallback))
        self.page = page
    }

    private static func selection(_ sources: [TitleSource], opened: String, fallback: TitleSource) -> TitleSourceSelection {
        let current = TitleSources.preferred(in: sources, opened: opened) ?? fallback
        return TitleSourceSelection(sources: sources.isEmpty ? [fallback] : sources, current: current)
    }

    var body: some View {
        if !restriction.hides(categoryID: selection.current.copy.categoryID) {
            page(selection.current.copy)
                .id(selection.current.id)
                .environment(selection)
        }
    }
}

/// Beside Play: the copies, in the same native menu the favourite button's
/// long press shows. Each item is a copy — ticked if it's the one on screen —
/// with what its stream is underneath; choosing one plays it.
struct TitleSourceButton: View {
    let selection: TitleSourceSelection
    @Environment(\.modelContext) private var modelContext
    /// Loaded with the page: a menu can't say when it opens.
    @State private var details = StreamDetailsLoader()

    var body: some View {
        Menu {
            TitleSourceMenuItems(sources: selection.sources, current: selection.current.id, details: details) { source in
                selection.pick(source)
            }
        } label: {
            Image(systemName: "square.stack")
            #if !os(tvOS)
                .font(.headline)
                .frame(minHeight: 30)
            #endif
        }
        .menuIndicator(.hidden)
        #if os(tvOS)
            // Play's height, but square: the glass style fills whatever width
            // it's offered, and Play keeps the rest of the row.
            .buttonStyle(TVGlassButtonStyle(action: .play))
            .frame(width: TVDetailMetrics.Action.play.height)
        #else
            .buttonStyle(.bordered)
        #endif
            .accessibilityLabel(Text("Source: \(selection.current.title)"))
            .accessibilityHint(Text("Choose which copy to play"))
            .task { await details.load(selection.sources, in: modelContext) }
    }
}

/// A title's copies as native menu items, shared by the detail page's Source
/// button and the player's: each copy ticked if it's the one on screen or
/// playing — the Source buttons are icon-only, so this is where it shows — with
/// what its stream is as the item's second line.
struct TitleSourceMenuItems: View {
    let sources: [TitleSource]
    let current: String
    let details: StreamDetailsLoader
    let choose: (TitleSource) -> Void

    var body: some View {
        ForEach(sources) { source in
            Button {
                choose(source)
            } label: {
                if source.id == current {
                    Label(source.title, systemImage: "checkmark")
                } else {
                    Text(verbatim: source.title)
                }
                let line = (details.details[source.id]?.summary ?? []) + source.facts
                if !line.isEmpty { Text(verbatim: line.joined(separator: " · ")) }
            }
        }
    }
}

extension TitleSource {
    /// The copy's name on the Source button: its category, else "Other". A
    /// live channel's quality goes by its tag ("FHD 50FPS"), the way the
    /// provider wrote it.
    var title: String {
        if case let .live(stream) = copy {
            return ChannelQuality.parsed(stream.name).tag
                ?? String(localized: "Standard", comment: "A live channel's quality whose name carries no quality tag")
        }
        return categoryName ?? String(localized: "Other", comment: "A copy of a title whose category has no name")
    }

    /// The Source menu's facts after the stream's details: runtime, file type
    /// and, for another playlist's copy, its playlist.
    var facts: [String] {
        var facts: [String] = []
        if let runtime = DetailFormat.duration(runtime?.seconds) { facts.append(runtime) }
        if case let .movie(movie) = copy, let container = movie.containerExtension, !container.isEmpty {
            facts.append(container.uppercased())
        }
        if case .live = copy, let categoryName { facts.append(categoryName) }
        if let playlistName { facts.append(playlistName) }
        return facts
    }
}
