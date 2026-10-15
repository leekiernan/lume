/// One active export and one replaceable pending request. Scheduling revokes
/// publication rights immediately, before the debounce or cancellation ends.
struct TopShelfExportMachine {
    private enum Pending {
        case waiting(RequestToken)
        case ready(RequestToken)

        var token: RequestToken {
            switch self {
            case let .waiting(token), let .ready(token): token
            }
        }
    }

    private enum State {
        case idle
        case pending(Pending)
        case exporting(RequestToken, pending: Pending?)
    }

    private var state: State = .idle

    mutating func request() -> RequestToken {
        let token = RequestToken()
        switch state {
        case let .exporting(active, _): state = .exporting(active, pending: .waiting(token))
        case .idle, .pending: state = .pending(.waiting(token))
        }
        return token
    }

    mutating func ready(_ token: RequestToken) {
        switch state {
        case let .pending(pending) where pending.token == token:
            state = .pending(.ready(token))
        case let .exporting(active, pending) where pending?.token == token:
            state = .exporting(active, pending: .ready(token))
        default: break
        }
    }

    mutating func begin() -> RequestToken? {
        guard case let .pending(.ready(token)) = state else { return nil }
        state = .exporting(token, pending: nil)
        return token
    }

    func canPublish(_ token: RequestToken) -> Bool {
        guard case let .exporting(active, pending: nil) = state else { return false }
        return active == token
    }

    mutating func finish(_ token: RequestToken) {
        guard case let .exporting(active, pending) = state, active == token else { return }
        state = pending.map(State.pending) ?? .idle
    }
}

/// The task-owning driver stays platform-neutral so cancellation, debounce
/// and publication ownership are tested without a Top Shelf extension.
@MainActor
final class TopShelfExportCoordinator {
    typealias PublicationCheck = @MainActor @Sendable () -> Bool

    private var machine = TopShelfExportMachine()
    private var debounce: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var active: Task<Void, Never>?
    private let delay: Duration
    private let export: @MainActor (@escaping PublicationCheck) async -> Void

    init(delay: Duration = .milliseconds(300), export: @escaping @MainActor (@escaping PublicationCheck) async -> Void) {
        self.delay = delay
        self.export = export
    }

    func refresh(immediately: Bool = false) {
        let token = invalidate()
        if immediately {
            machine.ready(token)
            startWorker()
        } else {
            debounce = Task { [weak self, delay] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                machine.ready(token)
                startWorker()
            }
        }
    }

    /// A profile switch invalidates now, but doesn't schedule work against a
    /// half-swapped catalogue. Its completion calls `refresh` with a new token.
    @discardableResult
    func invalidate() -> RequestToken {
        debounce?.cancel()
        active?.cancel()
        return machine.request()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while let token = machine.begin() {
                let check: PublicationCheck = { [weak self] in self?.machine.canPublish(token) == true }
                let operation = export
                let task = Task { await operation(check) }
                active = task
                await task.value
                active = nil
                machine.finish(token)
            }
            worker = nil
        }
    }
}
