//
//  TrackerAccountSession.swift
//  Lume
//
//  One tracker account's sign-in and token lifecycle, shared by the Trakt and
//  Simkl services: restoring the stored session, the OAuth device flow, token
//  refresh, resolving who the tokens belong to, and disconnecting. The states
//  are `TrackerSessionMachine`'s; the service-specific parts come from the
//  `Backend`.
//
//  The services keep what is theirs (durable mutations, watchlists,
//  scrobbling, imports) and hear about the session through two hooks:
//  `identityDidChange` and `didConnect`.
//

import Foundation
import OSLog

/// How a restore left the session.
enum TrackerRestoreOutcome: Equatable {
    /// No tokens on this device.
    case signedOut
    /// Tokens are held but none is usable yet (offline, or another device is
    /// rotating the shared single-use refresh token).
    case waiting
    /// Tokens are held and usable.
    case ready
}

@MainActor
@Observable
final class TrackerAccountSession<Backend: TrackerAccountBackend> {
    private(set) var machine = TrackerSessionMachine<Backend.Code>()
    /// Who the held tokens belong to, once known.
    private(set) var identity: Backend.Identity?

    /// Whenever `identity` changes — restored, fetched or cleared. `confirmed`
    /// when it was just fetched with a working token, which is when queued work
    /// for the account can go out; a remembered identity only says who to queue
    /// it for.
    @ObservationIgnored var identityDidChange: ((_ identity: Backend.Identity?, _ confirmed: Bool) -> Void)?
    /// After a device-flow sign-in completes on this device.
    @ObservationIgnored var didConnect: (() async -> Void)?

    @ObservationIgnored let backend: Backend
    @ObservationIgnored private var tokens: Backend.Tokens?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var identityTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<String?, Never>?
    @ObservationIgnored private var generation = RequestToken()
    /// A refresh token the service rejected. Another device may have consumed
    /// it and be exporting the replacement through iCloud, so don't retry it
    /// until a different pair arrives.
    @ObservationIgnored private var refreshFailedForToken: String?

    /// First wait between identity lookups; doubles up to ten minutes.
    @ObservationIgnored private let identityRetryDelay: Duration

    init(backend: Backend, identityRetryDelay: Duration = .seconds(15)) {
        self.backend = backend
        self.identityRetryDelay = identityRetryDelay
    }

    // MARK: - State for the UI

    var isConfigured: Bool {
        backend.isConfigured
    }

    /// Whether this device holds the account's tokens. The username can lag
    /// behind (after a reinstall it is fetched again).
    var isConnected: Bool {
        machine.isConnected
    }

    var isConnecting: Bool {
        machine.isConnecting
    }

    var username: String? {
        machine.account
    }

    var pendingCode: Backend.Code? {
        machine.pendingCode
    }

    /// A human-readable failure from the last connect attempt. Cleared when a
    /// new attempt begins.
    var connectionError: String? {
        machine.failure.map(Self.message)
    }

    // MARK: - Lifecycle

    /// Loads the stored session at launch or after iCloud replaced the tokens:
    /// the tokens, the remembered identity, then — if a token is usable — a
    /// fresh identity.
    func restore() async -> TrackerRestoreOutcome {
        guard isConfigured else { return .signedOut }
        guard let stored = backend.loadTokens() else {
            invalidateSessionWork()
            tokens = nil
            refreshFailedForToken = nil
            backend.clearIdentity()
            setIdentity(nil, confirmed: false)
            send(.tokensGone)
            return .signedOut
        }
        if tokens != stored { invalidateSessionWork() }
        tokens = stored
        if refreshFailedForToken != stored.refreshToken {
            refreshFailedForToken = nil
        }
        let remembered = backend.loadIdentity()
        setIdentity(remembered, confirmed: false)
        send(.tokensHeld(account: remembered?.username))

        let request = generation
        guard let accessToken = await validAccessToken(), generation == request, isConnected else { return .waiting }
        if let fresh = await backend.fetchIdentity(accessToken: accessToken) {
            guard generation == request, isConnected, !Task.isCancelled else { return .signedOut }
            adopt(fresh)
        }
        return generation == request && isConnected ? .ready : .signedOut
    }

    func connect() {
        guard isConfigured else { return }
        send(.connectRequested)
    }

    func cancelConnect() {
        send(.connectCancelled)
    }

    /// Revokes the token server-side (best effort) and clears the session,
    /// recording the user's decision so iCloud signs every device out.
    func disconnect() async {
        let revokedToken = tokens?.accessToken
        invalidateSessionWork()
        send(.disconnected)
        if backend.clearTokensForUserDisconnect() {
            backend.credentialsDidChange()
        }
        backend.clearIdentity()
        tokens = nil
        setIdentity(nil, confirmed: false)
        // Local intent is durable before the network suspension. A new sign-in
        // during revocation must not be cleared by this old operation.
        if let revokedToken { await backend.revoke(accessToken: revokedToken) }
    }

    private func invalidateSessionWork() {
        generation = RequestToken()
        refreshTask?.cancel()
        refreshTask = nil
        identityTask?.cancel()
        identityTask = nil
    }

    // MARK: - Tokens

    /// A usable access token, refreshing first if the pair is stale.
    /// Concurrent refreshes coalesce into one request.
    func validAccessToken() async -> String? {
        guard let current = tokens else { return nil }
        if !current.needsRefresh {
            return current.accessToken
        }
        guard refreshFailedForToken != current.refreshToken else { return nil }
        let request = generation
        if let refreshTask {
            let result = await refreshTask.value
            return generation == request && !Task.isCancelled ? result : nil
        }

        let task = Task { [weak self] () -> String? in
            guard let self else { return nil }
            return await refresh(current, request: request)
        }
        refreshTask = task
        let result = await task.value
        guard generation == request else { return nil }
        refreshTask = nil
        return Task.isCancelled ? nil : result
    }

