import Foundation

/// A detail lane's publication boundary, not an async loader. Movie and Series
/// machines own their distinct work; this only arbitrates request lifetimes.
nonisolated struct DetailLoadState {
    enum Outcome: Equatable {
        case loaded, failed
    }

    struct Request: Equatable {
        fileprivate let token = RequestToken()
    }

    private enum State {
        case idle(blocking: Bool)
        case loading(Request, blocking: Bool)
        case settled(Outcome)
    }

    private var state: State

    var isBlocking: Bool {
        switch state {
        case let .idle(blocking), let .loading(_, blocking): blocking
        case .settled: false
        }
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var outcome: Outcome? {
        if case let .settled(outcome) = state { return outcome }
        return nil
    }

    init(isBlocking: Bool = false) {
        state = .idle(blocking: isBlocking)
    }

    mutating func begin() -> Request {
        let request = Request()
        state = .loading(request, blocking: isBlocking)
        return request
    }

    func owns(_ request: Request) -> Bool {
        guard case let .loading(active, _) = state else { return false }
        return active == request
    }

    @discardableResult
    mutating func finish(_ request: Request, outcome: Outcome = .loaded) -> Bool {
        guard owns(request) else { return false }
        state = .settled(outcome)
        return true
    }

    mutating func abandon(_ request: Request) {
        if owns(request) { invalidate() }
    }

    mutating func invalidate() {
        state = .idle(blocking: isBlocking)
    }
}
