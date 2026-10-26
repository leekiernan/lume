import Foundation

/// Remote membership and the local flag share one heart. A tracker absent from
/// `trackers` is unavailable: not connected, or the title has no TMDB id.
nonisolated struct MediaFavoriteState: Equatable {
    enum Destination: Hashable, CaseIterable {
        case local
        case tracker(WatchlistProvider)

        static var allCases: [Self] {
            [.local] + WatchlistProvider.allCases.map(tracker)
        }
    }

    /// Nil, or a tracker left out, leaves that destination untouched,
    /// including its metadata/history.
    struct Change: Equatable {
        var local: Bool?
        var trackers: [WatchlistProvider: Bool] = [:]
    }

    let local: Bool
    let trackers: [WatchlistProvider: Bool]

    init(local: Bool, trackers: [WatchlistProvider: Bool] = [:]) {
        self.local = local
        self.trackers = trackers
    }

    var isFavorite: Bool {
        local || trackers.values.contains(true)
    }

    var toggled: Bool {
        !isFavorite
    }

    /// What a heart tap asks of `provider`, if anything.
    func intent(for provider: WatchlistProvider) -> Bool? {
        intent(forMembership: trackers[provider])
    }

    var toggleChange: Change {
        Change(local: toggled, trackers: trackers.compactMapValues { intent(forMembership: $0) })
    }

    func membership(in destination: Destination) -> Bool? {
        switch destination {
        case .local: local
        case let .tracker(provider): trackers[provider]
        }
    }

    /// Individual menu actions never copy their choice to another list.
    func change(setting isPresent: Bool, in destination: Destination) -> Change? {
        guard membership(in: destination) != nil else { return nil }
        switch destination {
        case .local: return Change(local: isPresent)
        case let .tracker(provider): return Change(trackers: [provider: isPresent])
        }
    }

    private func intent(forMembership membership: Bool?) -> Bool? {
        guard let membership else { return nil }
        return toggled || membership ? toggled : nil
    }
}
