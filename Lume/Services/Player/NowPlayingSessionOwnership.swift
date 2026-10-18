import Foundation

/// Now Playing selects one host, rather than aggregating every active host.
/// A fresh request also distinguishes two streams opened by the same host.
nonisolated struct NowPlayingSessionOwnership {
    private(set) var owner: ActivityLease?
    private var request = RequestToken()

    mutating func claim(_ owner: ActivityLease) -> RequestToken {
        self.owner = owner
        request = RequestToken()
        return request
    }

    func accepts(_ request: RequestToken) -> Bool {
        owner != nil && self.request == request
    }

    @discardableResult
    mutating func release(_ owner: ActivityLease) -> Bool {
        guard self.owner == owner else { return false }
        self.owner = nil
        request = RequestToken()
        return true
    }
}
