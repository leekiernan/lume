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
    private let account: TrackerAccountPermit

    init(account: TrackerAccountLifetime) {
        viewer = .current
        self.account = TrackerAccountPermit(account: account)
    }

    var isCurrent: Bool {
        viewer.isCurrent && account.isCurrent
    }

    /// Revalidate after the executor hop, then serialize the synchronous local
    /// transaction with projection swaps. Never hold this across an await.
    func withCurrent<Value>(_ operation: () -> Value) -> Value? {
        ProfileProjectionGate.shared.withCurrent(viewer) {
            guard account.isCurrent else { return nil }
            return operation()
        } ?? nil
    }
}

/// A captured lifetime without the import's viewer projection rule. Imports
/// use the strict credential lifetime; scrobbles use an account lifetime that
/// survives verified same-account rotations. Trakt is still globally connected.
nonisolated struct TrackerAccountPermit {
    private let account: TrackerAccountLifetime
    private let generation: RequestToken

    init(account: TrackerAccountLifetime) {
        self.account = account
        generation = account.current
    }

    var isCurrent: Bool {
        account.current == generation
    }

    @MainActor
    func accessToken(using fetch: () async -> String?) async -> String? {
        guard !Task.isCancelled, isCurrent else { return nil }
        let token = await fetch()
        return !Task.isCancelled && isCurrent ? token : nil
    }
}
