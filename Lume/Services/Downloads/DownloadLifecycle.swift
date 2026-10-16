import Foundation

/// Transfer ownership, independent of URLSession and UI progress. A cancelled
/// attempt stays retired until an explicit enqueue; its late callbacks cannot
/// settle a replacement. Unknown tasks may be adopted after a system relaunch.
nonisolated struct DownloadLifecycle {
    private enum State: Equatable {
        case queued
        case running(Int)
        case finishing(Int)
        case retired
    }

    private var states: [String: State] = [:]

    mutating func enqueue(_ id: String) {
        states[id] = .queued
    }

    mutating func start(_ id: String, task: Int) -> Bool {
        guard states[id] == .queued else { return false }
        states[id] = .running(task)
        return true
    }

    mutating func restore(_ id: String, task: Int) -> Bool {
        guard states[id] == nil else { return states[id] == .running(task) }
        states[id] = .running(task)
        return true
    }

    mutating func beginCompletion(_ id: String, task: Int) -> Bool {
        guard restore(id, task: task), states[id] == .running(task) else { return false }
        states[id] = .finishing(task)
        return true
    }

    mutating func finish(_ id: String, task: Int) -> Bool {
        guard states[id] == .running(task) || states[id] == .finishing(task) else { return false }
        states[id] = .retired
        return true
    }

    mutating func cancel(_ id: String) {
        states[id] = .retired
    }

    mutating func fail(_ id: String, task: Int) -> Bool {
        if finish(id, task: task) { return true }
        return restore(id, task: task) && finish(id, task: task)
    }
}
