import Foundation

/// Owns account transitions and permits for work that suspends. Logout revokes
/// permits immediately, even if the best-effort remote logout is still running.
nonisolated struct OpenSubtitlesSessionMachine {
    struct Account {
        let session: OpenSubtitlesSession
        var remainingDownloads: Int?
    }

    private enum State {
        case idle(Account?, error: String?)
        case signingIn(RequestToken, previous: Account?)
    }

    private var state: State = .idle(nil, error: nil)
    private(set) var generation = RequestToken()

    var account: Account? {
        switch state {
        case let .idle(account, _), let .signingIn(_, account): account
        }
    }

    var isSigningIn: Bool {
        if case .signingIn = state { return true }
        return false
    }

    var error: String? {
        if case let .idle(_, error) = state { return error }
        return nil
    }

    mutating func restore(_ session: OpenSubtitlesSession?) {
        generation = RequestToken()
        state = .idle(session.map { Account(session: $0) }, error: nil)
    }

    mutating func beginSignIn() -> RequestToken? {
        guard !isSigningIn else { return nil }
        generation = RequestToken()
        state = .signingIn(generation, previous: account)
        return generation
    }

    @discardableResult
    mutating func finishSignIn(_ request: RequestToken, session: OpenSubtitlesSession) -> Bool {
        guard case let .signingIn(active, _) = state, active == request else { return false }
        state = .idle(Account(session: session), error: nil)
        return true
    }

    mutating func failSignIn(_ request: RequestToken, message: String?) {
        guard case let .signingIn(active, previous) = state, active == request else { return }
        state = .idle(previous, error: message)
    }

    @discardableResult
    mutating func signOut() -> OpenSubtitlesSession? {
        let previous = account?.session
        restore(nil)
        return previous
    }

    func accepts(_ permit: RequestToken) -> Bool {
        permit == generation
    }

    mutating func recordDownload(_ remaining: Int, permit: RequestToken) {
        guard accepts(permit), case let .idle(account?, error) = state else { return }
        var updated = account
        updated.remainingDownloads = remaining
        state = .idle(updated, error: error)
    }
}
