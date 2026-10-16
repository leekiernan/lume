import Foundation
import Observation
import SwiftData

/// Preparation owns a request, playback owns a copy, and only dismissal
/// changes the detail page. The player can update the copy without rebuilding
/// the covered page and upsetting tvOS focus.
@Observable
final class TitleSourceSelection {
    struct Request: Identifiable {
        let id = UUID()
        let source: TitleSource
    }

    private enum Phase {
        case idle
        case preparing(Request)
        case playing(TitleSource)
    }

    let sources: [TitleSource]
    private(set) var current: TitleSource
    private var phase: Phase = .idle

    init(sources: [TitleSource], current: TitleSource) {
        self.sources = sources
        self.current = current
    }

    var offersChoice: Bool {
        sources.count > 1
    }

    var request: Request? {
        guard case let .preparing(request) = phase else { return nil }
        return request
    }

    func pick(_ source: TitleSource) {
        guard sources.contains(where: { $0.id == source.id }) else { return }
        phase = .preparing(Request(source: source))
    }

    func beginPlayback(_ request: Request) -> Bool {
        guard self.request?.id == request.id else { return false }
        phase = .playing(request.source)
        return true
    }

    func abandonPick(_ request: Request) {
        if self.request?.id == request.id { phase = .idle }
    }

    /// Plain Play and in-player source/episode changes report the actual copy.
    /// Unrelated media never turns this page into a different title.
    func recordPlayback(_ ref: PlayableMedia.ContentRef, in context: ModelContext) {
        let id: String? = switch ref {
        case let .movie(movieID): movieID
        case let .episode(episodeID): PlayerContentLookup.episode(episodeID, in: context)?.series?.id
        case .live: nil
        }
        guard let source = sources.first(where: { $0.id == id }) else { return }
        phase = .playing(source)
    }

    func showPicked() {
        if case let .playing(source) = phase { current = source }
        phase = .idle
    }
}
