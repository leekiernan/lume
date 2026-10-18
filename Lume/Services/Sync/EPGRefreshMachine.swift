import Foundation

nonisolated enum EPGRefreshIntent: Equatable {
    case enrichment
    case guide(allowConditional: Bool)

    var metadataOnly: Bool {
        self == .enrichment
    }

    var allowConditional: Bool {
        if case let .guide(conditional) = self { return conditional }
        return true
    }

    /// Provider work includes enrichment; a forced guide check must never be
    /// weakened by a later conditional or metadata-only trigger.
    func merging(_ other: Self) -> Self {
        switch (self, other) {
        case (.guide(false), _), (_, .guide(false)): .guide(allowConditional: false)
        case (.guide(true), _), (_, .guide(true)): .guide(allowConditional: true)
        default: .enrichment
        }
    }
}

/// Admission against the real content-sync queue, not a guessed launch order.
/// Both guide and catalogue requests can consume the provider's one connection.
nonisolated struct EPGRefreshGate {
    private(set) var runningContentSyncs = 0
    var isAutoSyncQueued = false
    private(set) var pendingIntent: EPGRefreshIntent?
    var isRefreshOwed: Bool {
        pendingIntent != nil
    }

    var isContentSyncPending: Bool {
        runningContentSyncs > 0 || isAutoSyncQueued
    }

    mutating func request(_ intent: EPGRefreshIntent = .guide(allowConditional: true)) -> Bool {
        if isContentSyncPending {
            owe(intent)
            return false
        }
        return true
    }

    mutating func owe(_ intent: EPGRefreshIntent = .guide(allowConditional: true)) {
        pendingIntent = pendingIntent.map { $0.merging(intent) } ?? intent
    }

    mutating func contentSyncStarted() {
        runningContentSyncs += 1
    }

    mutating func contentSyncFinished(succeeded: Bool, refreshedLiveTV: Bool) {
        runningContentSyncs = max(0, runningContentSyncs - 1)
        if succeeded, refreshedLiveTV { owe() }
    }

    @discardableResult
    mutating func takeOwedRefresh(allowDuringContentSync: Bool = false) -> Bool {
        guard isRefreshOwed, allowDuringContentSync || !isContentSyncPending else { return false }
        pendingIntent = nil
        return true
    }
}

/// One running job plus typed refresh debt. IO, publication fences and schedule
/// timestamps remain in the service; stale completions cannot retire a new job.
nonisolated struct EPGRefreshMachine {
    enum Mode: Equatable { case background, manual }
    struct Job: Equatable {
        let id = RequestToken()
        let intent: EPGRefreshIntent
        let mode: Mode
        let retrySuperseded: Bool
    }

    private var gate = EPGRefreshGate()
    private(set) var running: Job?
    var isRunning: Bool {
        running != nil
    }

    var pendingIntent: EPGRefreshIntent? {
        gate.pendingIntent
    }

    var isContentSyncPending: Bool {
        gate.isContentSyncPending
    }

    var isAutoSyncQueued: Bool {
        get { gate.isAutoSyncQueued }
        set { gate.isAutoSyncQueued = newValue }
    }

    mutating func owe(_ intent: EPGRefreshIntent) {
        gate.owe(intent)
    }

    mutating func begin(_ intent: EPGRefreshIntent, mode: Mode, retrySuperseded: Bool = true) -> Job? {
        guard running == nil else { return nil }
        let resolved = gate.pendingIntent.map { intent.merging($0) } ?? intent
        if mode == .background, !gate.request(resolved) { return nil }
        gate.takeOwedRefresh(allowDuringContentSync: mode == .manual)
        let job = Job(intent: resolved, mode: mode, retrySuperseded: retrySuperseded)
        running = job
        return job
    }

    /// The executor cancels the task only when this returns true. Manual work
    /// deliberately remains allowed alongside a content sync, as before.
    mutating func contentSyncStarted() -> Bool {
        gate.contentSyncStarted()
        guard let running, running.mode == .background else { return false }
        gate.owe(running.intent)
        return true
    }

    mutating func contentSyncFinished(succeeded: Bool, refreshedLiveTV: Bool) {
        gate.contentSyncFinished(succeeded: succeeded, refreshedLiveTV: refreshedLiveTV)
    }

    @discardableResult
    mutating func finish(_ job: Job) -> Bool {
        guard running == job else { return false }
        running = nil
        return true
    }
}
