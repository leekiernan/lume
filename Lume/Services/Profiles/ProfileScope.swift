import Foundation

/// Captured before asynchronous work. Returning to the same profile does not
/// revive an operation started against its previous catalog projection.
nonisolated struct ProfileScope: Equatable {
    let profileID: UUID?
    let generation: RequestToken

    static var current: Self {
        ActiveProfileStore.scope
    }

    var isCurrent: Bool {
        self == Self.current
    }
}