    private func refresh(_ current: Backend.Tokens, request: RequestToken) async -> String? {
        let result = await backend.refresh(current.refreshToken)
        guard generation == request, tokens?.refreshToken == current.refreshToken, !Task.isCancelled else { return nil }
        switch result {
        case let .refreshed(newTokens):
            apply(newTokens)
            return tokens?.accessToken
        case .rejected:
            refreshFailedForToken = current.refreshToken
            return nil
        case .unavailable:
            return nil
        }
    }

    private func apply(_ newTokens: Backend.Tokens) {
        if let current = tokens, current.issuedAt > newTokens.issuedAt {
            return
        }
        tokens = newTokens
        refreshFailedForToken = nil
        if backend.saveTokens(newTokens) {
            backend.credentialsDidChange()
        }
    }

    // MARK: - Identity

    private func setIdentity(_ newIdentity: Backend.Identity?, confirmed: Bool) {
        guard identity != newIdentity || confirmed else { return }
        identity = newIdentity
        identityDidChange?(newIdentity, confirmed)
    }

    /// Takes a freshly fetched identity: stored for the next launch, and the
    /// session told who it is.
    private func adopt(_ fresh: Backend.Identity) {
        backend.saveIdentity(fresh)
        setIdentity(fresh, confirmed: true)
        send(.identityResolved(account: fresh.username))
    }

    /// Fetches the account the held tokens belong to, backing off between
    /// attempts, until it is known or the session no longer needs it.
    private func resolveIdentity() {
        guard identityTask == nil else { return }
        let request = generation
        identityTask = Task { [weak self] in
            var delay = self?.identityRetryDelay ?? .seconds(15)
            while !Task.isCancelled {
                guard let self, generation == request, machine.isConnected, machine.account == nil else { break }
                if let accessToken = await validAccessToken(),
                   let fresh = await backend.fetchIdentity(accessToken: accessToken),
                   generation == request, !Task.isCancelled, machine.isConnected, machine.account == nil
                {
                    adopt(fresh)
                    break
                }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(600))
            }
            if self?.generation == request { self?.identityTask = nil }
        }
    }

    // MARK: - Device flow

    private func runDeviceFlow() async {
        do {
            let code = try await backend.requestDeviceCode()
            try Task.checkCancellation()
            send(.codeIssued(code))

            let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
            var interval = TimeInterval(max(code.interval, 1))

            // A declined code can look exactly like an untouched one (Simkl
            // records nothing on decline), so the deadline is the only end for
            // a user who says no.
            while !Task.isCancelled, Date() < deadline {
                try await Task.sleep(for: .seconds(interval))
                let outcome = await backend.poll(code)
                try Task.checkCancellation()
                switch outcome {
                case .pending:
                    continue
                case .slowDown:
                    // Polling again at the old cadence re-arms the service's
                    // window and can lock the loop out until the code expires.
                    interval += Backend.slowDownStep
                case let .approved(newTokens):
                    await finishConnect(with: newTokens)
                    return
                case let .failed(failure):
                    send(.connectFailed(failure))
                    return
                }
            }
            if !Task.isCancelled {
                send(.connectFailed(.codeExpired))
            }
        } catch is CancellationError {
            // Cancelled via cancelConnect() or a disconnect.
        } catch {
            if !Task.isCancelled { send(.connectFailed(.unreachable)) }
        }
    }

    private func finishConnect(with newTokens: Backend.Tokens) async {
        guard !Task.isCancelled, isConnecting else { return }
        invalidateSessionWork()
        let request = generation
        apply(newTokens)
        let fresh = await backend.fetchIdentity(accessToken: newTokens.accessToken)
        guard !Task.isCancelled, generation == request, isConnecting else { return }
        if let fresh {
            // Just fetched with the new token, so work queued for the account
            // can go out.
            backend.saveIdentity(fresh)
            setIdentity(fresh, confirmed: true)
        }
        send(.tokensHeld(account: fresh?.username))
        await didConnect?()
    }

    // MARK: - Session machine

    private func send(_ event: TrackerSessionMachine<Backend.Code>.Event) {
        let before = machine.state
        guard let effects = machine.handle(event) else {
            Logger.network.info("\(Backend.name) session: ignored \(event.logName) while \(before.logName)")
            return
        }
        if machine.state != before {
            Logger.network.info("\(Backend.name) session: \(before.logName) → \(machine.state.logName)")
        }
        for effect in effects {
            switch effect {
            case .startDeviceFlow:
                pollingTask?.cancel()
                pollingTask = Task { [weak self] in
                    await self?.runDeviceFlow()
                }
            case .cancelDeviceFlow:
                pollingTask?.cancel()
                pollingTask = nil
            case .resolveIdentity:
                resolveIdentity()
            }
        }
    }

    static func message(_ failure: TrackerConnectFailure) -> String {
        switch failure {
        case .codeExpired: "The code expired. Please try connecting again."
        case .declined: "Authorization was declined."
        case .codeUsed: "That code was already used. Please try again."
        case .rejectedApp: "\(Backend.name) rejected this app's credentials."
        case .unreachable: "Couldn't reach \(Backend.name). Check your connection and try again."
        }
    }
}
