import Foundation

/// Delivery is separate from navigation: receiving a URL doesn't mean the
/// catalogue or presentation host is ready to resolve it yet.
nonisolated struct DeepLinkDeliveryMachine: Equatable {
    struct Request: Equatable {
        let url: URL
        fileprivate let token = RequestToken()
    }

    struct Readiness: Equatable {
        let profileReady: Bool
        let catalogReady: Bool
        let presentationBlocked: Bool

        var canResolve: Bool {
            profileReady && catalogReady && !presentationBlocked
        }
    }

    struct Attempt: Equatable {
        let token: RequestToken?
        let readiness: Readiness
    }

    enum Outcome: Equatable { case handled, rejected }

    private enum State: Equatable {
        case idle
        case waiting(Request)
        case resolving(Request)
        case finished(Request, Outcome)
    }

    private var state: State = .idle

    var pendingToken: RequestToken? {
        if case let .waiting(request) = state { return request.token }
        return nil
    }

    mutating func receive(_ url: URL) {
        state = .waiting(Request(url: url))
    }

    mutating func begin(when readiness: Readiness) -> Request? {
        guard readiness.canResolve, case let .waiting(request) = state else { return nil }
        state = .resolving(request)
        return request
    }

    /// A newer URL owns delivery even if the old lookup returns later.
    mutating func finish(_ request: Request, outcome: Outcome) -> Bool {
        guard state == .resolving(request) else { return false }
        state = .finished(request, outcome)
        return true
    }
}
