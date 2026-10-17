import Foundation

/// VLC can report playing at zero before a resume seek is possible or has
/// landed. Do not publish that clock as watch progress or startup evidence.
nonisolated struct VLCResumeSeekMachine {
    enum State: Equatable {
        case notNeeded
        case waiting(TimeInterval)
        case issued(TimeInterval)
        case landed
    }

    private(set) var state: State

    init(target: TimeInterval = 0, isLive: Bool = false) {
        // VLCTime takes signed 32-bit milliseconds. Reject unrepresentable
        // external progress instead of trapping in the engine adapter.
        state = !isLive && target.isFinite && target > 1 && target <= Double(Int32.max) / 1000
            ? .waiting(target) : .notNeeded
    }

    mutating func seekIfPossible(isSeekable: Bool) -> TimeInterval? {
        guard isSeekable, case let .waiting(target) = state else { return nil }
        state = .issued(target)
        return target
    }

    mutating func observe(currentSeconds: TimeInterval) -> Bool {
        switch state {
        case .notNeeded, .landed: return true
        case .waiting: return false
        case let .issued(target):
            guard currentSeconds.isFinite, currentSeconds >= target - 2 else { return false }
            state = .landed
            return true
        }
    }
}
