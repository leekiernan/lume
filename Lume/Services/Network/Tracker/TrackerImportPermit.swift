import Foundation
import Synchronization

/// Session generations are process-local, unlike the durable account/profile
/// identity used by parked history. A reconnect to the same account is new work.
final nonisolated class TrackerAccountLifetime: Sendable {
    private let generation = Mutex(RequestToken())

    var current: RequestToken {
        generation.withLock { $0 }
    }

    func invalidate() {
        generation.withLock { $0 = RequestToken() }
    }
}

nonisolated struct TrackerImportPermit {
    private let viewer: ProfileScope
    private let account: TrackerAccountLifetime
    private let generation: RequestToken

    init(account: TrackerAccountLifetime) {
        viewer = .current
        self.account = account
        generation = account.current
    }

    var isCurrent: Bool {
        viewer.isCurrent && account.current == generation
    }

    /// Revalidate after the executor hop, then serialize the synchronous local
    /// transaction with projection swaps. Never hold this across an await.
    func withCurrent<Value>(_ operation: () -> Value) -> Value? {
        ProfileProjectionGate.shared.withCurrent(viewer) {
            guard account.current == generation else { return nil }
            return operation()
        } ?? nil
    }
}
