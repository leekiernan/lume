import Foundation

/// Process-local identity for one surface's lifetime. Unlike a counter, a
/// duplicate release cannot accidentally end another surface's activity.
nonisolated struct ActivityLease: Hashable {
    private let token = RequestToken()
}

nonisolated struct ActivityLeases {
    private var owners: Set<ActivityLease> = []
    var isActive: Bool {
        !owners.isEmpty
    }

    mutating func acquire(_ owner: ActivityLease) {
        owners.insert(owner)
    }

    @discardableResult
    mutating func release(_ owner: ActivityLease) -> Bool {
        owners.remove(owner) != nil
    }
}
